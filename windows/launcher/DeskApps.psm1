<#
  Shared by the starter (Start-DeskApp.ps1) and the update worker (Update-DeskApps.ps1). Lives in
  %LOCALAPPDATA%\DeskApps\launcher\ and is updated by hand only, never by the updater it serves.

  Layout of the DeskApps folder (-Root):
    repo\               git clone of the GitHub mirror; tags pc-vX.Y.Z signed with the owner's SSH key
    releases\<tag>\     git worktree of a verified tag; the apps run from here
    allowed_signers     the owner's public key (installed by hand; the updater never writes it)
    state.json          per app: current, previous, pending, trial, failed (written under a mutex, atomically)
    update-check.json   last result of Update-DeskApps.ps1 -Mode Check
    launcher\           this module, Start-DeskApp.ps1, Update-DeskApps.ps1
  App data (config.json, logs, lib\, wv2data\) stays in %LOCALAPPDATA%\DeskTray\ and %LOCALAPPDATA%\meeting-reminder\.
#>

# Raised by hand when the starter, this module or the worker change in a way a release depends on.
$script:LauncherVersion = 1
$script:TagPattern = '^pc-v(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})\.(0|[1-9]\d{0,3})$'
$script:AppNames = @('desk-tray', 'meeting-reminder')
$script:RemoteUrl = 'https://github.com/ziembiewicz/desktronic.git'

function Get-DeskLauncherVersion { $script:LauncherVersion }
function Get-DeskAppNames { $script:AppNames }
function Get-DeskRemoteUrl { $script:RemoteUrl }

# ------------------------------------------------------------------ versions (pure)

