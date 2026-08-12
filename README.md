# Claude Code Switch — for Windows

**Switch Claude desktop-app accounts without losing your session sidebar.**

Log out of the Claude desktop app, log in to another account, and the sidebar looks empty.
Your conversations are fine — the transcripts are on disk and don't care which account
you're on. Only the small "pointer" files that *build* the sidebar live in a folder named
after your account. This tool points the new account's folder at the old one, so both
share a single list.

> Windows port of **[gileneusz/claude-code-switch](https://github.com/gileneusz/claude-code-switch)**
> by Mateusz Gilewicz (macOS, MIT). The idea and the original implementation are theirs;
> this is a rewrite in PowerShell with Windows-native mechanics. Credit for the underlying
> trick goes to [@rchybicki](https://x.com/rchybicki), spotted in a thread by
> [@theo](https://x.com/theo).

> **Unofficial.** Not affiliated with or endorsed by Anthropic. Use it with your own
> account(s) and within Anthropic's Terms of Service.

---

## Quick start

Nothing here needs administrator rights. Windows PowerShell 5.1 (built in) is enough.

**1. Look first.** Read-only, safe with the app open:

```powershell
.\claude-code-switch.ps1 status
```

You should see your master account and its session count. If it finds nothing, it prints
every path it probed — see [Troubleshooting](#troubleshooting).

**2. Rehearse.** Still changes nothing:

```powershell
.\claude-code-switch.ps1 transfer -DryRun
```

**3. Do it.** Quit Claude Desktop completely, including the tray icon, then:

```powershell
.\claude-code-switch.ps1
```

The menu walks you through it. Prefer one scripted command? See
[Non-interactive use](#non-interactive-use).

**4. Undo, if you want to.** Every run backs up first and prints its own rollback command:

```powershell
.\claude-code-switch.ps1 rollback "$env:USERPROFILE\claude-backup-<timestamp>"
```

---

## How your sessions are stored

| What | Where | Tied to your account? |
|---|---|---|
| Conversations (JSONL transcripts) | `%USERPROFILE%\.claude\projects\<proj>\<uuid>.jsonl` | no — shared |
| Sidebar entries (title, cwd, model, pointer) | `<support>\claude-code-sessions\<ACCOUNT>\<ORG>\local_*.json` | **yes** |
| Agent-mode sessions | `<support>\local-agent-mode-sessions\<ACCOUNT>\<ORG>\` | **yes** |
| Retention | `%USERPROFILE%\.claude\settings.json` → `cleanupPeriodDays` | no |
| Pin order / UI state | Electron localStorage | lost on logout (cosmetic) |

A pointer file holds `cliSessionId`, `cwd`, `title`, `model` and timestamps — but no
account or org id, which is why pointers move between account folders freely.

### `<support>` is not always `%APPDATA%\Claude`

For a normal installer it is. **For a Microsoft Store (MSIX) install it isn't.** Store apps
run under filesystem virtualization:

| Who's asking | `%APPDATA%\Claude` resolves to |
|---|---|
| A process inside the app's package container | `%LOCALAPPDATA%\Packages\<PackageFamily>\LocalCache\Roaming\Claude` |
| An ordinary PowerShell window | nothing — the folder doesn't exist |

The script probes `%LOCALAPPDATA%\Packages\*\LocalCache\Roaming\Claude` first and prefers
the physical path, falling back to `%APPDATA%\Claude`. `status` always reports which one it
resolved.

This matters beyond discovery: a junction records its target as a *literal string*, so one
written with the virtual path would dangle for every process outside the container —
including a later rollback.

---

## Commands and options

| Command | What it does |
|---|---|
| `status` | Read-only: accounts, pointer counts, junctions, resolved paths, retention |
| `transfer` | Back up, then link the new account onto the old one |
| `rollback <dir>` | Restore the session indexes from a backup |
| `retention` | Set `cleanupPeriodDays` in `~\.claude\settings.json` |
| *(no argument)* | Interactive menu |

| Option | Effect |
|---|---|
| `-DryRun` | Print the whole plan, change nothing |
| `-OnConflict replace\|merge\|skip\|ask` | What to do when the new account's folder already holds its own sessions |
| `-NewAccount <uuid>` / `-OldAccount <uuid>` | Skip auto-detection |
| `-RetentionDays <n>` | Set retention without prompting |
| `-NoSkillsBackup` | Exclude `.claude\skills` from the backup — much faster, same protection for chats |
| `-Force` | Proceed even though the app is running (not recommended) |
| `-NonInteractive` | Never prompt; fail instead of asking |

### `-OnConflict` in detail

If the new account's org folder already contains its own `local_*.json` pointers, a
junction can't simply be dropped on top of it:

- **`replace`** — stash that folder in the backup, delete it, create the junction. One
  shared list. The stashed sessions leave the sidebar until you copy them back; the script
  prints the exact command. *This is a Windows-only extension — the macOS original only
  offers merge/skip here.*
- **`merge`** — copy the old account's pointers into the new folder. Nothing is deleted and
  nothing links, so each account keeps its own list from then on. *This is what macOS does.*
- **`skip`** — change nothing.

Want a single shared list containing everything? Use `replace`, then run the `Copy-Item`
line the script prints, which puts the stashed pointers into the shared folder.

### Non-interactive use

```powershell
.\claude-code-switch.ps1 -Command transfer -NonInteractive -OnConflict replace -RetentionDays 3650
```

Add `-NewAccount <uuid>` to pin the target instead of auto-detecting the freshest account.

### Environment overrides

Same names as the macOS original, plus two test seams:

`CCSWITCH_SUPPORT_DIR`, `CCSWITCH_CLAUDE_DIR`, `CCSWITCH_CLAUDE_JSON`,
`CCSWITCH_BACKUP_ROOT`, `CCSWITCH_TEST_MODE`, `CCSWITCH_PROC_NAME`, `CCSWITCH_PACKAGES_DIR`.

---

## Is it safe?

- **It backs up first, every time**, to `%USERPROFILE%\claude-backup-<timestamp>`: both
  session-index trees, `~\.claude`, and `~\.claude.json`. The backup is **verified** —
  pointer-file counts compared — before anything is modified. A failed backup aborts.
- **Your transcripts are never written to.** Only the index is touched. Worst case the
  sidebar looks wrong and a rollback fixes it.
- **Junction creation is proven before deletion.** A throwaway junction is created and
  removed first, so a permissions failure aborts with everything still intact.
- **Deletes never recurse through a junction.** The script walks trees itself and unlinks
  reparse points with `[System.IO.Directory]::Delete($path, $false)`.
- **Destructive steps are allowlisted** to the resolved support dir and `claude-backup-*`.
- **Backups contain credentials.** `~\.claude.json` holds OAuth tokens. Backups live in
  your home folder and are git-ignored here — never commit or share one.

### Retention — read this even if you skip the rest

Claude deletes session files older than **30 days** unless `cleanupPeriodDays` is set. If
you care about old chats:

```powershell
.\claude-code-switch.ps1 -Command retention -RetentionDays 3650
```

---

## Troubleshooting

**"No desktop sessions found"** — the script prints every path it probed, whether each
exists, and every subdirectory it saw. Read that output. The usual cause is an MSIX install
(see [above](#support-is-not-always-appdataclaude)); the script handles it automatically,
but you can force a location with `$env:CCSWITCH_SUPPORT_DIR`.

**The script behaves differently in your shell than in a clean one** — run it with
`-NoProfile` to rule out a profile that shadows a cmdlet:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-code-switch.ps1 status
```

**"cannot be loaded because running scripts is disabled"** — use the `-NoProfile
-ExecutionPolicy Bypass -File` form above, or unblock the file:

```powershell
Unblock-File .\claude-code-switch.ps1
```

**It refuses to run because the app is running** — quit Claude Desktop completely,
including the tray icon. If you are running this from a terminal *inside* the Claude app,
you cannot complete a transfer: quitting the app ends that session. Use a plain PowerShell
window.

---

## Tests

```powershell
.\tests\Run-Tests.ps1
```

104 assertions across 24 cases, run entirely against a synthetic sandbox — the suite never
reads or writes a real session store. It covers junction creation and repair, all three
conflict modes, idempotent re-runs, backup-verification failure, dry-run inertness,
rollback, MSIX path resolution, and the real (non-test-mode) app-detection path.

T8 is a *characterization* test rather than a test of this code: it measures what the
platform does when you delete a tree containing a junction. On Windows 10.0.19045 /
PowerShell 5.1.19041.6456, `Remove-Item -Recurse`, `rmdir /s /q` and removing the link
directly all unlink correctly and leave the target intact. The junction-aware walker is
therefore defence in depth, not a fix for an observed bug — but the blast radius is your
entire session index, so the script doesn't delegate that behaviour to the platform.

---

## Differences from the macOS original

| | macOS | this port |
|---|---|---|
| Link type | symlink | directory junction (no elevation needed) |
| App detection | `lsappinfo`, `pgrep` | `Get-Process` |
| JSON handling | `python3` | `ConvertFrom-Json` / `ConvertTo-Json` |
| Copying | `cp -a` | `robocopy /E /XJ` |
| Languages | English + Polish | English |
| Store installs | n/a | MSIX/LocalCache path resolution |
| Extra | — | `status`, `-DryRun`, `-NonInteractive`, `-OnConflict`, backup verification, pre-flight junction check, test suite |

---

## Good to know

- **Resuming a long old session** resends its whole context uncached on the first turn —
  slower and pricier. For long chats prefer `/export` and a fresh session.
- **claude.ai website chats are not covered.** Those live on Anthropic's servers, tied to
  the account. This only touches local Code-mode sessions.
- **You don't need this tool to read an old chat.** `cd` to the session's original working
  directory and run `claude --resume`.
- **Unofficial hack.** The app's layout could change in an update. Worst case is an empty
  sidebar — your data stays put.

**Verified on:** Windows 10 Pro 19045, Windows PowerShell 5.1.19041.6456, Claude Desktop
installed as the Store package `Claude_pzs8sxrjxfjjc`, 2026-08-12. A real transfer of 34
orphaned sessions onto a second account completed successfully and the sidebar returned.

---

## For AI agents

If you are an AI agent working on or with this repo, read **[AGENTS.md](AGENTS.md)** first.
It documents the safety invariants and the specific traps that have already caused
failures here.

## License

MIT — see [LICENSE](LICENSE). Original copyright Mateusz Gilewicz; Windows port copyright
Ahmed Rashad.
