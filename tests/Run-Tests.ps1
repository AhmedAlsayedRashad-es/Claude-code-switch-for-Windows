<#
.SYNOPSIS
    Test suite for claude-code-switch.ps1.

.DESCRIPTION
    Every test builds a synthetic sandbox and points the script at it with
    CCSWITCH_SUPPORT_DIR / CCSWITCH_CLAUDE_DIR / CCSWITCH_BACKUP_ROOT. The real
    %APPDATA%\Claude is never read or written by this suite.

    The script under test is run in a child powershell.exe, the same way a user runs it,
    so `exit` codes and the top-level error handler are exercised for real.
#>
[CmdletBinding()]
param([string]$Only)

$ErrorActionPreference = 'Stop'

$ScriptPath  = Join-Path (Split-Path $PSScriptRoot -Parent) 'claude-code-switch.ps1'
$SandboxRoot = Join-Path $PSScriptRoot 'sandbox'

$OLD_ACC = '11111111-1111-1111-1111-111111111111'
$OLD_ORG = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
$NEW_ACC = '22222222-2222-2222-2222-222222222222'
$NEW_ORG = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
$BASES   = @('claude-code-sessions', 'local-agent-mode-sessions')

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()
$script:CurrentTest = ''

# ---- harness ---------------------------------------------------------------------------
function Remove-TestTree {
    # the sandbox contains junctions; a naive -Recurse delete would follow them
    param([string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return }
    $item = Get-Item -LiteralPath $LiteralPath -Force
    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($LiteralPath, $false) }
        else { [IO.File]::Delete($LiteralPath) }
        return
    }
    if (-not $item.PSIsContainer) { [IO.File]::Delete($LiteralPath); return }
    foreach ($e in [IO.Directory]::GetFileSystemEntries($LiteralPath)) { Remove-TestTree $e }
    [IO.Directory]::Delete($LiteralPath, $false)
}

function Assert-That {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Pass++
        Write-Host "    ok   $Message" -ForegroundColor DarkGreen
    }
    else {
        $script:Fail++
        $script:Failures += "$($script:CurrentTest): $Message"
        Write-Host "    FAIL $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    Assert-That ($Expected -eq $Actual) "$Message (expected '$Expected', got '$Actual')"
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    if ($Only -and $Name -notlike "*$Only*") { return }
    $script:CurrentTest = $Name
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor Cyan
    try { & $Body }
    catch {
        $script:Fail++
        $script:Failures += "${Name}: threw - $($_.Exception.Message)"
        Write-Host "    FAIL threw: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function New-Pointer {
    param([string]$Dir, [string]$Title)
    $id = [guid]::NewGuid().ToString()
    $obj = [ordered]@{
        sessionId    = "local_$id"
        cliSessionId = [guid]::NewGuid().ToString()
        cwd          = 'D:\fixture'
        title        = $Title
        model        = 'claude-opus-5'
        lastActivityAt = 1786544725442
    }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $Dir "local_$id.json") -Encoding UTF8
}

