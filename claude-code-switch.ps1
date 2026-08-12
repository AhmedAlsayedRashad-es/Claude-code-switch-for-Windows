<#
.SYNOPSIS
    Claude Code Switch for Windows - switch Claude desktop-app accounts without losing
    your session sidebar.

.DESCRIPTION
    The Claude desktop app keys its session sidebar by account UUID. Log out and into a
    different account and the sidebar looks empty - but every transcript is still on disk
    under %USERPROFILE%\.claude\projects. Only the small "pointer" files that build the
    sidebar live in a per-account folder.

    This script backs everything up, then replaces the new account's session-index folder
    with a directory junction onto the old account's folder, so all accounts share one
    session list.

    Windows port of gileneusz/claude-code-switch (macOS, MIT). Junctions are used instead
    of symlinks because they need no administrator rights. Junctions are also more
    dangerous than symlinks - several Windows APIs recurse straight through them - so
    every delete in this script goes through Remove-TreeSafely and every copy through
    robocopy /XJ.

    Your transcripts are never written to. Only the index is touched.

.PARAMETER Command
    status     Read-only summary of accounts, pointer counts and junctions.
    transfer   The main flow: back up, then link the new account onto the old one.
    rollback   Restore the session indexes from a backup directory.
    retention  Change cleanupPeriodDays in ~\.claude\settings.json.
    menu       Interactive menu (default).

.PARAMETER Path
    For 'rollback': the backup directory to restore from.

.PARAMETER OnConflict
    What to do when the new account's org folder already holds its own pointers:
      replace  stash the folder in the backup, delete it, create the junction.
               NOTE: this is a Windows-only extension. The macOS original only ever
               offers merge/skip for a folder that holds its own sessions; it
               stash-replaces sessionless folders only.
      merge    copy the old account's pointers in; both accounts keep separate lists
      skip     leave it alone
      ask      prompt (default)

.PARAMETER DryRun
    Print the full plan without changing anything.

.PARAMETER Force
    Continue even though claude.exe is running. Not recommended.

.PARAMETER NoSkillsBackup
    Exclude ~\.claude\skills from the backup. Same protection for your chats, much faster.

.EXAMPLE
    .\claude-code-switch.ps1 status

.EXAMPLE
    .\claude-code-switch.ps1 transfer -DryRun

.EXAMPLE
    .\claude-code-switch.ps1 rollback "$env:USERPROFILE\claude-backup-2026-08-12-181500"

.NOTES
    Unofficial. Not affiliated with or endorsed by Anthropic. Use with your own accounts
    and within Anthropic's Terms of Service.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'status', 'transfer', 'rollback', 'retention')]
    [string]$Command = 'menu',

    [Parameter(Position = 1)]
    [string]$Path,

    [string]$OldAccount,
    [string]$NewAccount,

    [ValidateSet('replace', 'merge', 'skip', 'ask')]
    [string]$OnConflict = 'ask',

    [int]$RetentionDays = 0,

    [switch]$DryRun,
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$NoSkillsBackup
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$VERSION = '1.0.1-windows'

# ---- configuration (env-overridable, same names as the macOS original) ------------------
function Get-Env([string]$name, [string]$fallback) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $fallback }
    return $v
}

$SupportDir = Get-Env 'CCSWITCH_SUPPORT_DIR' (Join-Path $env:APPDATA 'Claude')
$ClaudeDir  = Get-Env 'CCSWITCH_CLAUDE_DIR'  (Join-Path $env:USERPROFILE '.claude')
$ClaudeJson = Get-Env 'CCSWITCH_CLAUDE_JSON' (Join-Path $env:USERPROFILE '.claude.json')
$BackupRoot = Get-Env 'CCSWITCH_BACKUP_ROOT' $env:USERPROFILE
$TestMode   = (Get-Env 'CCSWITCH_TEST_MODE' '0') -eq '1'
$UiMode     = Get-Env 'CCSWITCH_UI' 'auto'
# process name to treat as "the desktop app". Overridable so the test suite can exercise
# the real (non-TEST_MODE) app-detection path against a process it controls.
$ProcName   = Get-Env 'CCSWITCH_PROC_NAME' 'claude'

$BASES = @('claude-code-sessions', 'local-agent-mode-sessions')
$UUID_RE = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$DEFAULT_RETENTION = 3650

# Mutable state shared between steps.
$script:Backup   = ''
$script:OldAcc   = ''
$script:OldOrg   = ''
$script:SessCount = 0
$script:NewAcc   = ''
$script:NewOrgs  = @()
$script:Changes  = @()

