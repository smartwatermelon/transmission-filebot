# Transmission-Plex Media Manager (Archived)

> **This repository has been consolidated into [mac-server-setup](https://github.com/smartwatermelon/mac-server-setup).**
>
> As of April 2026, the media processing pipeline (transmission-done.sh),
> installation wizard, BATS test suite, and all documentation now live in the
> mac-server-setup repository. This repo is archived for historical reference only.

## Where things moved

| This repo | mac-server-setup |
|---|---|
| `transmission-done.sh` | `app-setup/templates/transmission-done.sh` |
| `install.sh` | `app-setup/transmission-filebot-setup.sh` |
| `process-media.command` | `app-setup/templates/process-media.command` |
| `config.yml.template` | `app-setup/templates/config.yml.template` |
| `run_tests.sh` | `run_tests.sh` |
| `test/` | `tests/transmission-filebot/` |
| `CLAUDE.md` | `docs/apps/transmission-filebot-README.md` |
| `CREATE_AUTOMATOR_APP.md` | `docs/apps/transmission-filebot-automator.md` |

## What changed during import

- Inline `TEST_MODE` test infrastructure was removed (BATS suite is the safety net)
- All hardcoded paths updated for the new directory layout
- Config template placeholders follow the `__CONVENTION__` pattern
- Config file now written with mode 600 (Plex token protection)
- BATS tests run in CI via the mac-server-setup workflow

## Why

The media processing pipeline is an integral part of the server — maintaining it as a
separate repo created friction (separate CI, separate PRs, cross-repo path references)
without benefit. The consolidation plan is documented in
`docs/plans/2026-04-03-repo-consolidation.md` in mac-server-setup.