function New-Sandbox {
    <# Returns a hashtable of paths. oldCount pointers under OLD, newCount under NEW. #>
    param([string]$Name, [int]$OldCount = 5, [int]$NewCount = 0, [switch]$NoNewOrg)

    $root = Join-Path $SandboxRoot $Name
    Remove-TestTree $root
    $support = Join-Path $root 'support'
    $claude  = Join-Path $root 'claude'
    $backups = Join-Path $root 'backups'

    foreach ($base in $BASES) {
        New-Item -ItemType Directory -Force -Path (Join-Path $support "$base\$OLD_ACC\$OLD_ORG") | Out-Null
        if (-not $NoNewOrg) {
            New-Item -ItemType Directory -Force -Path (Join-Path $support "$base\$NEW_ACC\$NEW_ORG") | Out-Null
        }
    }
    # a non-UUID directory the real app creates; the script must ignore it
    New-Item -ItemType Directory -Force -Path (Join-Path $support "local-agent-mode-sessions\skills-plugin\$OLD_ORG") | Out-Null

    $oldDir = Join-Path $support "claude-code-sessions\$OLD_ACC\$OLD_ORG"
    $newDir = Join-Path $support "claude-code-sessions\$NEW_ACC\$NEW_ORG"
    for ($i = 1; $i -le $OldCount; $i++) { New-Pointer -Dir $oldDir -Title "old session $i" }
    for ($i = 1; $i -le $NewCount; $i++) { New-Pointer -Dir $newDir -Title "new session $i" }

    New-Item -ItemType Directory -Force -Path (Join-Path $claude 'projects\proj') | Out-Null
    '{"type":"user"}' | Set-Content -LiteralPath (Join-Path $claude 'projects\proj\fixture.jsonl') -Encoding UTF8
    '{"model":"opus","permissions":{"allow":["Bash"]}}' | Set-Content -LiteralPath (Join-Path $claude 'settings.json') -Encoding UTF8
    '{"oauthAccount":{"emailAddress":"fixture@example.com"}}' | Set-Content -LiteralPath (Join-Path $root 'claude.json') -Encoding UTF8
    New-Item -ItemType Directory -Force -Path $backups | Out-Null

    # the new account must look fresher than the old one for auto-detection
    foreach ($base in $BASES) {
        $p = Join-Path $support "$base\$OLD_ACC"
        if (Test-Path $p) { (Get-Item $p).LastWriteTimeUtc = (Get-Date).AddDays(-3).ToUniversalTime() }
        $p = Join-Path $support "$base\$NEW_ACC"
        if (Test-Path $p) { (Get-Item $p).LastWriteTimeUtc = (Get-Date).ToUniversalTime() }
    }

    return @{
        Root = $root; Support = $support; Claude = $claude; Backups = $backups
        OldDir = $oldDir; NewDir = $newDir
        ClaudeJson = (Join-Path $root 'claude.json')
    }
}

function Invoke-Ccs {
    param(
        [hashtable]$Sandbox,
        [string[]]$CcsArgs,
        # '0' exercises the real app-detection path instead of short-circuiting it
        [string]$TestMode = '1',
        # process name the script treats as "the desktop app"
        [string]$ProcName
    )
    $env:CCSWITCH_SUPPORT_DIR = $Sandbox.Support
    $env:CCSWITCH_CLAUDE_DIR  = $Sandbox.Claude
    $env:CCSWITCH_CLAUDE_JSON = $Sandbox.ClaudeJson
    $env:CCSWITCH_BACKUP_ROOT = $Sandbox.Backups
    $env:CCSWITCH_TEST_MODE   = $TestMode
    if ($ProcName) { $env:CCSWITCH_PROC_NAME = $ProcName }
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @CcsArgs 2>&1
        $code = $LASTEXITCODE
        return @{ Output = ($out | Out-String); Code = $code }
    }
    finally {
        Remove-Item env:CCSWITCH_SUPPORT_DIR, env:CCSWITCH_CLAUDE_DIR, env:CCSWITCH_CLAUDE_JSON,
        env:CCSWITCH_BACKUP_ROOT, env:CCSWITCH_TEST_MODE, env:CCSWITCH_PROC_NAME -ErrorAction SilentlyContinue
    }
}

