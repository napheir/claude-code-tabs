# Security

## Scope

claude-code-tabs is a local-only userland tool. It runs on the same machine where you run Claude Code, with the same user account, and does the following:

- Spawns `powershell.exe` once per Claude Code hook event (`UserPromptSubmit`, `Stop`, `Notification`, `PreToolUse`, `SessionStart`).
- Reads stdin (the JSON payload Claude Code passes to hooks: `session_id`, `cwd`, etc.).
- Walks the parent process chain (`Get-CimInstance Win32_Process`, `Get-Process`) to discover the owning terminal window.
- Reads / writes `~/.claude/cache/tab_status_<session_id>.json` — small JSON status files.
- Reads / writes `~/.claude/settings.json` (only `install.ps1`; backed up to `.bak` first).
- Calls Win32 `FlashWindowEx` / `SetWindowText` / `SetForegroundWindow` on the discovered host window handle.
- Posts a Windows toast notification.
- Optionally creates a `.lnk` in `shell:startup` to auto-launch the watcher.

It does **not**:

- Make network calls.
- Read your prompt content, conversation history, or any file under your project (only the cwd path string).
- Modify any file outside `~/.claude/hooks/`, `~/.claude/cache/`, `~/.claude/settings.json`, and `shell:startup`.
- Elevate privileges.

## Reporting a vulnerability

If you discover a security issue, please open a GitHub issue **without** the exploit details and request a private contact channel, or email the maintainer at the address listed in commit history. Do not disclose details publicly until a fix is available.

## Threat model notes

- **`settings.json` rewrite.** `install.ps1` is the only path that writes to `settings.json`. It backs up to `.bak` first, uses `ConvertTo-Json -Depth 32`, and only appends entries; it never removes user entries unless you run `-Uninstall` (which removes only entries whose `command` regex-matches our script filenames).
- **stdin parsing.** Hook stdin is JSON from a trusted local process (Claude Code itself). We force UTF-8 on `[Console]::InputEncoding` to avoid GBK / cp936 corruption on Chinese-default Windows installs. `ConvertFrom-Json` is wrapped in try/catch so a malformed payload cannot crash the hook chain.
- **Process tree walk.** `Get-Process -Id <int>` + `Get-CimInstance Win32_Process` only read process metadata; they do not exfiltrate or modify other processes.
- **No code execution from cache.** The watcher only `ConvertFrom-Json`s status files and uses primitive fields (state string, hwnd int, pid int, cwd path, ts). It does not `Invoke-Expression` any cached content.

## Auto-launched watcher

The Startup folder shortcut launches `powershell.exe -NoProfile -WindowStyle Hidden -File <watcher>` on every login. To stop / inspect it:

```powershell
# View the running watcher process
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'agent-tabs-watcher' }

# Stop it
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'agent-tabs-watcher' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# Disable auto-launch (leaves scripts + hooks in place)
Remove-Item "$([Environment]::GetFolderPath('Startup'))\agent-tabs-watcher.lnk"
```

`./install.ps1 -Uninstall` does all of the above plus removes the hook scripts and unregisters the `settings.json` entries.
