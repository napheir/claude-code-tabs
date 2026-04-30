# Contributing

Thanks for considering a contribution. claude-code-tabs is small enough to review casually, but the parts that touch process trees, encoding, and Win32 deserve some discipline. This doc covers the basics.

## Before you start

- **Bug reports**: open an issue with the bug-report template. The PowerShell version, Windows build, and terminal host (Windows Terminal / Tabby / Hyper / conhost) are required — most issues track back to one of those three.
- **Feature ideas**: open a feature-request issue first. The architecture (Win32, WinForms, PowerShell 5.1, file-based IPC) constrains what fits cleanly.
- **Cross-platform ports** (Linux, macOS): open an issue with the `os:linux` or `os:macos` label so we can scope the panel rewrite (the current one is WinForms-bound). Port-specific PRs that don't first agree on architecture will be hard to land.

## Dev environment

- Windows 10 or 11.
- PowerShell 5.1+ (built in) — also test with PowerShell 7 if you have it.
- A working Claude Code install with at least one project to dogfood against.
- Git.

```powershell
git clone https://github.com/<your-fork>/claude-code-tabs.git
cd claude-code-tabs

# Install your fork (overwrites your live hooks — watch out)
./install.ps1 -DryRun        # preview changes
./install.ps1 -Update        # actually apply
```

To revert to upstream while developing:

```powershell
./install.ps1 -Uninstall
git checkout main
./install.ps1
```

## Tests

There are two cheap checks. Run both before submitting a PR.

### Parse check

```powershell
./tests/parse.ps1
```

This calls `[Parser]::ParseFile` on every `.ps1` in `src/` and `install.ps1`. It catches syntax errors before you ship a broken hook to a user.

### Smoke test

```powershell
./tests/smoke.ps1
```

Synthesizes a fake Claude Code stdin payload, pipes it through `notify-busy.ps1` and `notify-done.ps1`, and asserts that `~/.claude/cache/tab_status_*.json` appears with the expected `state`, `cwd`, and `terminal_pid` fields. Cleans up after itself.

CI runs both on `windows-latest`. See `.github/workflows/ci.yml`.

## What's in scope

- Bug fixes for the existing 5 scripts and `install.ps1`.
- New panel features that fit the WinForms model (sorting, filtering, keyboard shortcuts).
- Documentation, screenshots, troubleshooting entries.
- Performance / startup-time improvements.
- Cross-platform ports (architecture discussion first — see above).

## What's out of scope (for now)

- Integration with other AI CLIs (Cursor / Continue / Codex). Each has its own stdin payload schema and sandbox model; the maintainer attempted a Codex port and rolled it back after hitting six layers of silent failure (sandbox `writable_roots`, `sessionId` vs `session_id`, multi-hook semantics, etc.). PRs welcome but expect deep review.
- A full GUI rewrite (Electron, Tauri, etc.). The current WinForms panel is < 250 lines; the constraint is feature, not framework.
- Telemetry, analytics, or anything that calls out over the network.

## Code style

- Hook scripts must:
  - Force UTF-8 stdin: `[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)`.
  - Wrap stdin parsing in try/catch.
  - Walk parent process chain starting from `$PID`'s parent (never use `$PID` itself as `terminal_pid`).
  - Set `$ErrorActionPreference = "SilentlyContinue"` at the top (hooks must never crash CC).
  - Be idempotent — running twice produces the same result.
- ASCII-only string literals in `.ps1` files. PowerShell 5.1 defaults to GBK source decoding on Chinese Windows; non-ASCII text will mojibake when the file is interpreted in the wrong code page.
- Use `Set-Content -Encoding utf8` (no BOM) when writing JSON status files.
- Comment the *why*, not the *what*. Especially for any non-obvious Win32 / process / encoding workaround — the next maintainer will thank you.

## PR checklist

- [ ] `./tests/parse.ps1` passes.
- [ ] `./tests/smoke.ps1` passes.
- [ ] CHANGELOG.md updated under `## [Unreleased]`.
- [ ] If touching a hook script: dogfooded for at least one CC session before submitting.
- [ ] If touching `install.ps1`: ran `-DryRun` and verified the diff against a real `~/.claude/settings.json` that has *other* hook entries (must not lose them).

## Releases

The maintainer cuts releases manually:

1. Bump version in CHANGELOG.md (`## [Unreleased]` → `## [x.y.z] — YYYY-MM-DD`, add new empty `## [Unreleased]`).
2. Tag: `git tag -a vx.y.z -m "Release vx.y.z"`.
3. Push: `git push origin master --tags`.
4. Create a GitHub release with the CHANGELOG section as the body.

Semantic versioning: breaking changes to `settings.json` schema or `tab_status_*.json` format = major. New hook events / new flags = minor. Bug fixes = patch.