function Get-Pointers { param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Filter 'local_*.json' -File -Force -EA SilentlyContinue).Count
}
function Test-Junction { param([string]$P)
    if (-not (Test-Path -LiteralPath $P)) { return $false }
    return [bool]((Get-Item -LiteralPath $P -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}
function Get-Backup { param([hashtable]$S)
    return @(Get-ChildItem -LiteralPath $S.Backups -Directory -Filter 'claude-backup-*' -EA SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1)[0]
}

# ---- tests -----------------------------------------------------------------------------
Remove-TestTree $SandboxRoot
New-Item -ItemType Directory -Force -Path $SandboxRoot | Out-Null
Write-Host "Testing $ScriptPath" -ForegroundColor Cyan
Write-Host "Sandbox  $SandboxRoot" -ForegroundColor DarkGray

Test-Case 'T1 status reports the master and its pointer count' {
    $s = New-Sandbox 't1' -OldCount 7 -NewCount 2
    $r = Invoke-Ccs $s @('-Command', 'status')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match "master: $OLD_ACC / $OLD_ORG - 7 session") 'reports 7 sessions on the master'
    Assert-That ($r.Output -match 'skills-plugin' -eq $false) 'ignores the non-UUID skills-plugin directory'
    Assert-Equal 7 (Get-Pointers $s.OldDir) 'master untouched by a status read'
}

Test-Case 'T2 transfer into a sessionless org creates a junction' {
    $s = New-Sandbox 't2' -OldCount 5 -NewCount 0
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That (Test-Junction $s.NewDir) 'new account org is now a junction'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master still has all 5 pointers'
    Assert-Equal 5 (Get-Pointers $s.NewDir) 'the junction reads through to 5 pointers'
    Assert-That (Test-Junction (Join-Path $s.Support "local-agent-mode-sessions\$NEW_ACC\$NEW_ORG")) 'agent-mode base linked too'
}

Test-Case 'T3 -OnConflict replace stashes existing pointers, then links' {
    $s = New-Sandbox 't3' -OldCount 5 -NewCount 2
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That (Test-Junction $s.NewDir) 'new account org is now a junction'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master still has all 5 pointers'
    $b = Get-Backup $s
    $stash = Join-Path $b.FullName "replaced-dirs\claude-code-sessions-$NEW_ACC\$NEW_ORG"
    Assert-Equal 2 (Get-Pointers $stash) 'both displaced pointers are stashed in the backup'
    Assert-That ($r.Output -match 'stashed 2 pointer file') 'reports the stash'
    Assert-That ($r.Output -match 'new session 1') 'names the sessions leaving the sidebar'
}

Test-Case 'T4 -OnConflict merge copies pointers in and deletes nothing' {
    $s = New-Sandbox 't4' -OldCount 5 -NewCount 2
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'merge')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That (-not (Test-Junction $s.NewDir)) 'no junction was created'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master untouched'
    Assert-Equal 7 (Get-Pointers $s.NewDir) 'new account now holds 2 own + 5 merged'
}

Test-Case 'T5 -OnConflict skip changes nothing' {
    $s = New-Sandbox 't5' -OldCount 5 -NewCount 2
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'skip')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That (-not (Test-Junction $s.NewDir)) 'no junction'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master untouched'
    Assert-Equal 2 (Get-Pointers $s.NewDir) 'new account untouched'
}

Test-Case 'T6 a second run is idempotent' {
    $s = New-Sandbox 't6' -OldCount 5 -NewCount 0
    $null = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match 'already shared') 'reports already shared'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master still has all 5 pointers'
    Assert-That (Test-Junction $s.NewDir) 'junction still in place'
}

Test-Case 'T7 a broken junction is re-pointed' {
    $s = New-Sandbox 't7' -OldCount 4 -NewCount 0
    Remove-TestTree $s.NewDir
    $bogus = Join-Path $s.Root 'gone'
    New-Item -ItemType Directory -Force -Path $bogus | Out-Null
    New-Item -ItemType Junction -Path $s.NewDir -Value $bogus | Out-Null
    Remove-TestTree $bogus     # now the junction dangles
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match 'fixed an existing link') 'reports the repair'
    Assert-Equal 4 (Get-Pointers $s.NewDir) 'junction now reads the master'
    Assert-Equal 4 (Get-Pointers $s.OldDir) 'master intact'
}

