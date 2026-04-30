# Troubleshooting

If you hit something not in this list, open a bug-report issue. Include PowerShell version, Windows version, and terminal host (Windows Terminal / Tabby / Hyper / conhost).

## The panel doesn't appear

The watcher isn't running. Check:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'agent-tabs-watcher' } |
    Select-Object ProcessId, CommandLine
```

If empty:

- The Startup shortcut may not exist. Verify: `Test-Path "$([Environment]::GetFolderPath('Startup'))\agent-tabs-watcher.lnk"`.
- Re-run `./install.ps1` (idempotent).
- Or launch manually: `powershell -NoProfile -WindowStyle Hidden -File "$env:USERPROFILE\.claude\hooks\agent-tabs-watcher.ps1"`.

If the panel was visible and disappeared, check Event Viewer → Windows Logs → Application for PowerShell crashes.

## A tab doesn't show up in the panel

Hooks aren't firing for that session, or the status file isn't being written.

**Step 1**: Check whether the hooks fire.

```powershell
# Watch for new status files
Get-ChildItem $env:USERPROFILE\.claude\cache\tab_status_*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object Name, LastWriteTime -First 5
```

Submit a prompt in the missing tab, then re-run. If no new file appears within a second, hooks aren't firing.

- Verify `~/.claude/settings.json` has the 5 hook entries. `cat $env:USERPROFILE\.claude\settings.json` and look for `notify-busy`, `notify-done`, `notify-clear`, `notify-resume`.
- Restart Claude Code in that tab — hook registrations are read at session start.
- Verify the script paths in `settings.json` are absolute and resolve: `Test-Path 'C:/Users/<you>/.claude/hooks/notify-done.ps1'`.

**Step 2**: If status files appear but the panel doesn't show them, the watcher is filtering them out.

- Check `terminal_pid` is sensible: `cat $env:USERPROFILE\.claude\cache\tab_status_<id>.json`. The `terminal_pid` should be the *shell* pid (your `pwsh` / `bash` / `cmd`), not the powershell that ran the hook.
  ```powershell
  Get-Process -Id <terminal_pid>   # should return your shell, not powershell
  ```
- If `terminal_pid` is dead, the watcher deletes the file. Common cause: the hook walked from `$PID` instead of from parent. This was fixed in 0.1.0 — make sure you're on a current build.
- If the file is being deleted faster than you can read it, the watcher is logging the delete. There's no log file by default; comment out the `Remove-Item` lines in `Refresh-Tabs` temporarily to debug.

## The wrong tab name shows up

The panel uses `Split-Path -Leaf $cwd` for the row label. If your tab shows `Documents` instead of `my-project`, you launched CC from the wrong directory or haven't `cd`'d in.

- Fix once: `cd path/to/my-project; claude` (restart CC). The next prompt updates the cwd.
- Alternative: Two tabs in the same project will show the same name. There's no fix for this in 0.1.0 — see "Open architectural questions" in `docs/architecture.md`.

## The title prefix `[OK]` / `[WAIT]` / `[!]` won't go away

`notify-clear.ps1` should strip it on `SessionStart`. If it's stuck:

- Verify `SessionStart` is registered for `notify-clear.ps1` in `settings.json`.
- Restart Claude Code in that tab. The next session start strips the prefix.
- As a one-off manual fix:
  ```powershell
  # Find the host window
  Get-Process | Where-Object { $_.MainWindowTitle -like '`[*' } | Select-Object Id, MainWindowTitle
  # Then in PowerShell, use SetWindowText (or just rename the tab manually in WT/Tabby).
  ```

## Toast notifications never appear

Two common causes:

- **Focus assist enabled.** Settings → System → Notifications → Focus assist. Set to "Off" or "Priority only" with PowerShell whitelisted.
- **Toast app ID collision.** Our `APP_ID` is the standard PowerShell `{1AC14E77-...}`. If another tool overrode it, our toasts show under that tool's name. Mostly cosmetic.

If toasts work but the title shows mojibake (`???` or `锟斤拷`), your console code page is corrupting UTF-8. Verify: `[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)` is at the top of `notify-done.ps1`. This is set in 0.1.0+.

## Taskbar doesn't flash

`FlashWindowEx` is a no-op when the window is already foreground. Multi-tab hosts (WT/Tabby) keep the host hwnd foreground while you're in *any* tab — so if you're working in tab A and tab B's CC finishes, no flash will fire (intentionally; the host icon is already lit).

- To verify the flash code path runs at all: alt-tab to a different application *before* the agent finishes. Then a flash should fire on completion.
- If still no flash with a definitely-different foreground window, check that `Get-TerminalInfo` returns a non-zero hwnd. The status JSON's `hwnd` field should be a positive integer. `0` means the parent walk didn't find a GUI host (rare; happens with some non-standard terminals).

## I uninstalled but the panel is still up

The watcher process is still running. `./install.ps1 -Uninstall` *tries* to kill it but the Stop-Process call is best-effort.

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'agent-tabs-watcher' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

## My `settings.json` got corrupted

The installer always backs up to `settings.json.bak` before writing.

```powershell
Copy-Item "$env:USERPROFILE\.claude\settings.json.bak" "$env:USERPROFILE\.claude\settings.json" -Force
```

If the backup is also bad (you ran `install.ps1` twice and the second run backed up the broken file), restore from version control if you have one, or hand-edit. The 5 hook entries we add are listed in `examples/settings.json`.

## Hook events fire too often / too rarely

Claude Code controls when hooks fire. claude-code-tabs is purely reactive. If `Stop` fires multiple times per "task complete" or `PreToolUse` doesn't fire on every tool call, that's a CC behavior, not a panel bug.

That said, our `notify-resume.ps1` is fast-path early-exit when state ≠ `WAITING`, so frequent `PreToolUse` events are cheap.
