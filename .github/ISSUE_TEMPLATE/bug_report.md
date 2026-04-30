---
name: Bug report
about: Something is broken or behaving unexpectedly
title: "[bug] "
labels: bug
assignees: ''
---

## Environment

<!-- All three are required — most issues are environment-specific. -->

- **PowerShell version**: <!-- $PSVersionTable.PSVersion -->
- **Windows version**: <!-- winver, e.g. Windows 11 Pro 23H2 (build 22631.x) -->
- **Terminal host**: <!-- Windows Terminal / Tabby / Hyper / conhost / other -->
- **Claude Code version**: <!-- claude --version -->
- **claude-code-tabs version / commit**: <!-- git rev-parse HEAD or release tag -->

## What happened

<!-- Describe the behavior. Be specific about what tab was active, what state was expected, and what state was observed. -->

## What you expected

## How to reproduce

1. ...
2. ...
3. ...

## Diagnostics

Please run these and paste the output (it's non-sensitive):

```powershell
# 1. Watcher process running?
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'agent-tabs-watcher' } |
    Select-Object ProcessId, CommandLine | Format-List

# 2. Status files
Get-ChildItem $env:USERPROFILE\.claude\cache\tab_status_*.json |
    Sort-Object LastWriteTime -Descending |
    Select-Object Name, Length, LastWriteTime -First 5 | Format-Table

# 3. Hook registrations (sanitize any unrelated entries before pasting)
Get-Content $env:USERPROFILE\.claude\settings.json -Raw |
    ConvertFrom-Json |
    Select-Object -ExpandProperty hooks |
    ConvertTo-Json -Depth 10
```

```
<paste output here>
```

## Additional context

<!-- Screenshots, logs, anything else. -->