Test-Case 'T8 CHARACTERIZATION: how this platform deletes a junction' {
    # Not a test of our code. It pins down what the platform actually does, so the claim
    # in the docs stays honest if someone runs this on a different build. If any line here
    # reports DESTROYED, Remove-TreeSafely is load-bearing on that machine rather than
    # defence in depth.
    function New-HazCase([string]$n) {
        $r = Join-Path $SandboxRoot "t8\$n"
        $m = Join-Path $r 'master'; $p = Join-Path $r 'parent'
        New-Item -ItemType Directory -Force -Path $m, $p | Out-Null
        1..3 | ForEach-Object { "data $_" | Set-Content -LiteralPath (Join-Path $m "f$_.txt") }
        New-Item -ItemType Junction -Path (Join-Path $p 'link') -Value $m | Out-Null
        return @{ Master = $m; Parent = $p; Link = (Join-Path $p 'link') }
    }
    function Assert-TargetSurvived([hashtable]$c, [string]$what) {
        $n = @(Get-ChildItem -LiteralPath $c.Master -File -EA SilentlyContinue).Count
        Assert-That ($n -eq 3) "$what left the junction target intact ($n of 3 files)"
    }

    Write-Host "    platform: PowerShell $($PSVersionTable.PSVersion) on $([Environment]::OSVersion.Version)" -ForegroundColor DarkGray

    $a = New-HazCase 'a'
    try { Remove-Item -LiteralPath $a.Parent -Recurse -Force -EA Stop } catch {}
    Assert-TargetSurvived $a 'Remove-Item -Recurse on the parent'

    $b = New-HazCase 'b'
    try { Remove-Item -LiteralPath $b.Link -Recurse -Force -EA Stop } catch {}
    Assert-TargetSurvived $b 'Remove-Item -Recurse on the link itself'

    $c = New-HazCase 'c'
    try { & cmd.exe /c rmdir /s /q $c.Parent 2>&1 | Out-Null } catch {}
    Assert-TargetSurvived $c 'cmd rmdir /s /q'

    $d = New-HazCase 'd'
    $seen = @(Get-ChildItem -LiteralPath $d.Parent -Recurse -File -Force -EA SilentlyContinue).Count
    Assert-That ($seen -eq 0) "Get-ChildItem -Recurse does not enumerate through the junction (saw $seen)"

    # and the property we actually depend on: our own walker unlinks without following
    $e = New-HazCase 'e'
    Remove-TestTree $e.Parent
    Assert-TargetSurvived $e 'our junction-aware walker'
    Assert-That (-not (Test-Path -LiteralPath $e.Parent)) 'our walker still removed the parent'
}

Test-Case 'T9 rollback restores the pre-state without harming the master' {
    $s = New-Sandbox 't9' -OldCount 6 -NewCount 2
    $r1 = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    Assert-Equal 0 $r1.Code 'transfer succeeded'
    Assert-That (Test-Junction $s.NewDir) 'junction created'

    # the live tree now contains a junction; rollback moves it aside and deletes it.
    # This is the hazard case from T8, exercised end to end.
    $b = Get-Backup $s
    $r2 = Invoke-Ccs $s @('-Command', 'rollback', $b.FullName)
    Assert-Equal 0 $r2.Code 'rollback exit code is 0'
    Assert-Equal 6 (Get-Pointers $s.OldDir) 'MASTER SURVIVED the rollback delete'
    Assert-That (-not (Test-Junction $s.NewDir)) 'junction is gone'
    Assert-Equal 2 (Get-Pointers $s.NewDir) 'the new account got its 2 original pointers back'
    Assert-That (-not (Test-Path (Join-Path $s.Support '.claude-code-sessions.pre-rollback.*'))) 'no leftover scratch dir'
}

Test-Case 'T10 backup does not traverse junctions' {
    $s = New-Sandbox 't10' -OldCount 3 -NewCount 0
    # a junction inside .claude, like the real ~\.claude\agents
    $outside = Join-Path $s.Root 'outside'
    New-Item -ItemType Directory -Force -Path $outside | Out-Null
    1..4 | ForEach-Object { "x" | Set-Content -LiteralPath (Join-Path $outside "big$_.txt") }
    New-Item -ItemType Junction -Path (Join-Path $s.Claude 'agents') -Value $outside | Out-Null

    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    Assert-Equal 0 $r.Code 'exit code is 0'
    $b = Get-Backup $s
    $copied = Join-Path $b.FullName 'dot-claude\agents'
    Assert-That (-not (Test-Path (Join-Path $copied 'big1.txt'))) 'junction contents were NOT copied into the backup'
    $manifest = Get-Content -LiteralPath (Join-Path $b.FullName 'manifest.json') -Raw | ConvertFrom-Json
    Assert-That (@($manifest.reparsePoints).Count -ge 1) 'the junction is recorded in the manifest instead'
    Assert-Equal 4 (@(Get-ChildItem -LiteralPath $outside -File).Count) 'the junction target is untouched'
}

