# Changelog

All notable changes to this project will be documented in this file. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] -- 2026-05-01

### Fixed
- `install.ps1` no longer crashes when actually writing `~/.claude/settings.json`. The script-scope path variable `$Settings` collided with the local `$settings` hashtable inside `Register-Hooks` / `Unregister-Hooks` (PowerShell variables are case-insensitive within a scope, and dynamic scoping walks the caller's locals). When `Save-Settings` was invoked from `Register-Hooks`, its `$Settings` lookup resolved to the caller's hashtable instead of the script-scope path string, causing `Set-Content -LiteralPath` to receive a `Hashtable` and abort. The bug was latent in v0.1.2 because the steady-state idempotent path skips `Save-Settings` entirely (`if (-not $changed) { return }`), and CI never exercised the write path. Renamed the script-scope variable to `$SettingsPath`.

### Added
- `tests/smoke-install.ps1` and a new `install-smoke` CI job exercise `Register-Hooks` / `Save-Settings` against a temp `settings.json`. Asserts the file is actually written, our entries appear, a preexisting unrelated entry survives, the second register is a no-op, and uninstall removes only our entries. The previous CI surface (parse + hook-script smoke + `install.ps1 -DryRun`) never wrote `settings.json`, which is why the case-collision bug shipped green.
- `install.ps1` now wraps its top-level Run block in a dot-source guard (`$MyInvocation.InvocationName -ne '.'`), so tests can pull in `Register-Hooks` etc. without triggering a real install. Running the script normally is unchanged.

### Docs
- `CLAUDE.md` section 8 made the release flow mandatory after any user-facing fix; pushing the fix to `master` is no longer considered "done."

## [0.1.2] -- 2026-05-01

### Fixed
- `install.ps1` no longer requires PowerShell 7. v0.1.1 used `ConvertFrom-Json -AsHashtable` (PS7+ only) in `Load-Settings`, so users on the documented minimum target (PS5.1) hit `A parameter cannot be found that matches parameter name 'AsHashtable'` and Register-Hooks aborted before settings.json was modified. Replaced with a `ConvertTo-HashtableRecursive` helper that walks the PSCustomObject tree returned by PS5.1's `ConvertFrom-Json`.
- `install.ps1` no longer mutates `~/.claude/settings.json` when re-run with everything already registered. Previously Save-Settings was called unconditionally; combined with PS5.1's single-element-array unwrap on `ConvertFrom-Json`, this silently degraded `"Stop": [{...}]` to `"Stop": {...}` (object form) on every idempotent re-run. Now tracks a `$changed` flag and only writes when at least one new entry was added. Also normalizes all event arrays + inner `hooks` arrays before save as a defense against the partial-register case.

## [0.1.1] -- 2026-05-01

### Fixed
- ASCII-only `.ps1` source — non-ASCII characters (em-dash, arrow, box-drawing) in scripts caused `windows-latest` GitHub Actions runner (English-locale PowerShell 5.1) to fail parsing with `TerminatorExpectedAtEndOfString` errors. Local Chinese-locale machines decoded the UTF-8 source correctly and didn't surface the bug. Replaced all non-ASCII with ASCII equivalents.
- BOM-prefixed stdin handling — when a parent process pipes UTF-8-with-BOM into a hook script (PowerShell native pipe between two PS5.1 processes does this), the leading `U+FEFF` made `ConvertFrom-Json` silently return null. `session_id` then fell back to `$PID` and the watcher's liveness check immediately deleted the entry. All hooks now strip the BOM before parsing.
- `tests/smoke.ps1` — reworked to use PowerShell native pipe + array splatting instead of `Start-Process -RedirectStandardInput / -ArgumentList`. The `Start-Process` approach failed in two ways on PS5.1: stdin redirection didn't reliably reach the child, and `-ArgumentList` did not preserve quoting around args containing spaces (`-Message 'Task complete'` was sent as `-Message Task` + positional `complete`).

## [0.1.0] -- 2026-04-30

Initial public release. Extracted from a private multi-Agent project where the panel had been dogfooded for several weeks.

### Added
- 5 hook scripts (`notify-busy`, `notify-done`, `notify-clear`, `notify-resume`, `agent-tabs-watcher`).
- `install.ps1` with `-DryRun`, `-SkipStartup`, `-Update`, `-Uninstall` flags.
- Idempotent merge into `~/.claude/settings.json` (preserves user's other hook entries; SHA256-based file copy skip).
- Startup folder shortcut for auto-launch on login.
- Per-tab dedup via `terminal_pid` (parent process walk; current `$PID` is the short-lived hook process and is never used as the tab identity).
- Liveness check: drops status entries whose owning shell pid has died (= tab closed).
- Taskbar flash with foreground guard (no-op flash on currently-focused host window).
- Window title prefix (`[OK]` / `[WAIT]` / `[!]`).
- Toast notification with cwd-basename suffix (`Claude Code - my-project`).
- WAIT → BUSY auto-recovery on `PreToolUse`.
- UTF-8 stdin force in every hook (PowerShell 5.1 default GBK / cp936 corrupts CC's UTF-8 hook payload — Chinese / Unicode prompts in particular).

### Known limitations
- Windows-only (WinForms-bound panel; `Win32` `FlashWindowEx` etc.).
- Multi-tab terminal hosts (Windows Terminal / Tabby) share one `MainWindowHandle` across all tabs — the panel can bring the host window to front on double-click but cannot focus a specific tab inside it.
- Tested with Claude Code only. Other AI CLIs likely use different stdin payload schemas (`sessionId` camelCase vs `session_id` snake_case, etc.) — see `docs/architecture.md` for details.

[Unreleased]: https://github.com/napheir/claude-code-tabs/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/napheir/claude-code-tabs/releases/tag/v0.1.3
[0.1.2]: https://github.com/napheir/claude-code-tabs/releases/tag/v0.1.2
[0.1.1]: https://github.com/napheir/claude-code-tabs/releases/tag/v0.1.1
[0.1.0]: https://github.com/napheir/claude-code-tabs/releases/tag/v0.1.0
