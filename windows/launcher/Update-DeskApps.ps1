<#
.SYNOPSIS
  Update worker for the desk apps: finds a newer signed release, or prepares one. Started by the panel in the
  background (no window) and by Install-DeskApps.ps1; writes its result as JSON and exits.

.DESCRIPTION
  -Mode Check
    git fetch of the pc-v* tags from the GitHub mirror (forced: a tag the owner re-created replaces the old one;
    that is safe because nothing is trusted by name, see Prepare). The newest pc-vX.Y.Z above what runs and not
    marked failed must be an annotated tag whose own name matches, signed by a key in allowed_signers
    (git verify-tag), and its manifest (windows/pc-manifest.json, read with git show, nothing written) must carry
    the same version. Result in update-check.json: status none | available | error, tag, tagObject, commit.
  -Mode Prepare -Tag -TagObject -Commit [-HaApi n]
    Runs after the owner said yes, maybe hours after Check: verifies the signature again and that the tag still
    is the same object pointing to the same commit, then checks the requirements of the release against this
    PC (nothing is written before that), creates the worktree releases\<tag> from the commit id (not the name)
    and marks the tag pending for both apps. -Initial (Install-DeskApps.ps1) makes it current instead.
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

function Get-VerifiedTag([string]$Name) {
    # Returns @{ tagObject; commit } for a signed annotated tag whose header names itself, or throws why not.
    $obj = Invoke-DeskGit $Root @('rev-parse', '--verify', '--quiet', "refs/tags/$Name")
    if ($obj.code -ne 0) { throw "tag $Name not found" }
    $type = Invoke-DeskGit $Root @('cat-file', '-t', $obj.out[0])
    if ($type.out[0] -ne 'tag') { throw "$Name is not an annotated tag" }
    $head = Get-DeskTagHeader (Invoke-DeskGit $Root @('cat-file', '-p', $obj.out[0])).out
    if ($head.tag -cne $Name -or $head.type -ne 'commit' -or $head.object -notmatch '^[0-9a-f]{40}$') { throw "tag ${Name}: header does not match (tag '$($head.tag)', type '$($head.type)')" }
    $v = Invoke-DeskGit $Root @('verify-tag', $obj.out[0])
    if ($v.code -ne 0) { throw "tag ${Name}: signature not valid for allowed_signers" }
    @{ tagObject = $obj.out[0]; commit = $head.object }
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
        $f = Invoke-DeskGit $Root @('fetch', '--prune', '--no-tags', 'origin', '+refs/tags/pc-v*:refs/tags/pc-v*')
        if ($f.code -ne 0) { throw "git fetch failed (exit $($f.code))" }
        $state = Invoke-DeskStateLocked $Root { param($s) $null }
        $failed = @($state.apps.Values | ForEach-Object { $_.failed }) | Select-Object -Unique
        # Offer what is newer than the oldest app: both apps move to the same release.
        $currents = @($state.apps.Values | ForEach-Object { $_.current } | Where-Object { $_ })
        $floor = $currents | Sort-Object { ConvertTo-DeskVersion $_ } | Select-Object -First 1
        $tags = (Invoke-DeskGit $Root @('tag', '-l', 'pc-v*')).out
        $result.status = 'none'
        $skipped = @()
        while ($true) {
            $newest = Select-DeskNewestTag -Tags $tags -Than $floor -Exclude (@($failed) + $skipped)
            if (-not $newest) { break }
            try {
                $t = Get-VerifiedTag $newest
                $man = Get-Manifest $t.commit
                $why = Test-DeskManifest $man $newest
                if ($why) { throw $why }
                $result.status = 'available'; $result.tag = $newest; $result.tagObject = $t.tagObject; $result.commit = $t.commit
                break
            }
            catch {
                # A bad newest tag must not hide a good older one.
                Write-Log "skipped $newest`: $($_.Exception.Message)"
                $skipped += $newest
            }
        }
        Write-Log "status $($result.status)$(if ($result.tag) { ' ' + $result.tag })"
    }
    else {
        if (-not ($Tag -and $TagObject -and $Commit)) { throw '-Tag, -TagObject and -Commit are required' }
        $t = Get-VerifiedTag $Tag
        if ($t.tagObject -ne $TagObject -or $t.commit -ne $Commit) { throw "tag $Tag changed since it was checked; check again" }
        $man = Get-Manifest $Commit
        $why = Test-DeskManifest $man $Tag
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
                $s.verified = @{ tag = $Tag; tagObject = $TagObject; commit = $Commit }
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