# ---- output ----------------------------------------------------------------------------
function Write-Info([string]$m) { Write-Host "==> $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err ([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red }
function Write-Plain([string]$m) { Write-Host $m }
function Write-Head([string]$m) { Write-Host $m -ForegroundColor Cyan }

function Write-Act([string]$m) {
    # every mutation announces itself the same way, dry-run or not
    if ($DryRun) { Write-Host "    [dry-run] $m" -ForegroundColor DarkGray }
    else { Write-Host "    $m" -ForegroundColor Gray; $script:Changes += $m }
}

# ---- reparse-point primitives ----------------------------------------------------------
# Everything dangerous on Windows funnels through these four functions.

function Test-IsReparse {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $false }
    $item = Get-Item -LiteralPath $LiteralPath -Force
    return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-ReparseTarget {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force
    $t = $null
    if ($item.PSObject.Properties.Name -contains 'Target') { $t = $item.Target }
    if ($null -eq $t) { return $null }
    if ($t -is [System.Collections.IEnumerable] -and $t -isnot [string]) {
        $first = $null
        foreach ($x in $t) { $first = $x; break }
        $t = $first
    }
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    # junction targets can come back in NT form
    return ([string]$t) -replace '^\\\?\?\\', ''
}

function Resolve-PhysicalDir {
    <#  Windows analogue of `cd "$d" && pwd -P` - follow junctions to the real directory,
        so a third account never produces a chain of links. #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    $current = $LiteralPath
    for ($i = 0; $i -lt 16; $i++) {
        if (-not (Test-Path -LiteralPath $current)) { break }
        if (-not (Test-IsReparse $current)) { break }
        $target = Get-ReparseTarget $current
        if ($null -eq $target) { break }
        if (-not [IO.Path]::IsPathRooted($target)) {
            $target = Join-Path (Split-Path $current -Parent) $target
        }
        $current = $target
    }
    try { return [IO.Path]::GetFullPath($current).TrimEnd('\') }
    catch { return $current.TrimEnd('\') }
}

function New-Junction {
    param(
        [Parameter(Mandatory)][string]$LinkPath,
        [Parameter(Mandatory)][string]$TargetPath
    )
    Assert-SafeTarget $LinkPath
    Write-Act "junction: $LinkPath  ->  $TargetPath"
    if ($DryRun) { return }

    $parent = Split-Path $LinkPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    try {
        New-Item -ItemType Junction -Path $LinkPath -Value $TargetPath -ErrorAction Stop | Out-Null
    }
    catch {
        # older/locked-down hosts: fall back to mklink, which needs no elevation for /J.
        # No 2>&1 here: with $ErrorActionPreference='Stop', redirecting a native command's
        # stderr throws on the first stderr line, which would pre-empt the exit-code check
        # below and surface a raw NativeCommandError instead of a useful message.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & cmd.exe /c mklink /J $LinkPath $TargetPath
            $rc = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $prev }
        if ($rc -ne 0) { throw "could not create junction ${LinkPath} (mklink exit $rc): $out" }
    }
    if (-not (Test-IsReparse $LinkPath)) { throw "junction was not created: $LinkPath" }
}

function Remove-Link {
    <# Unlink a junction WITHOUT touching whatever it points at. #>
    param([Parameter(Mandatory)][string]$LinkPath)
    Assert-SafeTarget $LinkPath
    if (-not (Test-IsReparse $LinkPath)) { throw "refusing to unlink a non-link: $LinkPath" }
    Write-Act "unlink (link only, target untouched): $LinkPath"
    if ($DryRun) { return }
    [IO.Directory]::Delete($LinkPath, $false)
}

function Remove-TreeSafely {
    <#  Recursive delete that never follows a reparse point.

        Measured on Windows 10.0.19045 / PowerShell 5.1.19041.6456, `Remove-Item -Recurse`
        already unlinks junctions correctly rather than deleting through them, as do
        `rmdir /s` and removing the link directly. This function does not fix an observed
        bug on that build.

        It is kept because the blast radius is the master session index, the exact thing
        this tool exists to protect, and because "which delete API on which build follows a
        reparse point" is not a property worth betting a user's chat history on. Walking
        the tree ourselves makes the behaviour ours rather than the platform's. #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    Assert-SafeTarget $LiteralPath
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return }

    if ($DryRun) { Write-Act "delete tree: $LiteralPath"; return }

    $item = Get-Item -LiteralPath $LiteralPath -Force

    if ([bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($LiteralPath, $false) }
        else { [IO.File]::Delete($LiteralPath) }
        return
    }

    if (-not $item.PSIsContainer) {
        [IO.File]::SetAttributes($LiteralPath, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($LiteralPath)
        return
    }

    foreach ($entry in [IO.Directory]::GetFileSystemEntries($LiteralPath)) {
        Remove-TreeSafely $entry
    }
    [IO.Directory]::Delete($LiteralPath, $false)
}

function Assert-SafeTarget {
    <#  Allowlist guard: destructive operations may only touch the app's support directory
        or a claude-backup-* directory. Anything else is a bug, and we stop hard. #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    $full = [IO.Path]::GetFullPath($LiteralPath).TrimEnd('\')
    $support = [IO.Path]::GetFullPath($SupportDir).TrimEnd('\')

    $okSupport = $full.StartsWith($support + '\', [StringComparison]::OrdinalIgnoreCase)
    $okBackup = $full -match '\\claude-backup-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}(\\|$)'

    if (-not ($okSupport -or $okBackup)) {
        throw "refusing to modify a path outside the session store or a backup: $full"
    }
    if ($full.Length -le 3) { throw "refusing to modify a drive root: $full" }
}

# ---- copying ---------------------------------------------------------------------------
function Copy-TreeSafely {
    <# robocopy /XJ - never traverses junctions, so `.claude\skills\c3d-*` and `agents`
       are recorded rather than duplicated. #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirs = @()
    )
    Write-Act "copy: $Source  ->  $Destination"
    if ($DryRun) { return }

    $rcArgs = @(
        $Source.TrimEnd('\'), $Destination.TrimEnd('\'),
        '/E', '/XJ', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1',
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/NC', '/BYTES'
    )
    foreach ($d in $ExcludeDirs) { $rcArgs += '/XD'; $rcArgs += $d }

    $out = & robocopy.exe @rcArgs 2>&1
    $code = $LASTEXITCODE
    # robocopy: 0-7 are success codes, >=8 means at least one item failed to copy
    if ($code -ge 8) { throw "robocopy failed (exit $code): $Source -> $Destination`n$($out -join "`n")" }
}

function Get-ReparseManifest {
    param([Parameter(Mandatory)][string]$Root)
    $found = @()
    if (-not (Test-Path -LiteralPath $Root)) { return $found }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $children = @()
        try { $children = [IO.Directory]::GetDirectories($dir) } catch { continue }
        foreach ($c in $children) {
            if (Test-IsReparse $c) {
                $found += [pscustomobject]@{ path = $c; target = (Get-ReparseTarget $c) }
            }
            else { $stack.Push($c) }
        }
    }
    return $found
}

function Get-PointerCount {
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    try { return @([IO.Directory]::GetFiles($Dir, 'local_*.json')).Count } catch { return 0 }
}

function Get-PointerTitles {
    param([Parameter(Mandatory)][string]$Dir)
    $titles = @()
    if (-not (Test-Path -LiteralPath $Dir)) { return $titles }
    foreach ($f in [IO.Directory]::GetFiles($Dir, 'local_*.json')) {
        $t = '(untitled)'
        try {
            $j = Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($j.PSObject.Properties.Name -contains 'title' -and $j.title) { $t = [string]$j.title }
        }
        catch { $t = '(unreadable)' }
        $titles += $t
    }
    return $titles
}

# ---- app detection ---------------------------------------------------------------------
function Get-AppEvidence {
    <#  Returns one line per running app process. Callers MUST wrap the result in @() -
        a function returning an empty array hands back $null, and a single-element array
        hands back a bare string, and under Set-StrictMode both blow up on .Count. #>
    if ($TestMode) { return @() }
    $procs = @(Get-Process -Name $ProcName -ErrorAction SilentlyContinue)
    $out = @()
    foreach ($p in $procs) { $out += ("    process:   pid {0}  $ProcName.exe" -f $p.Id) }
    return $out
}

function Wait-AppClosed {
    if ($TestMode) { return }
    while ($true) {
        $evidence = @(Get-AppEvidence)
        if ($evidence.Count -eq 0) { return }

        if ($DryRun) {
            Write-Warn "$($evidence.Count) $ProcName.exe process(es) running - fine for a dry run, but the real run needs the app fully quit"
            return
        }

        if ($Force) {
            Write-Warn "continuing despite $($evidence.Count) running $ProcName.exe process(es) - you asked with -Force"
            return
        }
        Write-Warn 'The Claude app appears to be running - here is what I detect:'
        $evidence | Select-Object -First 6 | ForEach-Object { Write-Plain $_ }
        if ($evidence.Count -gt 6) { Write-Plain "    ... and $($evidence.Count - 6) more" }

        if ($NonInteractive) { throw 'the Claude app is running; quit it or pass -Force' }

        $ans = Read-Host 'Quit it completely, then press Enter to re-check ([w] continue anyway, [q] abort)'
        switch ($ans) {
            'w' { Write-Warn 'continuing despite detected processes (at your request)'; return }
            'q' { throw 'aborted - nothing was changed' }
        }
    }
}

# ---- discovery -------------------------------------------------------------------------
function Get-SubDirectories {
    <#  Directory listing via .NET rather than Get-ChildItem.

        Get-ChildItem is a command name, and a command name can be shadowed by a profile
        function, an alias or a proxy. When that happens a swallowed error looks exactly
        like "there are no sessions here", which is the worst possible way for this script
        to fail. [IO.Directory] cannot be intercepted. #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not [IO.Directory]::Exists($LiteralPath)) { return @() }
    return @([IO.Directory]::GetDirectories($LiteralPath))
}
# NOTE: a PowerShell function that returns a 0- or 1-element array hands the caller $null
# or a bare scalar. Under Set-StrictMode, .Count on either throws. Every call site of the
# collection-returning helpers below wraps the result in @() for that reason.

function Get-AccountDirs {
    param([Parameter(Mandatory)][string]$Base)
    $root = Join-Path $SupportDir $Base
    $out = @()
    foreach ($d in @(Get-SubDirectories $root)) {
        $name = [IO.Path]::GetFileName($d)
        if ($name -notmatch $UUID_RE) { continue }
        $out += [pscustomobject]@{
            Name             = $name
            FullName         = $d
            LastWriteTimeUtc = [IO.Directory]::GetLastWriteTimeUtc($d)
        }
    }
    return $out
}

function Get-OrgDirs {
    param([Parameter(Mandatory)][string]$AccountPath)
    $out = @()
    foreach ($d in @(Get-SubDirectories $AccountPath)) {
        $name = [IO.Path]::GetFileName($d)
        if ($name -notmatch $UUID_RE) { continue }
        $out += [pscustomobject]@{ Name = $name; FullName = $d }
    }
    return $out
}

function Write-DiscoveryDump {
    <# Printed whenever discovery comes up empty, so the failure explains itself. #>
    Write-Plain ''
    Write-Warn 'Discovery found nothing. This is what the script actually sees:'
    Write-Plain "    support dir      : $SupportDir"
    Write-Plain "    exists           : $([IO.Directory]::Exists($SupportDir))"
    foreach ($base in $BASES) {
        $root = Join-Path $SupportDir $base
        Write-Plain "    $base"
        Write-Plain "      path           : $root"
        Write-Plain "      exists         : $([IO.Directory]::Exists($root))"
        $subs = @(Get-SubDirectories $root)
        Write-Plain "      subdirectories : $($subs.Count)"
        foreach ($s in $subs) {
            $n = [IO.Path]::GetFileName($s)
            $ok = 'UUID'
            if ($n -notmatch $UUID_RE) { $ok = 'ignored (not a UUID)' }
            Write-Plain "        - $n  [$ok]"
        }
    }
    Write-Plain ''
    Write-Plain '    If the folders are listed above but the script still says none were found,'
    Write-Plain '    please report this output. If CCSWITCH_SUPPORT_DIR is set in your shell it'
    Write-Plain '    overrides the default location:'
    Write-Plain "      CCSWITCH_SUPPORT_DIR = $([Environment]::GetEnvironmentVariable('CCSWITCH_SUPPORT_DIR'))"
}

function Find-Master {
    <# master = the physical (non-junction) <account>\<org> under claude-code-sessions
       holding the most pointers. #>
    $best = -1
    $script:OldAcc = ''
    $script:OldOrg = ''
    $script:SessCount = 0

    foreach ($acc in @(Get-AccountDirs 'claude-code-sessions')) {
        if ($OldAccount -and $acc.Name -ne $OldAccount) { continue }
        foreach ($org in @(Get-OrgDirs $acc.FullName)) {
            if (Test-IsReparse $org.FullName) { continue }   # links are never the master
            $n = Get-PointerCount $org.FullName
            if ($n -gt $best) {
                $best = $n
                $script:OldAcc = $acc.Name
                $script:OldOrg = $org.Name
                $script:SessCount = $n
            }
        }
    }
    return [bool]$script:OldAcc
}

function Get-LinkedCount {
    $master = Resolve-PhysicalDir (Join-Path $SupportDir "claude-code-sessions\$($script:OldAcc)\$($script:OldOrg)")
    $n = 0
    foreach ($acc in @(Get-AccountDirs 'claude-code-sessions')) {
        foreach ($org in @(Get-OrgDirs $acc.FullName)) {
            if (-not (Test-IsReparse $org.FullName)) { continue }
            if ((Resolve-PhysicalDir $org.FullName) -eq $master) { $n++ }
        }
    }
    return $n
}

function Find-NewAccount {
    <# new account = the freshest account directory that is not the master, across both
       bases (local-agent-mode-sessions appears immediately after a mere login). #>
    $script:NewAcc = ''
    $script:NewOrgs = @()

    if ($NewAccount) {
        $script:NewAcc = $NewAccount
    }
    else {
        $newest = [datetime]::MinValue
        foreach ($base in $BASES) {
            foreach ($acc in (Get-AccountDirs $base)) {
                if ($acc.Name -eq $script:OldAcc) { continue }
                if ($acc.LastWriteTimeUtc -gt $newest) {
                    $newest = $acc.LastWriteTimeUtc
                    $script:NewAcc = $acc.Name
                }
            }
        }
    }
    if (-not $script:NewAcc) { return $false }

    $orgs = @()
    foreach ($base in $BASES) {
        $dir = Join-Path $SupportDir "$base\$($script:NewAcc)"
        # broken junctions are still directory entries here, and they are repairable
        foreach ($org in (Get-OrgDirs $dir)) {
            if ($orgs -notcontains $org.Name) { $orgs += $org.Name }
        }
    }
    $script:NewOrgs = $orgs
    return ($orgs.Count -gt 0)
}

# ---- backup ----------------------------------------------------------------------------
function New-Backup {
    $stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
    $backup = Join-Path $BackupRoot "claude-backup-$stamp"
    Write-Info "STEP 2/4 - backing up to: $backup"

    if (-not $DryRun) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }

    $sourceCounts = @{}
    foreach ($base in $BASES) {
        $src = Join-Path $SupportDir $base
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $sourceCounts[$base] = @(Get-ChildItem -LiteralPath $src -Recurse -Filter 'local_*.json' -File -Force -ErrorAction SilentlyContinue).Count
        Copy-TreeSafely -Source $src -Destination (Join-Path $backup $base)
    }

    if (Test-Path -LiteralPath $ClaudeDir) {
        $exclude = @()
        if ($NoSkillsBackup) {
            $exclude = @((Join-Path $ClaudeDir 'skills'))
            Write-Warn 'skipping .claude\skills (-NoSkillsBackup); your transcripts in .claude\projects are still backed up'
        }
        else {
            Write-Plain '    (copying ~\.claude in full - this is the slow part; -NoSkillsBackup makes it much faster)'
        }
        Copy-TreeSafely -Source $ClaudeDir -Destination (Join-Path $backup 'dot-claude') -ExcludeDirs $exclude
    }

    if (Test-Path -LiteralPath $ClaudeJson) {
        Write-Act "copy: $ClaudeJson -> $backup\dot-claude.json"
        if (-not $DryRun) { Copy-Item -LiteralPath $ClaudeJson -Destination (Join-Path $backup 'dot-claude.json') -Force }
    }

    if (-not $DryRun) {
        $manifest = [pscustomobject]@{
            version       = $VERSION
            createdAt     = (Get-Date).ToString('o')
            supportDir    = $SupportDir
            claudeDir     = $ClaudeDir
            skillsSkipped = [bool]$NoSkillsBackup
            pointerCounts = $sourceCounts
            reparsePoints = @(Get-ReparseManifest $ClaudeDir)
        }
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $backup 'manifest.json') -Encoding UTF8

        # verify before anything is mutated: every pointer must have made it into the backup
        foreach ($base in $BASES) {
            if (-not $sourceCounts.ContainsKey($base)) { continue }
            $dst = Join-Path $backup $base
            $got = @(Get-ChildItem -LiteralPath $dst -Recurse -Filter 'local_*.json' -File -Force -ErrorAction SilentlyContinue).Count
            if ($got -ne $sourceCounts[$base]) {
                throw "backup verification failed for ${base}: $got of $($sourceCounts[$base]) pointer files copied. Nothing was changed."
            }
            Write-Plain "    verified $base : $got/$($sourceCounts[$base]) pointer files"
        }

        $size = (Get-ChildItem -LiteralPath $backup -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        Write-Info ('backup ready ({0:N0} MB)' -f ($size / 1MB))
        Write-Warn 'this backup contains .claude.json, which holds OAuth tokens - never commit or share it'
    }

    $script:Backup = $backup
    return $backup
}

# ---- linking ---------------------------------------------------------------------------
function Invoke-LinkOrg {
    param(
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Org
    )

    $oldPath = Join-Path $SupportDir "$Base\$($script:OldAcc)\$($script:OldOrg)"
    $newPath = Join-Path $SupportDir "$Base\$($script:NewAcc)\$Org"
    $label = "$Base ($Org)"

    if (-not (Test-Path -LiteralPath $oldPath)) {
        Write-Warn "${label}: the old account has no such folder - skipping."
        return
    }
    $master = Resolve-PhysicalDir $oldPath

    if ((Test-Path -LiteralPath $newPath) -and ((Resolve-PhysicalDir $newPath) -eq $master)) {
        Write-Info "${label}: already shared - nothing to do."
        return
    }

    if (Test-IsReparse $newPath) {
        # a link pointing somewhere else, or a broken one: re-point it
        Remove-Link $newPath
        New-Junction -LinkPath $newPath -TargetPath $master
        Write-Info "${label}: fixed an existing link."
        return
    }

    if (Test-Path -LiteralPath $newPath) {
        $n = Get-PointerCount $newPath
        if ($n -gt 0) {
            Write-Warn "${label}: the new account already has $n session(s) of its own:"
            foreach ($t in @(Get-PointerTitles $newPath)) { Write-Plain "        - $t" }

            $choice = $OnConflict
            if ($choice -eq 'ask') {
                if ($NonInteractive) { throw "$label has its own sessions and -OnConflict was not set" }
                Write-Plain ''
                Write-Plain '    [r] replace - stash those in the backup, then link  (they leave the sidebar)'
                Write-Plain '    [m] merge   - copy the old sessions in instead      (lists stay separate)'
                Write-Plain '    [s] skip    - change nothing'
                $ans = Read-Host '    choose [r/m/s]'
                switch ($ans) {
                    'r' { $choice = 'replace' }
                    'm' { $choice = 'merge' }
                    default { $choice = 'skip' }
                }
            }

            switch ($choice) {
                'merge' {
                    Write-Act "merge: copy pointers from $master into $newPath"
                    if (-not $DryRun) {
                        foreach ($f in [IO.Directory]::GetFiles($master, 'local_*.json')) {
                            $dest = Join-Path $newPath ([IO.Path]::GetFileName($f))
                            if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath $f -Destination $dest }
                        }
                    }
                    Write-Info "${label}: merged (note: from now on each account keeps its own list)."
                    return
                }
                'skip' {
                    Write-Warn "${label}: skipped."
                    return
                }
            }
            # 'replace' falls through to the stash-and-link path below
        }

        # stash the folder into the backup, then remove it so a junction can take its place
        if (-not $script:Backup) { throw 'internal: no backup directory - refusing to delete anything' }
        $stash = Join-Path $script:Backup "replaced-dirs\$Base-$($script:NewAcc)\$Org"
        Copy-TreeSafely -Source $newPath -Destination $stash

        if (-not $DryRun) {
            $srcN = Get-PointerCount $newPath
            $dstN = Get-PointerCount $stash
            if ($dstN -ne $srcN) { throw "stash verification failed for ${label}: $dstN of $srcN pointers saved. Nothing deleted." }
            if ($srcN -gt 0) { Write-Plain "    stashed $srcN pointer file(s) in $stash" }
        }
        Remove-TreeSafely $newPath
    }

    New-Junction -LinkPath $newPath -TargetPath $master
    Write-Info "${label}: linked -> shared session list."
}

# ---- actions ---------------------------------------------------------------------------
function Get-RetentionCurrent {
    $settings = Join-Path $ClaudeDir 'settings.json'
    if (-not (Test-Path -LiteralPath $settings)) { return '30 (default)' }
    try {
        $j = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains 'cleanupPeriodDays') { return [string]$j.cleanupPeriodDays }
    }
    catch { return '(unreadable settings.json)' }
    return '30 (default)'
}

function Set-Retention {
    param([Parameter(Mandatory)][int]$Days)
    $settings = Join-Path $ClaudeDir 'settings.json'

    $obj = $null
    if (Test-Path -LiteralPath $settings) {
        try { $obj = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json }
        catch { Write-Err "could not parse $settings - is it valid JSON? Leaving it alone."; return $false }
    }
    if ($null -eq $obj) { $obj = [pscustomobject]@{} }

    if ($obj.PSObject.Properties.Name -contains 'cleanupPeriodDays') { $obj.cleanupPeriodDays = $Days }
    else { $obj | Add-Member -NotePropertyName 'cleanupPeriodDays' -NotePropertyValue $Days }

    Write-Act "set cleanupPeriodDays=$Days in $settings"
    if ($DryRun) { return $true }

    $dir = Split-Path $settings -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $settings) { Copy-Item -LiteralPath $settings -Destination "$settings.bak" -Force }

    $tmp = "$settings.tmp"
    # WriteAllText with an explicit BOM-less encoder: Set-Content -Encoding UTF8 emits a
    # UTF-8 BOM on PowerShell 5.1, and a BOM breaks strict JSON.parse readers. The file
    # Claude ships has no BOM, so neither may ours.
    $json = ($obj | ConvertTo-Json -Depth 100)
    [IO.File]::WriteAllText($tmp, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    # prove the result parses before it replaces the live file
    $null = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
    Move-Item -LiteralPath $tmp -Destination $settings -Force

    Write-Info "cleanupPeriodDays=$Days saved in $settings"
    return $true
}

function Invoke-RetentionDialog {
    $current = Get-RetentionCurrent
    if ($RetentionDays -gt 0) { $null = Set-Retention $RetentionDays; return }
    if ($NonInteractive) { return }

    Write-Plain ''
    $ans = Read-Host "Change session retention now? Claude deletes session files older than 30 days by default (current: $current) [y/N]"
    if ($ans -ne 'y' -and $ans -ne 'Y') { Write-Info 'Retention left unchanged.'; return }

    while ($true) {
        $val = Read-Host "How many days to keep sessions? [Enter = $DEFAULT_RETENTION, q = cancel]"
        if ($val -eq '') { $val = "$DEFAULT_RETENTION" }
        if ($val -eq 'q' -or $val -eq 'Q') { Write-Info 'Retention change cancelled.'; return }
        $parsed = 0
        if ([int]::TryParse($val, [ref]$parsed) -and $parsed -ge 1) { $null = Set-Retention $parsed; return }
        Write-Warn 'Please enter a positive number, or q to cancel.'
    }
}

function Invoke-Status {
    Write-Head 'Session store'
    Write-Plain "  support dir : $SupportDir"
    Write-Plain "  claude dir  : $ClaudeDir"
    Write-Plain ''

    foreach ($base in $BASES) {
        Write-Plain "  $base"
        $accounts = @(Get-AccountDirs $base)
        if ($accounts.Count -eq 0) { Write-Plain '    (none)'; continue }
        foreach ($acc in $accounts) {
            foreach ($org in @(Get-OrgDirs $acc.FullName)) {
                $kind = 'dir     '
                $extra = ''
                if (Test-IsReparse $org.FullName) {
                    $kind = 'junction'
                    $extra = ' -> ' + (Resolve-PhysicalDir $org.FullName)
                }
                $n = Get-PointerCount (Resolve-PhysicalDir $org.FullName)
                Write-Plain ("    {0}  {1}\{2}  {3,3} pointer(s){4}" -f $kind, $acc.Name, $org.Name, $n, $extra)
            }
        }
    }

    Write-Plain ''
    if (Find-Master) {
        Write-Info "master: $($script:OldAcc) / $($script:OldOrg) - $($script:SessCount) session(s), $(Get-LinkedCount) shared link(s)"
    }
    else {
        Write-Warn "No desktop sessions found in: $SupportDir\claude-code-sessions"
        Write-DiscoveryDump
    }
    Write-Plain "retention (cleanupPeriodDays): $(Get-RetentionCurrent)"
}

function Invoke-Transfer {
    if (-not (Find-Master)) {
        Write-DiscoveryDump
        throw "No desktop sessions found in: $SupportDir\claude-code-sessions"
    }

    Write-Plain ''
    Write-Info "Account with sessions (old / master): $($script:OldAcc)"
    Write-Plain "      org:      $($script:OldOrg)"
    Write-Plain "      sessions: $($script:SessCount)"
    Write-Plain ''

    if (-not $NonInteractive) {
        Write-Plain ''
        Write-Head 'STEP 1/4 - Quit the Claude app completely, including the tray icon.'
        Read-Host '[Enter] when done' | Out-Null
    }
    Wait-AppClosed

    $backup = New-Backup

    # Retention edits ~\.claude\settings.json, so it runs AFTER the backup - otherwise a
    # failure later in the flow would leave a modified settings.json with no copy of the
    # original in the backup. (The macOS original asks first; it has no verified backup to
    # order against.)
    Invoke-RetentionDialog

    if (-not $NonInteractive) {
        Write-Plain ''
        Write-Head 'STEP 3/4 - Re-login:'
        Write-Plain '   1. open the Claude app'
        Write-Plain '   2. log out'
        Write-Plain '   3. log in to the NEW account (just logging in is enough)'
        Write-Plain '   4. quit the app again'
        Write-Plain ''
        Write-Plain '   (If you are already logged in to the new account, just press Enter.)'
        Read-Host '[Enter] when done' | Out-Null
        Wait-AppClosed
    }

    while (-not (Find-NewAccount)) {
        if ($NonInteractive) { throw 'no new-account directories found on disk' }
        Write-Warn @'
no new-account directories on disk yet.
    - if you just logged in: open the app on the new account once more, wait a few seconds, quit it
    - if you switched back to the OLD account (everything already linked): just quit (q)
'@
        $ans = Read-Host '[Enter] to check again, q to quit'
        if ($ans -eq 'q' -or $ans -eq 'Q') {
            Write-Info "finished - nothing was changed (backup kept: $backup)"
            return
        }
        Wait-AppClosed
    }

    Write-Plain ''
    Write-Info "Detected new account: $($script:NewAcc)"
    Write-Plain "      organizations: $($script:NewOrgs -join ', ')"

    Write-Plain ''
    Write-Info 'STEP 4/4 - linking the old account''s sessions to the new one...'
    foreach ($org in $script:NewOrgs) {
        foreach ($base in $BASES) {
            Invoke-LinkOrg -Base $base -Org $org
        }
    }

    Write-Plain ''
    if ($DryRun) {
        Write-Head '=== DRY RUN COMPLETE - nothing was changed ==='
        return
    }

    Write-Head '=== DONE ==='
    Write-Plain 'Open the app and log in to the new account - your sessions should be back in the sidebar.'
    Write-Plain ''
    Write-Plain 'Keep in mind:'
    Write-Plain '  - resuming a long old session resends its whole context uncached on the first turn;'
    Write-Plain '    it is slower and more expensive. For long chats prefer /export + a fresh session.'
    Write-Plain '  - sidebar pin order is wiped on every logout (the app itself clears it).'
    Write-Plain ''
    Write-Plain "Backup:   $backup"
    Write-Plain "Rollback: .\claude-code-switch.ps1 rollback `"$backup`""

    $stashRoot = Join-Path $backup 'replaced-dirs'
    if (Test-Path -LiteralPath $stashRoot) {
        Write-Plain ''
        Write-Warn 'Sessions that were stashed out of the sidebar (restore them by copying the files back):'
        foreach ($d in @(Get-ChildItem -LiteralPath $stashRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue)) {
            $n = Get-PointerCount $d.FullName
            if ($n -eq 0) { continue }
            foreach ($t in @(Get-PointerTitles $d.FullName)) { Write-Plain "        - $t" }
            Write-Plain "      Copy-Item '$($d.FullName)\local_*.json' '$SupportDir\claude-code-sessions\$($script:OldAcc)\$($script:OldOrg)\'"
        }
    }
}

function Invoke-Rollback {
    param([Parameter(Mandatory)][string]$BackupDir)

    if (-not (Test-Path -LiteralPath $BackupDir)) { throw "backup directory not found: $BackupDir" }
    Wait-AppClosed

    foreach ($base in $BASES) {
        $src = Join-Path $BackupDir $base
        if (-not (Test-Path -LiteralPath $src)) { continue }

        $live = Join-Path $SupportDir $base
        $aside = Join-Path $SupportDir ".$base.pre-rollback.$PID"

        if (Test-Path -LiteralPath $aside) { Remove-TreeSafely $aside }

        if (Test-Path -LiteralPath $live) {
            Write-Act "move aside: $live -> $aside"
            if (-not $DryRun) { Move-Item -LiteralPath $live -Destination $aside -Force }
        }

        try {
            Copy-TreeSafely -Source $src -Destination $live
        }
        catch {
            Write-Err "restore of $base failed - putting the previous state back"
            if (-not $DryRun) {
                if (Test-Path -LiteralPath $live) { Remove-TreeSafely $live }
                if (Test-Path -LiteralPath $aside) { Move-Item -LiteralPath $aside -Destination $live -Force }
            }
            throw
        }

        # verify the restore before discarding the state we moved aside
        if (-not $DryRun) {
            $want = @(Get-ChildItem -LiteralPath $src -Recurse -Filter 'local_*.json' -File -Force -ErrorAction SilentlyContinue).Count
            $got = @(Get-ChildItem -LiteralPath $live -Recurse -Filter 'local_*.json' -File -Force -ErrorAction SilentlyContinue).Count
            if ($got -ne $want) {
                Write-Err "restore of $base is short ($got of $want pointer files) - putting the previous state back"
                Remove-TreeSafely $live
                if (Test-Path -LiteralPath $aside) { Move-Item -LiteralPath $aside -Destination $live -Force }
                throw "rollback verification failed for $base"
            }
            Write-Plain "    verified $base : $got/$want pointer files"
        }

        # the moved-aside copy may contain junctions from an earlier run: Remove-TreeSafely
        # unlinks them instead of deleting through them into the master index
        if (Test-Path -LiteralPath $aside) { Remove-TreeSafely $aside }
        Write-Info "restored $base from the backup"
    }

    Write-Plain ''
    Write-Info "Done. (~\.claude and ~\.claude.json are not touched by rollback - restore them by hand from $BackupDir if needed.)"
}

function Invoke-RollbackDialog {
    Write-Head 'Restore session indexes from a backup.'
    $list = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter 'claude-backup-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending)
    if ($list.Count -gt 0) {
        Write-Plain 'Available backups:'
        foreach ($b in $list) { Write-Plain "    $($b.FullName)" }
    }
    else {
        Write-Warn "No backups found in $BackupRoot."
    }
    $p = Read-Host 'Backup directory path [q = back]'
    if ($p -eq '' -or $p -eq 'q' -or $p -eq 'Q') { return }
    Invoke-Rollback -BackupDir $p
}

# ---- menu ------------------------------------------------------------------------------
function Show-Menu {
    $options = @(
        'Status (read-only)',
        'Start account transfer',
        'Session retention (cleanupPeriodDays)',
        'Restore from a backup (rollback)',
        'Quit'
    )
    while ($true) {
        Write-Plain ''
        for ($i = 0; $i -lt $options.Count; $i++) { Write-Plain "  $($i + 1)) $($options[$i])" }
        $choice = Read-Host "Choose an option [1-$($options.Count), q]"
        if ($choice -eq 'q' -or $choice -eq 'Q') { Write-Info 'Bye!'; return }
        switch ($choice) {
            '1' { Write-Plain ''; Invoke-Status }
            '2' { Write-Plain ''; Invoke-Transfer; return }
            '3' { Write-Plain ''; Invoke-RetentionDialog }
            '4' { Write-Plain ''; Invoke-RollbackDialog }
            '5' { Write-Info 'Bye!'; return }
            default { Write-Warn 'Not a valid option.' }
        }
    }
}

# ---- entry point -----------------------------------------------------------------------
Write-Head "Claude Code Switch for Windows v$VERSION"
if ($DryRun) { Write-Warn 'DRY RUN - nothing will be changed' }
if ($TestMode) { Write-Warn "TEST MODE - app checks skipped, support dir: $SupportDir" }
Write-Plain ''

try {
    switch ($Command) {
        'status' { Invoke-Status }
        'transfer' { Invoke-Transfer }
        'retention' { Invoke-RetentionDialog }
        'rollback' {
            if (-not $Path) { throw "usage: .\claude-code-switch.ps1 rollback <backup-dir>" }
            Invoke-Rollback -BackupDir $Path
        }
        'menu' {
            Write-Plain 'Switch Claude desktop-app accounts without losing your session history.'
            Write-Plain 'Your transcripts live in ~\.claude\projects and are never modified.'
            Write-Plain ''
            if (Find-Master) {
                Write-Info "Session store: account $($script:OldAcc)"
                Write-Plain "             org $($script:OldOrg) - $($script:SessCount) session(s), $(Get-LinkedCount) shared link(s)"
            }
            else {
                Write-Warn "No desktop sessions found in: $SupportDir\claude-code-sessions"
                Write-DiscoveryDump
            }
            Show-Menu
        }
    }
}
catch {
    Write-Plain ''
    Write-Err $_.Exception.Message
    if ($script:Changes.Count -gt 0) {
        Write-Warn 'Changes made before the failure:'
        foreach ($c in $script:Changes) { Write-Plain "    $c" }
        if ($script:Backup) { Write-Warn "Roll back with: .\claude-code-switch.ps1 rollback `"$($script:Backup)`"" }
    }
    else {
        Write-Plain 'Nothing was changed.'
    }
    exit 1
}
