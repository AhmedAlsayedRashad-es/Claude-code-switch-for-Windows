# Instructions for AI agents

You are operating on a tool that modifies the index of a user's **irreplaceable chat
history**. Read this fully before running or changing anything.

## The one rule

**Never run `transfer` or `rollback` against a real session store without the user's
explicit, in-conversation approval for that specific run.** `status` and `-DryRun` are
read-only and safe. Everything else writes.

If you are running inside the Claude desktop app, you **cannot** perform the real
transfer: it requires the app to be fully quit, which ends your session. Prepare and
verify, then hand the user the exact command. Do not attempt to work around this.

## Before you touch anything

```powershell
.\claude-code-switch.ps1 -Command status
```

Confirm the reported `support dir`, the master account, and the pointer counts match what
the user expects. If discovery fails the script prints every path it probed — read that
output rather than guessing.

## Where the data actually is

| What | Path | Safe to modify? |
|---|---|---|
| Transcripts (the chats) | `%USERPROFILE%\.claude\projects\<proj>\<cliSessionId>.jsonl` | **never** |
| Sidebar pointers | `<support>\claude-code-sessions\<ACCOUNT>\<ORG>\local_*.json` | only via this tool |
| Agent-mode sessions | `<support>\local-agent-mode-sessions\<ACCOUNT>\<ORG>\` | only via this tool |
| Retention | `%USERPROFILE%\.claude\settings.json` → `cleanupPeriodDays` | via `-Command retention` |

`<support>` is **not reliably `%APPDATA%\Claude`.** See the MSIX section below — this has
already caused one real failure.

## Traps that have actually bitten

These are not hypothetical. Each one was hit during development.

### 1. MSIX virtualization makes `%APPDATA%` mean two different things

Claude Desktop is often a Microsoft Store package. Inside the package container
`%APPDATA%\Claude` is redirected to
`%LOCALAPPDATA%\Packages\<PackageFamily>\LocalCache\Roaming\Claude`; outside it, that
folder does not exist at all.

If you run checks from a shell spawned by the app, you are seeing the redirected view and
**your findings do not describe what the user's own shell sees.** Verify from a plain
PowerShell window, or trust `status`, which resolves the physical path deliberately.

Junctions store their target as a literal string, so one written with the virtual path
dangles for every process outside the container.

### 2. On MSIX installs the app cannot write through a junction

The most damaging bug found so far, and it is silent. After a `replace` transfer on a Store
install, the app continued writing every other file in its support folder but stopped
writing session pointers entirely. New chats vanished on restart and renames reverted, for
two days, before anyone noticed.

If a user reports disappearing or reverting sessions, check the newest `local_*.json` in
the index against the transfer time. If nothing has been written since, that is this bug.
The fix is `-Command unshare`. Prefer `-OnConflict merge` on Store installs.

### 3. `Set-StrictMode` + `.Count` on a function's return value

A PowerShell function returning a 0- or 1-element array hands the caller `$null` or a bare
scalar. Under `Set-StrictMode`, `.Count` on either **throws**. This made the tool crash in
the exact state it requires (the app quit) while 71 tests passed.

**Wrap every collection-returning call in `@( )`.** The existing code does; keep it that
way.

### 4. `CCSWITCH_TEST_MODE=1` hides the app-detection path

It short-circuits `Wait-AppClosed` and `Get-AppEvidence`. Tests that set it prove nothing
about real-mode behaviour. Use `-TestMode '0' -ProcName 'ccswitch-no-such-process'` in
`Invoke-Ccs` to exercise the real path with the app simulated as quit.

### 5. `Set-Content -Encoding UTF8` writes a BOM on PowerShell 5.1

`settings.json` must stay BOM-free. Use
`[IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false)))`.

### 6. `Get-ChildItem` can be shadowed by a user's profile

Discovery uses `[IO.Directory]` for this reason. Do not replace it with `Get-ChildItem`,
and do not add `-ErrorAction SilentlyContinue` to enumeration — a swallowed error looks
identical to "no sessions found".

## Testing

```powershell
.\tests\Run-Tests.ps1
```

116 assertions across 26 cases, entirely against a synthetic sandbox
(`CCSWITCH_SUPPORT_DIR`). The suite never reads or writes a real session store.

**If you add a safety property, add a test that fails without it.** Verify this by
reverting your change and watching the test go red — several tests in this repo originally
passed against broken code, which is how the critical bug survived.

Test seams available: `CCSWITCH_SUPPORT_DIR`, `CCSWITCH_CLAUDE_DIR`, `CCSWITCH_CLAUDE_JSON`,
`CCSWITCH_BACKUP_ROOT`, `CCSWITCH_TEST_MODE`, `CCSWITCH_PROC_NAME`, `CCSWITCH_PACKAGES_DIR`.

## If you change the destructive path

`Invoke-LinkOrg`, `Invoke-Unshare` and `Invoke-Rollback` are the only functions that delete. Preserve these
invariants:

1. A verified backup exists before any mutation. Verification compares pointer-file counts.
2. Displaced pointers are copied and **count-verified** before the original is removed.
3. Junction creatability is proven (`Test-JunctionCreatable`) **before** the directory it
   replaces is deleted.
4. Deletes go through `Remove-TreeSafely`, which unlinks reparse points instead of
   recursing through them.
5. Destructive paths pass `Assert-SafeTarget` — under the support dir or a `claude-backup-*`
   directory, nothing else.

## Background

`docs/DESIGN.md` records why the port is built the way it is, including the field failures
that shaped it. Read it before changing discovery, backup, or the linking logic.

## Reporting to the user

State what you verified and how. If you claim something is safe, say what you measured.
Do not describe a run as successful without checking the resulting pointer counts.
