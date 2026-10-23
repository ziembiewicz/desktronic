<#
.SYNOPSIS
  Update worker for the desk apps: finds a newer release on main, or prepares one. Started by the panel in the
  background (no window) and by Install-DeskApps.ps1; writes its result as JSON and exits.

.DESCRIPTION
  A release is a commit on main of the GitHub mirror, named v<N>: N counts the commits on main's first-parent
  line that changed windows/, so every merged pull request that touches the PC apps is the next release and a
  merge that only changes Home Assistant files is not. Main only changes through pull requests the owner merges.
  -Mode Check
    git fetch of main; when its v<N> is above what runs and not marked failed, and its manifest
    (windows/pc-manifest.json, read with git show, nothing written) is valid: available.
    Result in update-check.json: status none | available | error, tag (the release name, v<N>), commit.
  -Mode Prepare -Tag v<N> -Commit <id> [-HaApi n]
    Runs after the owner said yes, maybe hours after Check: the commit must still count as v<N>; then checks the
    requirements of the release against this PC (nothing is written before that), creates the worktree
    releases\v<N> from the commit id and marks it pending for both apps. -Initial (Install-DeskApps.ps1) makes it
    current instead. -TagObject is accepted and ignored (panels from before v14 pass it).
    Result in update-prepare.json: status ready | refused | error, reason.
  Never logs URLs from config.json, tokens or meeting data.
#>
#Requires -Version 7.4
param(
    [Parameter(Mandatory)][ValidateSet('Check', 'Prepare')][string]$Mode,
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'DeskApps'),
    [string]$Tag,
    [string]$TagObject,
    [string]$Commit,
    [int]$HaApi = 0,
    [switch]$Initial,
    [hashtable]$DataDirs = @{ 'desk-tray' = (Join-Path $env:LOCALAPPDATA 'DeskTray'); 'meeting-reminder' = (Join-Path $env:LOCALAPPDATA 'meeting-reminder') },
    [scriptblock]$ListenCheck = {
        param([string]$Prefix)
        $out = & netsh.exe http show urlacl url=$Prefix 2>$null
        [bool]($out | Select-String -SimpleMatch $Prefix)
    }
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeskApps.psm1') -Force
$logPath = Join-Path $Root 'update.log'

function Write-Log([string]$Message) {
    try { Add-Content -Path $logPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss} {1} {2}' -f (Get-Date), $Mode.ToLowerInvariant(), $Message) } catch { }
}

function Get-ReleaseName([string]$CommitId) {
    $n = Invoke-DeskGit $Root @('rev-list', '--count', '--first-parent', $CommitId, '--', 'windows/')
    if ($n.code -ne 0) { throw "commit $CommitId not found" }
    "v$($n.out[0])"
}

function Get-Manifest([string]$CommitId) {
    $m = Invoke-DeskGit $Root @('show', "${CommitId}:windows/pc-manifest.json")
    if ($m.code -ne 0) { throw 'release has no windows/pc-manifest.json' }
    try { ($m.out -join "`n") | ConvertFrom-Json } catch { throw 'pc-manifest.json is not valid JSON' }
}