function ConvertTo-DeskVersion {
    # 'pc-v1.2.3' -> [version]1.2.3; anything else (suffixes, leading zeros, other tags) -> $null.
    param([string]$Tag)
    if ($Tag -cmatch $script:TagPattern) { return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
    $null
}

function Select-DeskNewestTag {
    # The highest pc-vX.Y.Z tag that is newer than $Than (a tag or $null) and not in $Exclude.
    param([string[]]$Tags, [string]$Than, [string[]]$Exclude = @())
    $floor = if ($Than) { ConvertTo-DeskVersion $Than } else { $null }
    $best = $null; $bestV = $null
    foreach ($t in $Tags) {
        $v = ConvertTo-DeskVersion $t
        if ($null -eq $v -or $t -in $Exclude) { continue }
        if ($floor -and $v -le $floor) { continue }
        if ($null -eq $bestV -or $v -gt $bestV) { $best = $t; $bestV = $v }
    }
    $best
}

function Get-DeskTagHeader {
    # Parses the header of a git tag object (git cat-file -p): object, type, tag. Lines after the first blank line
    # are the message and are ignored, so a message cannot fake a header line.
    param([string[]]$Lines)
    $h = @{}
    foreach ($l in $Lines) {
        if ($l -eq '') { break }
        if ($l -cmatch '^(object|type|tag|tagger) (.+)$') { if (-not $h.ContainsKey($Matches[1])) { $h[$Matches[1]] = $Matches[2] } }
    }
    $h
}

# ------------------------------------------------------------------ manifest and requirements (pure)

function Test-DeskManifest {
    # windows/pc-manifest.json of a release. Returns $null when valid, otherwise the reason. Unknown keys are
    # refused: an older updater must not silently skip a requirement it does not know.
    param($Manifest, [string]$Tag)
    if ($null -eq $Manifest -or $Manifest -isnot [pscustomobject]) { return 'manifest is not a JSON object' }
    $top = @($Manifest.PSObject.Properties.Name)
    foreach ($k in $top) { if ($k -notin 'version', 'requires') { return "manifest: unknown key '$k'" } }
    if ([string]$Manifest.version -cne $Tag) { return "manifest version '$($Manifest.version)' is not the tag $Tag" }
    $r = $Manifest.requires
    if ($null -eq $r -or $r -isnot [pscustomobject]) { return 'manifest: requires missing' }
    foreach ($k in @($r.PSObject.Properties.Name)) {
        if ($k -notin 'launcher', 'pwsh', 'deps', 'listen', 'ha_api', 'config_keys') { return "manifest: unknown requirement '$k'" }
    }
    foreach ($k in 'launcher', 'pwsh', 'deps', 'listen', 'ha_api', 'config_keys') {
        if ($null -eq $r.$k) { return "manifest: requirement '$k' missing" }
    }
    if ($r.config_keys -isnot [pscustomobject]) { return 'manifest: config_keys is not an object' }
    foreach ($k in @($r.config_keys.PSObject.Properties.Name)) { if ($k -notin $script:AppNames) { return "manifest: config_keys for unknown app '$k'" } }
    $null
}

function Test-DeskRequirements {
    # Checks a valid manifest against this PC. $Env holds what was measured:
    #   launcher (int), pwsh ([version]), deps (string from lib\deps.json or $null), listen (bool: the URL
    #   reservation exists), ha_api (int, last "api" pushed by Home Assistant, 0 if none), config (app -> key names).
    # Returns $null or the reason, phrased as the manual step to take.
    param($Manifest, [hashtable]$Env)
    $r = $Manifest.requires
    if ([int]$r.launcher -gt $Env.launcher) { return "needs starter version $($r.launcher) (installed: $($Env.launcher)); install the new launcher by hand (windows/launcher/README.md)" }
    if ([version][string]$r.pwsh -gt $Env.pwsh) { return "needs PowerShell $($r.pwsh) or newer: winget upgrade Microsoft.PowerShell" }
    if ([string]$r.deps -cne [string]$Env.deps) { return "needs the libraries $($r.deps): Exit the panel, then run Install-DeskTrayDeps.ps1 -Root <DeskTray folder> from the new release" }
    if (-not $Env.listen) { return "needs the push address $($r.listen): run Set-DeskTrayFirewall.ps1 from the new release" }
    if ([int]$r.ha_api -gt $Env.ha_api) { return "needs Home Assistant panel API $($r.ha_api) (seen: $($Env.ha_api)); the Home Assistant part is deployed first" }
    foreach ($app in @($r.config_keys.PSObject.Properties.Name)) {
        $have = @($Env.config[$app])
        foreach ($k in @($r.config_keys.$app)) { if ($k -notin $have) { return "needs '$k' in config.json of $app" } }
    }
    $null
}

# ------------------------------------------------------------------ state (pure transitions)

# A plain hashtable on purpose: the Step-* functions change it in place, and a [hashtable] parameter would copy an ordered one.
function New-DeskAppState { @{ current = $null; previous = $null; pending = $null; trial = $null; failed = @() } }

function ConvertTo-DeskState {
    # state.json -> hashtable with one entry per known app; missing or broken parts start empty.
    param([string]$Json)
    $s = @{ apps = @{}; verified = $null }
    $p = $null
    if ($Json) { try { $p = $Json | ConvertFrom-Json } catch { $p = $null } }
    foreach ($app in $script:AppNames) {
        $a = New-DeskAppState
        $src = if ($p -and $p.apps) { $p.apps.$app } else { $null }
        if ($src) {
            foreach ($k in 'current', 'previous', 'pending') { if ($src.$k) { $a[$k] = [string]$src.$k } }
            if ($src.trial -and $src.trial.version) { $a.trial = @{ version = [string]$src.trial.version; since = [string]$src.trial.since } }
            $a.failed = @($src.failed | Where-Object { $_ } | ForEach-Object { [string]$_ })
        }
        $s.apps[$app] = $a
    }
    if ($p -and $p.verified) { $s.verified = @{ tag = [string]$p.verified.tag; tagObject = [string]$p.verified.tagObject; commit = [string]$p.verified.commit } }
    $s
}

function Step-DeskApply {
    # The starter is about to start the app: a pending version becomes current and starts its trial.
    param([hashtable]$App, [datetime]$Now)
    if ($App.pending -and $App.pending -ne $App.current) {
        $App.previous = $App.current
        $App.current = $App.pending
        $App.trial = @{ version = $App.current; since = $Now.ToString('o') }
    }
    $App.pending = $null
    $App
}

function Step-DeskExit {
    # The app ended. Returns what the starter does next: 'apply' (exit 3: start again with what is pending),
    # 'end' (exit 0: the owner chose Exit), 'rollback' (failed during its trial; current is now previous),
    # 'stop' (failed during its trial and there is nothing to go back to) or 'restart' (crashed after its trial).
    param([hashtable]$App, [int]$ExitCode, [datetime]$Now, [int]$TrialSeconds = 60)
    if ($ExitCode -eq 3) { return 'apply' }
    if ($ExitCode -eq 0) { $App.trial = $null; return 'end' }
    if ($App.trial -and ($Now - [datetime]::Parse($App.trial.since, $null, 'RoundtripKind')).TotalSeconds -lt $TrialSeconds) {
        $bad = $App.current
        $App.failed = @(@($App.failed) + $bad | Select-Object -Unique)
        $App.trial = $null
        if (-not $App.previous) { return 'stop' }
        $App.current = $App.previous
        $App.previous = $null
        return 'rollback'
    }
    $App.trial = $null
    'restart'
}

function Step-DeskTrialPassed {
    # The app has run TrialSeconds: its version is good.
    param([hashtable]$App, [datetime]$Now, [int]$TrialSeconds = 60)
    if ($App.trial -and ($Now - [datetime]::Parse($App.trial.since, $null, 'RoundtripKind')).TotalSeconds -ge $TrialSeconds) {
        $App.trial = $null
        return $true
    }
    $false
}

function Test-DeskQueueEmpty {
    # queue.json of the meeting reminder: {count, next}. Empty when missing, broken, count 0, or the next
    # meeting started over a minute ago (a reminder that crashed leaves a stale file behind).
    param([string]$Json, [datetime]$Now)
    if (-not $Json) { return $true }
    try { $q = $Json | ConvertFrom-Json } catch { return $true }
    if ([int]$q.count -le 0) { return $true }
    $next = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$q.next, $null, 'RoundtripKind', [ref]$next)) { return $true }
    $next.ToUniversalTime() -lt $Now.ToUniversalTime().AddSeconds(-60)
}

