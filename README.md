# claude-code-switch — Windows port

Switch Claude desktop-app accounts without losing your session sidebar.

Windows port of [gileneusz/claude-code-switch](https://github.com/gileneusz/claude-code-switch)
(macOS, MIT). Same idea, native tooling: PowerShell 5.1, no dependencies, **directory
junctions instead of symlinks** so no administrator rights are needed.

> Unofficial — not affiliated with or endorsed by Anthropic. Use it with your own
> account(s) and within Anthropic's Terms of Service.

## What's going on

Log out of the Claude desktop app, log in to a different account, and the sidebar looks
empty. Your conversations are fine. The transcripts live on disk and don't care which
account you're on — only the small "pointer" files that build the sidebar sit in a folder
named after your account.

| What | Where | Per-account? |
|---|---|---|
| Conversations (JSONL transcripts) | `%USERPROFILE%\.claude\projects\<proj>\<uuid>.jsonl` | no |
| Sidebar entries (title, cwd, model, pointer) | `%APPDATA%\Claude\claude-code-sessions\<ACCOUNT>\<ORG>\local_*.json` | **yes** |
| Agent-mode sessions | `%APPDATA%\Claude\local-agent-mode-sessions\<ACCOUNT>\<ORG>\` | **yes** |
| Pin order / UI state | Electron localStorage | lost on logout (cosmetic) |

This tool points the new account's folder at the old one, so both share a single list.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built in) or PowerShell 7+
- No admin rights. Junctions (`mklink /J`) don't need elevation
- The Claude desktop app must be **fully quit** for anything that modifies files

## Usage

Always look before you leap:

```powershell
.\claude-code-switch.ps1 status
```

```powershell
.\claude-code-switch.ps1 transfer -DryRun
```

Then the real thing — interactive menu:

```powershell
.\claude-code-switch.ps1
```

Or scripted, with no prompts:

```powershell
.\claude-code-switch.ps1 -Command transfer -NonInteractive -OnConflict replace -RetentionDays 3650
```

Roll back at any time:

```powershell
.\claude-code-switch.ps1 rollback "$env:USERPROFILE\claude-backup-2026-08-12-181500"
```

### Commands

| Command | What it does |
|---|---|
| `status` | Read-only summary: accounts, pointer counts, junctions, retention |
| `transfer` | Back up, then link the new account onto the old one |
| `rollback <dir>` | Restore the session indexes from a backup |
| `retention` | Set `cleanupPeriodDays` in `~\.claude\settings.json` |

### Options

| Option | Effect |
|---|---|
| `-DryRun` | Print the whole plan, change nothing |
| `-OnConflict replace\|merge\|skip\|ask` | What to do when the new account's folder already holds its own sessions |
| `-NewAccount <uuid>` / `-OldAccount <uuid>` | Skip auto-detection |
| `-RetentionDays <n>` | Set retention without prompting |
| `-NoSkillsBackup` | Exclude `.claude\skills` from the backup — much faster, same protection for chats |
| `-Force` | Proceed even though `claude.exe` is running (not recommended) |
| `-NonInteractive` | Never prompt; fail instead of asking |

Environment knobs, same names as the macOS original: `CCSWITCH_SUPPORT_DIR`,
`CCSWITCH_CLAUDE_DIR`, `CCSWITCH_CLAUDE_JSON`, `CCSWITCH_BACKUP_ROOT`, `CCSWITCH_TEST_MODE`.

### `-OnConflict` in detail

If the new account's org folder already contains its own `local_*.json` pointers, a
junction cannot simply be dropped on top of it:

- **`replace`** — stash that folder in the backup, delete it, create the junction. One
  shared list. **The stashed sessions leave the sidebar** until you copy them back; the
  script prints the exact command.
- **`merge`** — copy the old account's pointers into the new folder. Nothing is deleted
  and nothing links, so each account keeps its own list from then on.
- **`skip`** — change nothing.

## Is it safe?

- **It backs up first, every time**, to `%USERPROFILE%\claude-backup-<timestamp>`: both
  session-index trees, `~\.claude`, and `~\.claude.json`. The backup is **verified**
  (pointer-file counts compared) before anything is modified. A failed backup aborts.
- **Your transcripts are never written to.** Only the index is touched. Worst case the
  sidebar looks wrong and a rollback fixes it.
- **Deletes never recurse through a junction.** The script walks trees itself and unlinks
  reparse points with `[System.IO.Directory]::Delete($path, $false)`.
- **Destructive steps are allowlisted** to `%APPDATA%\Claude` and `claude-backup-*`.
- **Backups contain credentials.** `~\.claude.json` holds OAuth tokens. Backups live in
  your home folder and are git-ignored here — never commit or share one.

## Tests

```powershell
.\tests\Run-Tests.ps1
```

71 assertions across 15 cases, run against a synthetic sandbox via `CCSWITCH_SUPPORT_DIR` —
the suite never reads or writes the real `%APPDATA%\Claude`. Covers junction creation,
broken-link repair, all three conflict modes, idempotent re-runs, backup verification
failure, dry-run inertness, rollback, and non-UUID directories.

T8 is a characterization test rather than a test of this code: it measures what the
platform does when you delete a tree containing a junction. On
Windows 10.0.19045 / PowerShell 5.1.19041.6456, `Remove-Item -Recurse`, `rmdir /s /q` and
removing the link directly all unlink correctly and leave the target intact. The
junction-aware walker is therefore defence in depth, not a fix for an observed bug — but
the blast radius is your entire session index, so the script does not delegate that
behaviour to the platform.

## Good to know

- **Retention.** Claude deletes session files older than **30 days** unless
  `cleanupPeriodDays` is set in `~\.claude\settings.json`. If you care about old chats,
  raise it: `.\claude-code-switch.ps1 -Command retention -RetentionDays 3650`.
- **Resuming a long old session** resends its whole context uncached on the first turn —
  slower and pricier. For long chats prefer `/export` and a fresh session.
- **claude.ai website chats are not covered.** Those live on Anthropic's servers, tied to
  the account. This only touches local Code-mode sessions.
- **Pin order** is wiped on every logout; the app clears it, not this script.
- **Unofficial hack.** The app's layout could change in an update. Worst case is an empty
  sidebar — your data stays put. Verified against the layout present on 2026-08-12.

## Differences from the macOS original

| | macOS | this port |
|---|---|---|
| Link type | symlink | directory junction |
| App detection | `lsappinfo`, `pgrep` | `Get-Process claude` |
| JSON handling | `python3` | `ConvertFrom-Json` / `ConvertTo-Json` |
| Copying | `cp -a` | `robocopy /E /XJ` |
| Languages | English + Polish | English |
| Extra | — | `status`, `-DryRun`, `-NonInteractive`, `-OnConflict`, backup verification, test suite |

## License

MIT, same as the original. Credit for the underlying trick goes to the upstream project
and to [@rchybicki](https://x.com/rchybicki).