Test-Case 'T11 a failing backup aborts before anything is mutated' {
    $s = New-Sandbox 't11' -OldCount 5 -NewCount 2
    $s2 = $s.Clone()
    $s2.Backups = 'Q:\no-such-drive\backups'      # backup creation must fail here
    $r = Invoke-Ccs $s2 @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    Assert-Equal 1 $r.Code 'exits non-zero'
    Assert-That (-not (Test-Junction $s.NewDir)) 'no junction was created'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master untouched'
    Assert-Equal 2 (Get-Pointers $s.NewDir) 'new account untouched'
    Assert-That ($r.Output -match 'Nothing was changed') 'says nothing was changed'
}

Test-Case 'T12 -DryRun mutates nothing' {
    $s = New-Sandbox 't12' -OldCount 5 -NewCount 2
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace', '-DryRun')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match 'DRY RUN COMPLETE') 'reports a dry run'
    Assert-That (-not (Test-Junction $s.NewDir)) 'no junction created'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master untouched'
    Assert-Equal 2 (Get-Pointers $s.NewDir) 'new account untouched'
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $s.Backups -Directory -EA SilentlyContinue).Count) 'no backup directory created'
}

Test-Case 'T13 retention write preserves unrelated settings keys' {
    $s = New-Sandbox 't13' -OldCount 2 -NewCount 0
    $r = Invoke-Ccs $s @('-Command', 'retention', '-RetentionDays', '3650')
    Assert-Equal 0 $r.Code 'exit code is 0'
    $j = Get-Content -LiteralPath (Join-Path $s.Claude 'settings.json') -Raw | ConvertFrom-Json
    Assert-Equal 3650 $j.cleanupPeriodDays 'cleanupPeriodDays was set'
    Assert-Equal 'opus' $j.model 'unrelated key "model" preserved'
    Assert-Equal 'Bash' $j.permissions.allow[0] 'nested permissions preserved'
    Assert-That (Test-Path (Join-Path $s.Claude 'settings.json.bak')) 'a .bak was written'
}

Test-Case 'T14 the new account is auto-detected when not given' {
    $s = New-Sandbox 't14' -OldCount 5 -NewCount 0
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-OnConflict', 'replace')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match "Detected new account: $NEW_ACC") 'auto-detected the fresher account'
    Assert-That (Test-Junction $s.NewDir) 'junction created'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master intact'
}

Test-Case 'T15 rollback from a non-existent backup path aborts cleanly' {
    # NOTE: this does NOT exercise Assert-SafeTarget - it aborts before any guard runs.
    # The allowlist guard is currently untested; see the design doc's testing section.
    $s = New-Sandbox 't15' -OldCount 3 -NewCount 0
    $r = Invoke-Ccs $s @('-Command', 'rollback', (Join-Path $s.Root 'no-such-backup'))
    Assert-Equal 1 $r.Code 'exits non-zero'
    Assert-That ($r.Output -match 'backup directory not found') 'reports the missing backup'
    Assert-Equal 3 (Get-Pointers $s.OldDir) 'master untouched'
}

# ---- regression tests for bugs found in adversarial review (2026-08-12) ----------------
# Every case below runs with CCSWITCH_TEST_MODE=0 where relevant. The original suite set
# TEST_MODE=1 everywhere, which short-circuited Wait-AppClosed/Get-AppEvidence entirely -
# so a crash on the app-quit path passed 71/71 while being fatal in real use.

Test-Case 'T16 REGRESSION real mode, app quit: transfer completes' {
    # Get-AppEvidence returns an empty array -> the caller receives $null -> $null.Count
    # threw under StrictMode, exactly when the app was correctly quit.
    $s = New-Sandbox 't16' -OldCount 5 -NewCount 2
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace') `
        -TestMode '0' -ProcName 'ccswitch-no-such-process'
    Assert-Equal 0 $r.Code 'exit code is 0 with the app not running'
    Assert-That ($r.Output -notmatch "property 'Count' cannot be found") 'no StrictMode Count crash'
    Assert-That (Test-Junction $s.NewDir) 'junction created'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master intact'
}

