<!-- Thanks for the PR. Please fill out the relevant sections. -->

## Summary

<!-- One paragraph: what does this change and why? -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation only
- [ ] Refactor (no behavior change)
- [ ] Test / CI infrastructure
- [ ] Cross-platform port

## Testing

- [ ] `./tests/parse.ps1` passes
- [ ] `./tests/smoke.ps1` passes
- [ ] Dogfooded with at least one real Claude Code session

If you skipped any of the above, explain why:

<!-- e.g., "docs only" or "Linux port — Windows tests N/A; ran ./tests/parse.sh" -->

## Linked issue

<!-- Closes #X / Refs #Y -->

## Checklist

- [ ] Code changes ASCII-only in `.ps1` files (PS 5.1 GBK-decoding hazard)
- [ ] Hook scripts that read stdin force UTF-8: `[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)`
- [ ] Process tree walks start at parent, never at `$PID`
- [ ] `CHANGELOG.md` updated under `## [Unreleased]`
- [ ] If touching `install.ps1`: ran `-DryRun` against a `settings.json` with non-trivial existing entries; verified no entries lost

## Screenshots / output

<!-- Optional. For panel changes, a before/after screenshot is gold. -->
