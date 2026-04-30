---
name: Feature request
about: Suggest a new feature or enhancement
title: "[feat] "
labels: enhancement
assignees: ''
---

## Problem

<!-- What are you trying to do that the current panel makes hard? -->

## Proposed solution

<!-- What would make it easier? Be concrete. -->

## Alternatives considered

<!-- What other approaches have you tried or thought about, and why aren't they sufficient? -->

## Architecture impact

<!-- Optional, but appreciated. The current architecture is:

- WinForms panel (Windows-only)
- File-based IPC via ~/.claude/cache/tab_status_*.json
- 5 hook scripts firing on Claude Code events
- 2-second polling refresh

Does your proposal fit cleanly, or would it require changes to one of the above? -->

## Out-of-scope check

This project is intentionally narrow. Before opening, please confirm your idea is **not** one of:

- [ ] Cross-platform port (Linux/macOS) — open with `os:linux` / `os:macos` label instead
- [ ] Integration with another AI CLI (Cursor/Continue/Codex) — see `docs/architecture.md` "Why no Codex/Cursor/Continue support"
- [ ] Network telemetry / analytics
- [ ] Full GUI rewrite (Electron, etc.)

If you ticked any of the above, the issue is welcome but expect a longer discussion before any implementation.