Test-Case 'T17 REGRESSION real mode, app running: refuses and changes nothing' {
    # powershell.exe is certainly running - this test host is one
    $s = New-Sandbox 't17' -OldCount 5 -NewCount 2
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace') `
        -TestMode '0' -ProcName 'powershell'
    Assert-Equal 1 $r.Code 'exits non-zero'
    Assert-That ($r.Output -match 'is running') 'reports the app is running'
    Assert-That ($r.Output -notmatch "property 'Count' cannot be found") 'no StrictMode Count crash'
    Assert-That (-not (Test-Junction $s.NewDir)) 'no junction created'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master untouched'
    Assert-Equal 0 (@(Get-ChildItem -LiteralPath $s.Backups -Directory -EA SilentlyContinue).Count) 'no backup written'
}

Test-Case 'T18 REGRESSION dry run with the app quit does not crash' {
    $s = New-Sandbox 't18' -OldCount 4 -NewCount 1
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace', '-DryRun') `
        -TestMode '0' -ProcName 'ccswitch-no-such-process'
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match 'DRY RUN COMPLETE') 'completed the dry run'
    Assert-That (-not (Test-Junction $s.NewDir)) 'nothing changed'
}

Test-Case 'T19 REGRESSION status works with a single account (scalar unroll)' {
    # one UUID dir per base -> the helper returns a scalar, not an array -> .Count threw
    $s = New-Sandbox 't19' -OldCount 3 -NoNewOrg
    $r = Invoke-Ccs $s @('-Command', 'status')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -notmatch "property 'Count' cannot be found") 'no StrictMode Count crash'
    Assert-That ($r.Output -match 'master: ') 'still reports the master'
}

Test-Case 'T20 REGRESSION empty store prints the diagnostic instead of crashing' {
    $s = New-Sandbox 't20' -OldCount 0 -NoNewOrg
    Remove-TestTree (Join-Path $s.Support "claude-code-sessions\$OLD_ACC")
    $r = Invoke-Ccs $s @('-Command', 'status')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -notmatch "property 'Count' cannot be found") 'no StrictMode Count crash'
    Assert-That ($r.Output -match 'Discovery found nothing') 'printed the discovery dump'
    Assert-That ($r.Output -match 'subdirectories : 0') 'dump reports the empty base'
}

Test-Case 'T21 REGRESSION settings.json is written without a BOM' {
    $s = New-Sandbox 't21' -OldCount 2 -NewCount 0
    $r = Invoke-Ccs $s @('-Command', 'retention', '-RetentionDays', '3650')
    Assert-Equal 0 $r.Code 'exit code is 0'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $s.Claude 'settings.json'))
    $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    Assert-That (-not $hasBom) 'no UTF-8 BOM (Set-Content -Encoding UTF8 would add one)'
    Assert-Equal 3650 ((Get-Content -LiteralPath (Join-Path $s.Claude 'settings.json') -Raw | ConvertFrom-Json).cleanupPeriodDays) 'value written'
}

Test-Case 'T22 REGRESSION the backup captures settings.json before retention edits it' {
    $s = New-Sandbox 't22' -OldCount 5 -NewCount 0
    $r = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace', '-RetentionDays', '3650') `
        -TestMode '0' -ProcName 'ccswitch-no-such-process'
    Assert-Equal 0 $r.Code 'exit code is 0'
    $live = Get-Content -LiteralPath (Join-Path $s.Claude 'settings.json') -Raw | ConvertFrom-Json
    Assert-Equal 3650 $live.cleanupPeriodDays 'live settings.json was updated'
    $b = Get-Backup $s
    $saved = Get-Content -LiteralPath (Join-Path $b.FullName 'dot-claude\settings.json') -Raw | ConvertFrom-Json
    Assert-That (-not ($saved.PSObject.Properties.Name -contains 'cleanupPeriodDays')) 'the backup holds the ORIGINAL settings, so the edit is reversible'
}

Test-Case 'T23 rollback verifies the restore before discarding the live tree' {
    $s = New-Sandbox 't23' -OldCount 6 -NewCount 2
    $null = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    $b = Get-Backup $s
    $r = Invoke-Ccs $s @('-Command', 'rollback', $b.FullName)
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match 'verified claude-code-sessions : 8/8') 'reports a verified pointer count'
    Assert-Equal 6 (Get-Pointers $s.OldDir) 'master intact'
    Assert-Equal 2 (Get-Pointers $s.NewDir) 'new account restored'
}

