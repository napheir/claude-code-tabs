# Architecture

This is the design rationale. If you only want to use the panel, the README is enough — read this when you're going to change the code, or when something is broken in a way the troubleshooting doc doesn't cover.

## High-level dataflow

```
                 ┌──────────────────────────────┐
                 │  Claude Code (one CLI proc   │
                 │   per tab, in a shared       │
                 │   terminal host like WT)     │
                 └──────┬───────────────────────┘
                        │ hook events (5 kinds)
                        │ + JSON stdin {session_id, cwd, ...}
                        ▼
       ┌────────────────────────────────────────────┐
       │  notify-busy / notify-done /               │
       │  notify-clear / notify-resume              │
       │  (one short-lived powershell per event)    │
       └──────┬─────────────────────────────────────┘
              │ (a) FlashWindowEx / SetWindowText / Toast
              │ (b) write status JSON
              ▼
       ~/.claude/cache/tab_status_<session_id>.json
              │ poll every 2s
              ▼
       agent-tabs-watcher.ps1  (long-running WinForms)
              │
              ▼
        always-on-top status panel
```

The watcher is the only long-running process. The four `notify-*` scripts each run for ~50–200ms per hook event and exit.

## Why file-based IPC

The watcher needs to learn about events from N short-lived hook processes. Options considered:

- **Named pipe / TCP socket**: requires the watcher to be running before any hook fires; if the user kills the watcher, the next event is lost (or the hook hangs trying to connect).
- **Event log**: heavy, requires admin-installed source on first write, hard to clean up.
- **Files on disk**: trivially reliable, easy to inspect (`type tab_status_*.json`), survive watcher restarts. Cleanup is the hard part — see "Per-tab dedup + liveness" below.

We picked files. The watcher polls every 2s; the hook never blocks on IPC.

## The terminal_pid problem

Modern terminal hosts (Windows Terminal, Tabby, Hyper) all share **one `MainWindowHandle` across every tab in the host**. So if you have 10 CC tabs in one WT window:

- They all flash the same hwnd (fine — flashing the host is what we want).
- They all set the same window title (less fine — the title only ever shows the *last* event).
- They cannot be distinguished by hwnd alone.

The watcher needs a per-tab identifier that:

1. Is stable for the lifetime of the tab (not the lifetime of one CC invocation — you might `/exit` and restart CC inside the same tab).
2. Dies when the tab dies, so we can clean up status files of closed tabs.

The shell process pid (the long-running `pwsh` / `bash` / `cmd` *inside* the tab, not the terminal host process) satisfies both. We call it `terminal_pid`.

### How we discover it

```
hook script ($PID) → parent → ... → first ancestor with MainWindowHandle (= host)
                              ^
                              └── the last non-GUI ancestor before reaching the host
                                  is the per-tab shell pid.
```

Critical detail: **the walk starts at `$PID`'s parent, not at `$PID`**. The current process is the short-lived powershell running the hook. If the hook itself happens to have a console window (it sometimes does, depending on how Claude Code spawns it), starting at `$PID` would return immediately with `$PID` as `terminal_pid`. Then the moment the hook exits, the watcher's liveness check would see `terminal_pid` is dead and delete the status file.

This was a real bug — see commit `d22d7e3f` in the upstream project. The fix is in `Get-TerminalInfo` in `src/notify-done.ps1`: `$cur = $startProc.ParentProcessId; for ($i = 0; ...)`.

## Per-tab dedup + liveness

When CC restarts inside the same tab (`/exit` then `claude` again), it gets a new `session_id` but runs inside the same shell process — so `terminal_pid` is unchanged. Without dedup, the panel would show a row per CC invocation, accumulating ghosts.

The watcher (in `Refresh-Tabs`):

1. Reads every `tab_status_*.json` in the cache dir.
2. Groups by `terminal_pid` (with fallback keys `cwd` and `session_id` for legacy entries missing the field).
3. Keeps the newest entry per group, deletes the older files.
4. For each kept entry, calls `Get-Process -Id <terminal_pid>`. If absent, deletes the file (= tab was closed).

Net effect: the panel shows one row per *live* tab, regardless of how many times CC restarted inside it. No time-based stale filter needed.

## UTF-8 stdin force

PowerShell 5.1 defaults `[Console]::InputEncoding` to the OS console code page. On Chinese-locale Windows, that's GBK / cp936. Claude Code writes hook stdin as UTF-8.

Symptom: any prompt containing non-ASCII (Chinese, emoji, accented Latin) corrupts the JSON. `ConvertFrom-Json` either throws or returns garbled fields. The `cwd` field gets mojibake'd if your project path contains non-ASCII; the `session_id` is usually ASCII so it survives, but the cwd-based tab name renders as `??????`.