$resultPath = Join-Path $Root $(if ($Mode -eq 'Check') { 'update-check.json' } else { 'update-prepare.json' })
$result = [ordered]@{ status = 'error'; at = (Get-Date).ToString('o') }
try {
    if ($Mode -eq 'Check') {
        $f = Invoke-DeskGit $Root @('fetch', '--prune', '--no-tags', 'origin', '+refs/heads/main:refs/remotes/origin/main')
        if ($f.code -ne 0) { throw "git fetch failed (exit $($f.code))" }
        $commit = (Invoke-DeskGit $Root @('rev-parse', '--verify', 'refs/remotes/origin/main^{commit}')).out[0]
        $name = Get-ReleaseName $commit
        $state = Invoke-DeskStateLocked $Root { param($s) $null }
        $failed = @($state.apps.Values | ForEach-Object { $_.failed })
        # Offer what is newer than the oldest app: both apps move to the same release.
        $floor = @($state.apps.Values | ForEach-Object { ConvertTo-DeskVersion $_.current } | Sort-Object)[0]
        $result.status = 'none'
        if ((ConvertTo-DeskVersion $name) -gt $floor) {
            if ($name -in $failed) { Write-Log "$name failed its trial before; waiting for the next merge" }
            else {
                $why = Test-DeskManifest (Get-Manifest $commit)
                if ($why) { throw "${name}: $why" }
                $result.status = 'available'; $result.tag = $name; $result.commit = $commit
            }
        }
        Write-Log "status $($result.status)$(if ($result.tag) { ' ' + $result.tag })"
    }
    else {
        if (-not ($Tag -and $Commit -match '^[0-9a-f]{40}$')) { throw '-Tag and -Commit are required' }
        if ((Get-ReleaseName $Commit) -cne $Tag) { throw "commit $($Commit.Substring(0, 12)) is not $Tag; check again" }
        $man = Get-Manifest $Commit
        $why = Test-DeskManifest $man
        if ($why) { throw $why }
        $config = @{}
        foreach ($app in Get-DeskAppNames) {
            $cfg = Join-Path $DataDirs[$app] 'config.json'
            $config[$app] = if (Test-Path $cfg) { @((Get-Content -Raw $cfg | ConvertFrom-Json).PSObject.Properties.Name) } else { @() }
        }
        $depsFile = Join-Path $DataDirs['desk-tray'] 'lib\deps.json'
        $deps = if (Test-Path $depsFile) { [string](Get-Content -Raw $depsFile | ConvertFrom-Json).deps } else { $null }
        $env2 = @{
            launcher = Get-DeskLauncherVersion; pwsh = $PSVersionTable.PSVersion; deps = $deps
            listen = [bool](& $ListenCheck ([string]$man.requires.listen)); ha_api = $HaApi; config = $config
        }
        $why = Test-DeskRequirements $man $env2
        if ($why) {
            $result.status = 'refused'; $result.reason = $why
            Write-Log "refused $Tag`: $why"
        }
        else {
            $dir = Join-Path (Join-Path $Root 'releases') $Tag
            if (Test-Path $dir) {
                $headNow = (& (Get-DeskGit).git -C $dir rev-parse HEAD 2>$null)
                if ($headNow -ne $Commit) { throw "releases\$Tag exists with another commit" }
            }
            else {
                $w = Invoke-DeskGit $Root @('worktree', 'add', '--detach', $dir, $Commit)
                if ($w.code -ne 0) { throw "git worktree add failed: $($w.err.Trim())" }
            }
            $null = Invoke-DeskStateLocked $Root {
                param($s)
                foreach ($app in Get-DeskAppNames) {
                    $a = $s.apps[$app]
                    if ($Initial) { $a.current = $Tag; $a.previous = $null; $a.pending = $null; $a.trial = $null }
                    elseif ($a.current -ne $Tag) { $a.pending = $Tag }
                }
                $s
            }
            # Old worktrees go; what runs, ran before or waits stays.
            $keep = @()
            $st = Invoke-DeskStateLocked $Root { param($s) $null }
            foreach ($a in $st.apps.Values) { $keep += @($a.current, $a.previous, $a.pending) }
            Get-ChildItem (Join-Path $Root 'releases') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $keep } | ForEach-Object {
                $r = Invoke-DeskGit $Root @('worktree', 'remove', '--force', $_.FullName)
                if ($r.code -ne 0) { Write-Log "could not remove $($_.Name)" }
            }
            $result.status = 'ready'; $result.tag = $Tag
            Write-Log "ready $Tag$(if ($Initial) { ' (initial)' })"
        }
    }
}
catch {
    $result.status = 'error'; $result.reason = $_.Exception.Message
    Write-Log "error: $($_.Exception.Message)"
}
Write-DeskFileAtomic $resultPath (ConvertTo-Json -InputObject $result)
if ($result.status -eq 'error') { exit 1 }
exit 0