Test-Case 'T24 REGRESSION finds an MSIX/Store install via LocalCache' {
    # Claude Desktop installed from the Store redirects %APPDATA%\Claude into
    # %LOCALAPPDATA%\Packages\<pkg>\LocalCache\Roaming\Claude. A shell outside the package
    # container sees no %APPDATA%\Claude at all, so the default must probe for the package.
    $s = New-Sandbox 't24' -OldCount 6 -NewCount 0
    $fakePackages = Join-Path $s.Root 'Packages'
    $pkgSupport = Join-Path $fakePackages 'Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude'
    New-Item -ItemType Directory -Force -Path (Split-Path $pkgSupport -Parent) | Out-Null
    Move-Item -LiteralPath $s.Support -Destination $pkgSupport

    $env:CCSWITCH_PACKAGES_DIR = $fakePackages
    $env:CCSWITCH_CLAUDE_DIR = $s.Claude
    $env:CCSWITCH_CLAUDE_JSON = $s.ClaudeJson
    $env:CCSWITCH_BACKUP_ROOT = $s.Backups
    $env:CCSWITCH_TEST_MODE = '1'
    try {
        # deliberately NOT setting CCSWITCH_SUPPORT_DIR - auto-detection must find it
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Command status 2>&1 | Out-String
        Assert-That ($out -match 'master: ') 'auto-detected the packaged session store'
        Assert-That ($out -match '6 session') 'read the right pointer count through it'
        Assert-That ($out -match [regex]::Escape('LocalCache\Roaming\Claude')) 'reports the physical package path, not the virtual one'
    }
    finally {
        Remove-Item env:CCSWITCH_PACKAGES_DIR, env:CCSWITCH_CLAUDE_DIR, env:CCSWITCH_CLAUDE_JSON,
        env:CCSWITCH_BACKUP_ROOT, env:CCSWITCH_TEST_MODE -ErrorAction SilentlyContinue
    }
}

Test-Case 'T25 unshare converts junctions back to real directories, keeping the list' {
    $s = New-Sandbox 't25' -OldCount 5 -NewCount 2
    $null = Invoke-Ccs $s @('-Command', 'transfer', '-NonInteractive', '-NewAccount', $NEW_ACC, '-OnConflict', 'replace')
    Assert-That (Test-Junction $s.NewDir) 'precondition: a junction exists'

    $r = Invoke-Ccs $s @('-Command', 'unshare', '-NonInteractive')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That (-not (Test-Junction $s.NewDir)) 'the junction is gone'
    Assert-That (Test-Path -LiteralPath $s.NewDir) 'a real directory is in its place'
    Assert-Equal 5 (Get-Pointers $s.NewDir) 'the merged list survived the conversion'
    Assert-Equal 5 (Get-Pointers $s.OldDir) 'master intact'

    # the whole point: the directory must now be writable in place
    $probe = Join-Path $s.NewDir 'local_writetest.json'
    '{"title":"write test"}' | Set-Content -LiteralPath $probe
    Assert-That (Test-Path -LiteralPath $probe) 'new pointers can be written into it'
    Remove-Item -LiteralPath $probe -Force

    Assert-That (-not (Test-Path -LiteralPath ($s.NewDir + '.ccswitch-converting'))) 'no staging directory left behind'
}

Test-Case 'T26 unshare is a no-op when there are no junctions' {
    $s = New-Sandbox 't26' -OldCount 4 -NewCount 1
    $r = Invoke-Ccs $s @('-Command', 'unshare', '-NonInteractive')
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match 'No junctions found') 'reports nothing to do'
    Assert-Equal 4 (Get-Pointers $s.OldDir) 'master untouched'
    Assert-Equal 1 (Get-Pointers $s.NewDir) 'new account untouched'
}