Fix is one line at the top of every script that reads stdin:

```powershell
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
```

`($false)` = no BOM. This must run *before* the first `[Console]::In.ReadToEnd()`.

## Foreground guard on FlashWindowEx

`FlashWindowEx` on a window that's already foreground does nothing useful (it has no taskbar entry to flash). On multi-tab hosts, the *currently-focused* tab is always on the foreground hwnd, so flashing it would be a no-op visually but a confusing one (the host icon briefly highlights then unhighlights).

We check `GetForegroundWindow() != hwnd` before calling `FlashWindowEx`. If the user is *in* the tab when CC finishes, no flash; if they're elsewhere, flash until they alt-tab.

## Why no Codex / Cursor / Continue support

The maintainer tried adding Codex support and rolled it back. Six independent silent-failure modes stacked:

1. **stdin field name**: Codex uses `sessionId` (camelCase); CC uses `session_id` (snake_case). Reading only one falls back to `$PID`, which produces a fresh status file every powershell spawn — watcher liveness deletes it immediately.
2. **Process tree shape**: Codex's hook command in `hooks.json` runs `powershell.exe ... -File ...` directly, so the powershell has a `conhost` window. Walking from `$PID` (instead of from parent) returns the powershell itself as `terminal_pid`. (We've fixed this for CC by walking from parent — but it's a fragile invariant.)
3. **Hook reload semantics**: Codex caches `hooks.json` per-session, so editing the file while a session is running has no effect — you must restart Codex. CC behaves differently (verified less precisely; see CC docs).
4. **Sandbox `writable_roots`**: Codex runs hooks under `workspace-write`, which restricts where hook scripts can write. `~/.claude/cache/` is not writable by default → `Set-Content` silently fails, no error code, no log.
5. **Multi-hook semantics**: When two `Stop` hook entries are registered for two different tools, only the first one fires. Sibling-hook coexistence in one event array is not guaranteed.
6. **Bash heredoc backslash folding**: When generating the `hooks.json` snippet through a bash heredoc (which the upstream project's installer did), `\\` in PowerShell paths got folded to `\`, producing invalid JSON.

Each layer's failure is silent (`async: true` + `$ErrorActionPreference = "SilentlyContinue"` swallow everything). After fixing the first three and still not getting a stable panel row from Codex, the decision was: **defer integration until the second tool's hook semantics are documented**.

If you want to add support for another AI CLI, the audit checklist is:

- What's the stdin payload field naming?
- What process spawns hooks, and does the powershell have its own console window?
- When does the tool reload hooks?
- Is there a sandbox? What can hooks write?
- What happens when multiple hook entries are registered for the same event?

## Process budget

A typical CC session fires (very roughly):

- 1 `SessionStart` per session.
- 1 `UserPromptSubmit` per prompt.
- 1+ `PreToolUse` per turn (one per tool call).
- 1 `Stop` per turn ending naturally.
- 1 `Notification` per permission prompt.

Each event spawns a powershell that runs ~50–200ms and exits. For an active multi-tab user that's ~10 powershell spawns/minute peak. Negligible CPU; the only resource cost is the brief flicker if a hook somehow becomes visible (it shouldn't — hooks run with `-WindowStyle Hidden`).

The watcher itself is one long-running powershell with a 2s timer. Steady-state RAM is ~30–50MB.

## File layout

```
~/.claude/
├── hooks/
│   ├── notify-busy.ps1          (UserPromptSubmit)
│   ├── notify-done.ps1          (Stop, Notification)
│   ├── notify-clear.ps1         (SessionStart)
│   ├── notify-resume.ps1        (PreToolUse)
│   └── agent-tabs-watcher.ps1   (long-running)
├── cache/
│   └── tab_status_<session_id>.json   (one per active tab)
├── settings.json                 (hook registrations)
└── settings.json.bak             (created by install.ps1)
```

## Open architectural questions

- **No persistent history** — the panel only shows live tabs. A "recently finished" log would help with "wait, which tab finished 30s ago?" Suggested via `tab_history.jsonl` append on `Stop`, displayed in a separate tab of the panel. Not implemented.
- **Tab name from cwd** — works when each CC tab has a distinct `cwd`. Two tabs in the same project show identical names. Could be augmented with a user-set tab label in CC settings, but CC doesn't expose one.
- **Per-tab focus inside multi-tab hosts** — fundamentally limited by Win32. Double-click only brings the host to front, not the specific tab. WT has a `wt.exe focus-tab` CLI, but mapping `terminal_pid` → tab index requires WT internals not exposed publicly. Punted.
