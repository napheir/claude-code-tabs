# claude-code-tabs - project rules for Claude Code

## 1. What this repo is

Windows-only single-repo small tool: 5 PowerShell hook scripts (`src/notify-*.ps1`)
plus 1 always-on-top watcher (`src/agent-tabs-watcher.ps1`), wired into Claude Code
via `~/.claude/settings.json` hooks by `install.ps1`. PowerShell 5.1+ compatible
(no PS7-only syntax). Single-maintainer project. **Not** a multi-agent system,
not a framework, not a platform.

## 2. Hard constraints for `.ps1` files

These are non-negotiable. Past CI failures and silent prod bugs trace back here.

- **ASCII-only source.** No em-dash, arrow, box-drawing, smart quotes, or any
  non-ASCII character anywhere in `.ps1` files. English-locale PS5.1 fails to
  decode UTF-8 bytes that the editor saved cleanly (v0.1.0 CI fail root cause).
  When in doubt, run `tests/parse.ps1` locally - it grep-checks for non-ASCII.
- **UTF-8 stdin force.** Any script that reads stdin must declare at the top:
  `[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)`
- **BOM strip before `ConvertFrom-Json`.** PS5.1 native pipes inject U+FEFF;
  `ConvertFrom-Json` then throws on the leading BOM. Strip it explicitly.
  See `notify-done.ps1` for the canonical pattern.
- **`$ErrorActionPreference = "SilentlyContinue"` at the top.** Hooks must
  never crash Claude Code. Silent best-effort is the contract.
- **Idempotent.** Re-entering the same hook event with the same input must
  produce the same observable state (status file, window title, taskbar flash).

## 3. Process-tree rules

- `Get-TerminalInfo` (and any analogue) walks **from `$PID`'s parent**, never
  from `$PID` itself. The hook process is short-lived; its parent is the
  long-lived per-tab shell whose pid is `terminal_pid`. Treating `$PID` as
  `terminal_pid` produces a fresh status file every spawn and the watcher
  liveness check deletes it immediately (v0.1.0 fix).
- `terminal_pid` is the watcher's liveness key. Do not invent alternates.

## 4. Win32 call conventions

- **`FlashWindowEx` requires a foreground guard.** Always check
  `GetForegroundWindow() -ne $hwnd` before flashing. Multiple Claude Code tabs
  share the host hwnd; flashing the focused tab is a UX bug.
- **`SetWindowText` strips before prefixing.** Strip any existing
  `^\[(OK|WAIT|!)\]\s*` prefix from the current title before composing the new
  one. Otherwise prefixes stack on retitled windows.

## 5. Test discipline

- `tests/parse.ps1` must pass (CI parse job, ASCII + tokenizer check).
- `tests/smoke.ps1` must pass (CI smoke job, end-to-end hook execution).
- Any `install.ps1` change requires a local `pwsh -File install.ps1 -DryRun`
  run; diff the resulting `~/.claude/settings.json` SHA256 against the prior
  hash to confirm idempotency and that other hook entries are untouched.

## 6. Out of scope - do not do

- **Do not add Codex / Cursor / Continue support.** A Codex integration
  attempt was rolled back at v0.1.0 after six stacked silent-failure modes
  (see `docs/architecture.md` "Why no Codex / Cursor / Continue support").
  Defer until the second tool's hook semantics are documented upstream.
- **Do not edit `~/.claude/hooks/`.** That is the user's live install
  location. This repo is the source; deployment goes through `install.ps1`.
- **Do not introduce** `tracker/`, `skills/`, `memory/`, `proposals/`,
  `.claude/agents/`, or other multi-agent harness subsystems. They are
  designed for long-running multi-domain projects; their ROI is negative
  here. If a real need surfaces, open a GitHub issue first.

## 7. Conventional Commits (no scope)

Imperative mood, lowercase verb, no scope parentheses:

- `fix: strip BOM before ConvertFrom-Json in notify-done`
- `feat: add resume hook wiring`
- `docs: clarify install dry-run flow`
- `chore: bump CI runner image`
- `refactor: extract Get-TerminalInfo`
- `test: cover ASCII enforcement in parse.ps1`

No `(scope)` suffix on the type. One concern per commit.

## 8. Release flow

**This flow is MANDATORY after any commit that changes installed behavior.**
Pushing the fix to `master` is not "done." A user-facing fix that lands on
`master` without a tag bump leaves users on `gh release` / a `git checkout
vX.Y.Z` clone running the broken version. If a session ships such a fix, it
must complete the full flow below before stopping. Test-only, CI-only, and
pure-docs commits do not trigger a release on their own, but if they
accumulate alongside a user-facing fix, they ride the same release.

What counts as user-facing: anything that changes what `install.ps1` does at
runtime, what the hook scripts do at runtime, the watcher's behavior, or
compatibility with documented requirements (PS5.1 / Windows). What does not:
CI workflow edits, new tests, README / CHANGELOG / CLAUDE.md edits, internal
refactors with no behavior change.

Steps:

1. Update `CHANGELOG.md` (Keep-a-Changelog style; bump `[Unreleased]` to a dated section).
2. Tag: `git tag -a vX.Y.Z -m "<release notes>" && git push --tags`. Use an
   annotated tag so step 3's `--notes-from-tag` has content.
3. `gh release create vX.Y.Z --notes-from-tag` (or `--notes-file`).
4. **Do not delete published tags.** When fixing a bug in a shipped release,
   leave the old tag and add a deprecation banner in its release notes
   pointing to the replacement (v0.1.0 -> v0.1.1 -> v0.1.2 already
   demonstrate the pattern).