Test-Case 'T27 reindex rebuilds a pointer from a transcript' {
    $s = New-Sandbox 't27' -OldCount 3 -NewCount 0
    $id = '7f3c1a20-0000-4000-8000-abcdefabcdef'
    $proj = Join-Path $s.Claude 'projects\D--somewhere'
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    @(
        '{"type":"custom-title","customTitle":"A recovered chat","sessionId":"' + $id + '"}'
        '{"type":"user","cwd":"D:\\somewhere","timestamp":"2026-08-14T10:00:00.000Z","message":{"role":"user","content":"hi"}}'
        '{"type":"assistant","timestamp":"2026-08-14T10:05:00.000Z","message":{"role":"assistant","model":"claude-opus-5","content":"yo"}}'
        '{"type":"user","timestamp":"2026-08-14T10:06:00.000Z","message":{"role":"user","content":"more"}}'
    ) | Set-Content -LiteralPath (Join-Path $proj "$id.jsonl") -Encoding UTF8

    $r = Invoke-Ccs $s @('-Command', 'reindex', '-SessionId', $id)
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-Equal 4 (Get-Pointers $s.OldDir) 'a fourth pointer appeared'

    $made = Get-ChildItem -LiteralPath $s.OldDir -Filter 'local_*.json' |
    ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } |
    Where-Object { $_.cliSessionId -eq $id }
    Assert-That ($null -ne $made) 'the new pointer references the transcript'
    Assert-Equal 'A recovered chat' $made.title 'title recovered from the custom-title record'
    Assert-Equal 'user' $made.titleSource 'marked as a user title so the app keeps it'
    Assert-Equal 'D:\somewhere' $made.cwd 'cwd recovered from the transcript'
    Assert-Equal 'claude-opus-5' $made.model 'model recovered'
    Assert-Equal 2 $made.completedTurns 'turn count derived'

    $bytes = [IO.File]::ReadAllBytes((Get-ChildItem -LiteralPath $s.OldDir -Filter 'local_*.json' |
            Where-Object { (Get-Content $_.FullName -Raw) -match [regex]::Escape($id) } | Select-Object -First 1).FullName)
    Assert-That (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) 'written without a BOM'
}

Test-Case 'T28b reindex accepts a comma-joined id list (how -File passes arrays)' {
    $s = New-Sandbox 't28b' -OldCount 2 -NewCount 0
    $proj = Join-Path $s.Claude 'projects\D--multi'
    New-Item -ItemType Directory -Force -Path $proj | Out-Null
    $ids = @('11110000-0000-4000-8000-000000000001', '11110000-0000-4000-8000-000000000002')
    foreach ($i in $ids) {
        @("{`"type`":`"custom-title`",`"customTitle`":`"chat $i`",`"sessionId`":`"$i`"}",
            '{"type":"user","cwd":"D:\\multi","timestamp":"2026-08-14T10:00:00.000Z","message":{"role":"user","content":"hi"}}') |
        Set-Content -LiteralPath (Join-Path $proj "$i.jsonl") -Encoding UTF8
    }
    # exactly what the shell hands over for: -SessionId 'a','b'
    $r = Invoke-Ccs $s @('-Command', 'reindex', '-SessionId', ($ids -join ','))
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-Equal 4 (Get-Pointers $s.OldDir) 'both pointers were rebuilt'
}

Test-Case 'T28 reindex will not duplicate an existing sidebar entry' {
    $s = New-Sandbox 't28' -OldCount 3 -NewCount 0
    $p = @(Get-ChildItem -LiteralPath $s.OldDir -Filter 'local_*.json')[0]
    $existingId = (Get-Content $p.FullName -Raw | ConvertFrom-Json).cliSessionId
    $r = Invoke-Ccs $s @('-Command', 'reindex', '-SessionId', $existingId)
    Assert-Equal 0 $r.Code 'exit code is 0'
    Assert-That ($r.Output -match 'already in the sidebar') 'reports the duplicate'
    Assert-Equal 3 (Get-Pointers $s.OldDir) 'no pointer was added'
}

# ---- summary ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('-' * 60)
if ($script:Fail -eq 0) {
    Write-Host "ALL PASS - $($script:Pass) assertions" -ForegroundColor Green
    exit 0
}
Write-Host "$($script:Pass) passed, $($script:Fail) FAILED" -ForegroundColor Red
foreach ($f in $script:Failures) { Write-Host "  - $f" -ForegroundColor Red }
exit 1