# ------------------------------------------------------------------ files

function Write-DeskFileAtomic {
    # Write to a temporary file next to the target, then replace: a power cut leaves the old or the new file, never half.
    param([string]$Path, [string]$Text)
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -Force -Path $tmp -Destination $Path
}

function Invoke-DeskStateLocked {
    # Runs $Action with the state as a hashtable and saves what it returns (or nothing when it returns $null),
    # under the mutex Local\DeskApps.State. A mutex left by a killed process counts as taken over.
    param([string]$Root, [scriptblock]$Action)
    $m = [Threading.Mutex]::new($false, 'Local\DeskApps.State')
    $owned = $false
    try {
        try { $owned = $m.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'state.json is locked by another process' }
        $path = Join-Path $Root 'state.json'
        $json = if (Test-Path $path) { Get-Content -Raw -Path $path } else { '' }
        $state = ConvertTo-DeskState $json
        $out = & $Action $state
        if ($null -ne $out) { Write-DeskFileAtomic $path (ConvertTo-Json -InputObject $out -Depth 6) }
        $state
    }
    finally {
        if ($owned) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

# ------------------------------------------------------------------ git

function Get-DeskGit {
    # Git for Windows by absolute path (never whatever is first in PATH), and the ssh-keygen that ships with it
    # (Windows' own OpenSSH may be too old for "ssh-keygen -Y"). On Linux (tests) git and ssh-keygen from PATH.
    if ($IsWindows) {
        $base = Join-Path $env:ProgramFiles 'Git'
        $git = Join-Path $base 'cmd\git.exe'
        $keygen = Join-Path $base 'usr\bin\ssh-keygen.exe'
        if (-not (Test-Path $git) -or -not (Test-Path $keygen)) { throw "Git for Windows not found in $base (winget install --id Git.Git)" }
        return @{ git = $git; keygen = $keygen }
    }
    @{ git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
       keygen = (Get-Command ssh-keygen -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
}

function Invoke-DeskGit {
    # Runs git in the clone without prompts or credential helpers. Returns @{ code; out (lines) }.
    param([string]$Root, [string[]]$Arguments, [int]$TimeoutSeconds = 120)
    $g = Get-DeskGit
    $signers = Join-Path $Root 'allowed_signers'
    $all = @('-C', (Join-Path $Root 'repo'), '-c', 'credential.helper=', '-c', 'core.askPass=', '-c', 'gpg.format=ssh',
             '-c', "gpg.ssh.allowedSignersFile=$signers", '-c', "gpg.ssh.program=$($g.keygen)") + $Arguments
    $psi = [Diagnostics.ProcessStartInfo]::new($g.git)
    foreach ($a in $all) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $psi.Environment['GCM_INTERACTIVE'] = 'never'
    $p = [Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill($true) } catch { }
        throw "git $($Arguments[0]) took longer than $TimeoutSeconds s"
    }
    $p.WaitForExit()
    $out = $outTask.Result
    @{ code = $p.ExitCode; out = @($out -split "`r?`n" | Where-Object { $_ -ne '' }); err = $errTask.Result }
}

Export-ModuleMember -Function *-Desk*
