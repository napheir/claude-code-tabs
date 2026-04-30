# claude-code-tabs

> Always-on-top status panel for [Claude Code](https://docs.claude.com/claude-code) tabs on Windows. Know which tab is busy, which one is waiting on you, and which one just finished — without alt-tabbing through ten terminals.

![status: alpha](https://img.shields.io/badge/status-alpha-orange) ![platform: windows](https://img.shields.io/badge/platform-windows-blue) ![license: MIT](https://img.shields.io/badge/license-MIT-green)

<!-- docs/screenshots/panel.png — replace with real screenshot -->

## What it does

When you run multiple Claude Code sessions in tabs (Windows Terminal / Tabby / Hyper / conhost), the host process shares **one window handle across all tabs**, so you lose track of which tab needs attention. claude-code-tabs adds:

- **Status panel** in the top-right corner showing every active CC tab with state (`BUSY` / `WAITING` / `DONE`), tab name (cwd basename), and age.
- **Taskbar flash** on `Stop` and `Notification` events — so a finished or waiting tab is visible even when the panel isn't.
- **Window title prefix** (`[OK]` / `[WAIT]` / `[!]`) so the title bar itself tells you the state.
- **Toast notification** with the tab name (`Claude Code - my-project`).
- **Double-click panel row** → brings the host window to front.

The panel updates every 2 seconds and self-cleans dead entries (tabs whose shell pid no longer exists).

## Quickstart

**Requires:** Windows 10/11, PowerShell 5.1+ (built in), Claude Code CLI installed.

```powershell
git clone https://github.com/napheir/claude-code-tabs.git
cd claude-code-tabs
./install.ps1
```

That's it. The installer:

1. Copies 5 hook scripts to `~/.claude/hooks/`.
2. Merges 5 hook entries into `~/.claude/settings.json` (preserving any other entries you have).
3. Creates a Startup folder shortcut for the watcher and launches it immediately.

Open a new Claude Code tab — within ~2s the row appears in the panel.

### Install flags

| Flag | Effect |
|------|--------|
| `-DryRun` | Show what would change, don't write anything. |
| `-SkipStartup` | Don't create the Startup shortcut (you'll need to launch the watcher manually). |
| `-Update` | Force-overwrite the hook scripts (default: skip if SHA256 matches). |
| `-Uninstall` | Remove our hook entries from `settings.json`, delete scripts, kill the watcher. |

`settings.json` is backed up to `settings.json.bak` before any write.

## How it works

Five Claude Code hooks collaborate (see `examples/settings.json` for the registration block):

| Event | Script | Effect |
|-------|--------|--------|
| `UserPromptSubmit` | `notify-busy.ps1` | Mark tab `BUSY` when you submit a prompt. |
| `Stop` | `notify-done.ps1` | Mark tab `DONE` + flash + toast when the agent finishes. |
| `Notification` | `notify-done.ps1` | Mark tab `WAITING` + flash + toast when permission is needed. |
| `PreToolUse` | `notify-resume.ps1` | If currently `WAITING`, flip back to `BUSY` (auto-recovery on permit). |
| `SessionStart` | `notify-clear.ps1` | Strip title prefix and remove status file on fresh session start. |

State is exchanged through small JSON files at `~/.claude/cache/tab_status_<session_id>.json`. The watcher (`agent-tabs-watcher.ps1`) polls this directory, deduplicates per-tab, and renders.

For the design rationale (why parent-walk for `terminal_pid`, why force UTF-8 stdin, why per-tab dedup) see [docs/architecture.md](docs/architecture.md).

## Compatibility

| Component | Status |
|-----------|--------|
| Windows 11 + Windows Terminal | ✅ Tested daily |
| Windows 11 + Tabby | ✅ Tested daily |
| Windows 11 + conhost (default cmd) | ✅ Should work |
| Windows 10 + WT 1.x | ⚠️ Likely works, untested |
| Linux | ❌ Not yet — see `os:linux` label |
| macOS | ❌ Not yet — see `os:macos` label |
| **Claude Code** (the only target) | ✅ Tested |
| Other AI CLIs (Cursor / Continue / Codex) | ⚠️ Experimental — different stdin schemas; expect breakage |

Cross-platform contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Troubleshooting

Most issues fall into one of four buckets — see [docs/troubleshooting.md](docs/troubleshooting.md):

- Panel doesn't appear → watcher not running.
- Tab missing from panel → host window doesn't expose `MainWindowHandle`, or hook stdin is mis-encoded.
- Wrong tab name → cwd inference; works on `cd` into project root.
- Title prefix sticks → `notify-clear.ps1` not registered on `SessionStart`.

## Contributing

Issues + PRs welcome. For platform ports (Linux/macOS), please open an issue with the `os:linux` or `os:macos` label first so we can scope the architecture changes (the panel is currently WinForms-bound).

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, parse-check, and smoke test instructions.

## Security

These scripts spawn `powershell.exe` on every Claude Code hook event and write JSON to `~/.claude/cache/`. No network calls. See [SECURITY.md](SECURITY.md) for the full scope.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgments

Built and dogfooded inside a multi-Agent trade-research project. The `terminal_pid` parent-walk + per-tab dedup design came out of a week of "why does the panel show ghost tabs" debugging — see [docs/architecture.md](docs/architecture.md) for the post-mortem.
