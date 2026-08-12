# Claude Code Switch for Windows — design

Date: 2026-08-12
Status: approved

## Problem

The Claude desktop app keys its session sidebar by account UUID. After logging out and
into a different account the sidebar looks empty, because it now reads a different
folder. The transcripts themselves are untouched.

Observed on this machine (2026-08-12):

| Account | Org | Pointers | Range |
|---|---|---|---|
| `a91f3470-d09b-46e3-b495-6740149d38d1` | `62e332bf-3ee4-454c-9155-1b2f0059b698` | 34 | 6 Jul → 12 Aug 16:52 |
| `4fbee629-690c-4ee0-b1c5-d1eb6561197c` | `1381aefe-c861-419b-a5c5-908cc369ca21` | 2 | 12 Aug 17:25, 17:30 |

All 34 orphaned pointers resolve to transcripts that exist on disk (verified: found=34,
missing=0). Nothing is lost; the index is merely orphaned.

`gileneusz/claude-code-switch` solves this on macOS by symlinking the new account's
session-index folder onto the old one. This document specifies a Windows port.

## Storage layout (Windows)

| What | Where | Per-account? |
|---|---|---|
| Transcripts | `%USERPROFILE%\.claude\projects\<proj>\<cliSessionId>.jsonl` | no |
| Sidebar pointers | `%APPDATA%\Claude\claude-code-sessions\<ACCOUNT>\<ORG>\local_*.json` | yes |
| Agent-mode sessions | `%APPDATA%\Claude\local-agent-mode-sessions\<ACCOUNT>\<ORG>\` | yes |
| Retention setting | `%USERPROFILE%\.claude\settings.json` → `cleanupPeriodDays` | no |

A pointer file carries `cliSessionId`, `cwd`, `title`, `model`, timestamps. It contains
no account or org identifier, so pointers are portable between account folders.

Non-UUID directories exist and must be ignored (e.g. `local-agent-mode-sessions\skills-plugin`).

## Platform mapping

| macOS | Windows |
|---|---|
| `~/Library/Application Support/Claude` | `%APPDATA%\Claude` |
| `ln -s` symlink | **directory junction** (`New-Item -ItemType Junction`) — no admin required |
| `lsappinfo` / `pgrep` | `Get-Process claude` |
| `stat -f %m` | `.LastWriteTimeUtc` |
| `python3` for JSON | `ConvertFrom-Json` / `ConvertTo-Json -Depth 100` |
| `cp -a` | `robocopy /E /XJ` |
| `du -sh` | `Measure-Object -Property Length -Sum` |
| `set -Eeuo pipefail` | `$ErrorActionPreference = 'Stop'` + `Set-StrictMode` + `trap` |

Environment knobs keep the original names so tests and power users transfer over:
`CCSWITCH_SUPPORT_DIR`, `CCSWITCH_CLAUDE_DIR`, `CCSWITCH_CLAUDE_JSON`,
`CCSWITCH_BACKUP_ROOT`, `CCSWITCH_TEST_MODE`.

English only; the Polish half of the original string table is dropped.

## Safety rules

These rules are the core of the port:

1. **Deletes never recurse through a reparse point.** `Remove-TreeSafely` walks entries
   itself and unlinks reparse points with `[System.IO.Directory]::Delete($path, $false)`.

   Measured on Windows 10.0.19045 / PowerShell 5.1.19041.6456 (`tests/Run-Tests.ps1` T8),
   `Remove-Item -Recurse`, `rmdir /s /q`, and removing a junction directly all already
   unlink correctly and leave the target intact; `[IO.Directory]::Delete($p, $true)`
   throws. So this rule does not fix a bug observed on that build. It is kept because the
   blast radius is the master session index, and because the behaviour should be ours
   rather than the platform's.
2. **Copy never follows reparse points.** `robocopy /XJ`; junctions under `~\.claude`
   (3 on this machine) are recorded in the `reparsePoints` field of `manifest.json`
   instead of being traversed.

   Known limitation: junctions **inside the session store** are not recorded anywhere. A
   backup taken after a previous transfer therefore omits the junctioned org directories,
   and restoring it silently drops the linked state (the app recreates a plain directory).
   Not relevant to a first run, when no junctions exist yet.
3. **Refuse to run while `claude.exe` is alive**, with an explicit force override.
   The app holds open handles on the index folder and rewrites it continuously.
4. **Path allowlist before any destructive step**: the target must resolve under
   `%APPDATA%\Claude` or under a `claude-backup-*` directory.
5. **Backup verified before mutation**: `local_*.json` counts are compared between
   source and backup; a mismatch aborts before anything is changed.
6. **`-DryRun`** prints the full plan and touches nothing.
7. Transcripts under `.claude\projects` are never written to. Only the index is touched.

## Behaviour

Commands: `status`, `transfer`, `rollback <dir>`, `retention`, plus an interactive menu.

`transfer`:

1. Find master = the physical (non-junction) `<account>\<org>` under `claude-code-sessions`
   holding the most `local_*.json`.
2. Offer the retention change (`cleanupPeriodDays`, default 3650).
3. Require the app closed.
4. Back up to `%USERPROFILE%\claude-backup-<timestamp>`: both index trees, `~\.claude`,
   `~\.claude.json`. Verify, then proceed.
5. Wait for the user to log in to the new account and quit the app; detect the new
   account as the newest non-master UUID directory across both bases.
6. For each `<base>\<newAccount>\<org>`, link it to the master:

   | State of target | Action |
   |---|---|
   | already resolves to master | no-op |
   | junction pointing elsewhere / broken | re-point |
   | real dir, 0 pointers | stash to backup, delete, junction |
   | real dir, N>0 pointers | `-OnConflict`: `replace` (stash+junction), `merge` (copy master's in), `skip` |

**Decision for this machine:** the new account's folder holds 2 live pointers, so the
`N>0` branch applies and the chosen action is `replace`.

**Correction (2026-08-12, post-review):** `replace` on a folder that holds its own
sessions was described to the user as "exact Mac parity". That is wrong. The macOS script
(`claude-code-switch.sh:419-431`) offers only merge/skip when `n>0` and never deletes a
session-holding directory; it stash-replaces sessionless directories only. `replace` in
the `N>0` case is a Windows-only extension introduced here. It remains safe (stash +
verified backup + printed restore command), but the parity justification was false and the
user's choice was made partly on it.

**Final decision (2026-08-12, after the correction above):** keep `replace`, then copy the
two stashed pointers into the shared master folder. End state is a single shared list of
36 sessions visible from both accounts, with nothing left behind in the backup only. The
script prints the exact copy command at the end of a transfer.

`rollback` moves the live index trees aside (rename, not delete), copies the backup in,
and only then removes the moved-aside copies — via `Remove-TreeSafely`, because they may
contain junctions from a previous run.

Backup default is full Mac parity (~1.6 GB here). `-NoSkillsBackup` excludes
`.claude\skills` (1,281 MB of reproducible package content), giving ~320 MB with the same
protection for chats.

## Testing

Everything is tested against a synthetic sandbox via `CCSWITCH_SUPPORT_DIR`; the real
index is only ever read until the user runs the final apply themselves.

1. `status` reports the master and counts
2. transfer into a sessionless org → junction created, master intact
3. transfer into an org with own pointers, `-OnConflict replace` → stashed, junction created
4. `-OnConflict merge` → master's pointers copied in, no junction, nothing deleted
5. `-OnConflict skip` → nothing changes
6. idempotent re-run → "already shared"
7. broken junction → re-pointed
8. **junction-delete hazard**: `Remove-TreeSafely` over a tree containing a junction
   leaves the target's files intact (the test that matters most)
9. backup does not traverse junctions
10. rollback restores the pre-state and leaves the master intact
11. backup verification mismatch aborts before mutation
12. non-UUID directories (`skills-plugin`) ignored
13. retention read/write preserves unrelated keys
14. `-DryRun` mutates nothing

Then `-DryRun` against live data (read-only), and the user runs the apply with the app
closed.
