# Pester 4.10.1. Unit tests of DeskApps.psm1, and an end-to-end run of Update-DeskApps.ps1 and Start-DeskApp.ps1
# against a local repository with tags signed by a throwaway SSH key (needs git 2.34+ and ssh-keygen; skipped otherwise).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# The scripts default to folders under LOCALAPPDATA, which Linux does not set; the tests pass every folder.
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [IO.Path]::GetTempPath() }
$launcher = Split-Path -Parent $here
Import-Module (Join-Path $launcher 'DeskApps.psm1') -Force

function New-App { $a = New-DeskAppState; $h = @{}; foreach ($k in $a.Keys) { $h[$k] = $a[$k] }; $h }
$t0 = [datetime]::new(2026, 10, 23, 9, 0, 0, [DateTimeKind]::Utc)

Describe 'ConvertTo-DeskVersion' {
    It 'reads pc-vX.Y.Z' { ConvertTo-DeskVersion 'pc-v1.10.2' | Should Be ([version]'1.10.2') }
    It 'refuses suffixes, leading zeros and other tags' {
        foreach ($t in 'pc-v1.0.0-rc1', 'pc-v01.0.0', 'v1.0.0', 'pc-v1.0', 'PC-V1.0.0', 'pc-v1.0.0 ') { ConvertTo-DeskVersion $t | Should Be $null }
    }
}

Describe 'Select-DeskNewestTag' {
    It 'compares versions as numbers' { Select-DeskNewestTag -Tags 'pc-v1.9.0', 'pc-v1.10.0', 'pc-v1.2.0' | Should Be 'pc-v1.10.0' }
    It 'offers only what is newer than what runs' {
        Select-DeskNewestTag -Tags 'pc-v1.0.0', 'pc-v1.0.1' -Than 'pc-v1.0.1' | Should Be $null
        Select-DeskNewestTag -Tags 'pc-v1.0.0', 'pc-v1.0.1' -Than 'pc-v1.0.0' | Should Be 'pc-v1.0.1'
    }
    It 'skips failed releases and foreign tags' {
        Select-DeskNewestTag -Tags 'pc-v1.0.2', 'pc-v1.0.1', 'esphome-v9' -Than 'pc-v1.0.0' -Exclude 'pc-v1.0.2' | Should Be 'pc-v1.0.1'
    }
}

Describe 'Get-DeskTagHeader' {
    It 'reads the header and ignores look-alike lines in the message' {
        $h = Get-DeskTagHeader @(('object ' + ('a' * 40)), 'type commit', 'tag pc-v1.0.1', 'tagger T <t@x> 1 +0000', '', 'tag pc-v9.9.9', ('object ' + ('b' * 40)))
        $h.tag | Should Be 'pc-v1.0.1'
        $h.object | Should Be ('a' * 40)
    }
}

Describe 'Test-DeskManifest' {
    $good = '{"version":"pc-v1.0.0","requires":{"launcher":1,"pwsh":"7.4","deps":"d","listen":"http://+:8765/desk/","ha_api":1,"config_keys":{"desk-tray":["push_token"]}}}'
    It 'accepts a complete manifest' { Test-DeskManifest ($good | ConvertFrom-Json) 'pc-v1.0.0' | Should Be $null }
    It 'refuses another version than the tag' { Test-DeskManifest ($good | ConvertFrom-Json) 'pc-v1.0.1' | Should Match 'not the tag' }
    It 'refuses requirements it does not know' {
        $m = $good.Replace('"ha_api":1', '"ha_api":1,"gpu":2') | ConvertFrom-Json
        Test-DeskManifest $m 'pc-v1.0.0' | Should Match "unknown requirement 'gpu'"
    }
    It 'refuses a missing requirement' {
        $m = $good.Replace('"ha_api":1,', '') | ConvertFrom-Json
        Test-DeskManifest $m 'pc-v1.0.0' | Should Match "'ha_api' missing"
    }
}

Describe 'Test-DeskRequirements' {
    $m = '{"version":"pc-v1.0.0","requires":{"launcher":1,"pwsh":"7.4","deps":"d1","listen":"x","ha_api":2,"config_keys":{"desk-tray":["push_token"]}}}' | ConvertFrom-Json
    $ok = @{ launcher = 1; pwsh = [version]'7.4.6'; deps = 'd1'; listen = $true; ha_api = 2; config = @{ 'desk-tray' = @('push_token') } }
    It 'passes when everything is there' { Test-DeskRequirements $m $ok | Should Be $null }
    It 'names the manual step for each gap' {
        $e = $ok.Clone(); $e.deps = 'd0'; Test-DeskRequirements $m $e | Should Match 'Install-DeskTrayDeps'
        $e = $ok.Clone(); $e.ha_api = 1; Test-DeskRequirements $m $e | Should Match 'Home Assistant'
        $e = $ok.Clone(); $e.listen = $false; Test-DeskRequirements $m $e | Should Match 'Set-DeskTrayFirewall'
        $e = $ok.Clone(); $e.launcher = 0; Test-DeskRequirements $m $e | Should Match 'starter'
        $e = $ok.Clone(); $e.config = @{ 'desk-tray' = @() }; Test-DeskRequirements $m $e | Should Match 'push_token'
    }
}

Describe 'starter state steps' {
    It 'apply: pending becomes current and starts a trial' {
        $a = New-App; $a.current = 'pc-v1.0.0'; $a.pending = 'pc-v1.0.1'
        $null = Step-DeskApply $a $t0
        $a.current | Should Be 'pc-v1.0.1'; $a.previous | Should Be 'pc-v1.0.0'; $a.pending | Should Be $null
        $a.trial.version | Should Be 'pc-v1.0.1'
    }
    It 'exit 3 applies, exit 0 ends without failure' {
        $a = New-App; $a.current = 'pc-v1.0.1'; $a.trial = @{ version = 'pc-v1.0.1'; since = $t0.ToString('o') }
        Step-DeskExit $a 3 $t0.AddSeconds(5) | Should Be 'apply'
        Step-DeskExit $a 0 $t0.AddSeconds(5) | Should Be 'end'
        @($a.failed).Count | Should Be 0
    }
    It 'a crash within the trial rolls back and marks the release failed' {
        $a = New-App; $a.current = 'pc-v1.0.1'; $a.previous = 'pc-v1.0.0'; $a.trial = @{ version = 'pc-v1.0.1'; since = $t0.ToString('o') }
        Step-DeskExit $a 1 $t0.AddSeconds(10) | Should Be 'rollback'
        $a.current | Should Be 'pc-v1.0.0'; $a.failed | Should Be 'pc-v1.0.1'
    }
    It 'a crash within the trial with nothing to go back to stops' {
        $a = New-App; $a.current = 'pc-v1.0.0'; $a.trial = @{ version = 'pc-v1.0.0'; since = $t0.ToString('o') }
        Step-DeskExit $a 1 $t0.AddSeconds(10) | Should Be 'stop'
    }
    It 'a crash after the trial restarts the same release' {
        $a = New-App; $a.current = 'pc-v1.0.1'; $a.previous = 'pc-v1.0.0'; $a.trial = @{ version = 'pc-v1.0.1'; since = $t0.ToString('o') }
        Step-DeskTrialPassed $a $t0.AddSeconds(61) | Should Be $true
        Step-DeskExit $a 1 $t0.AddSeconds(3600) | Should Be 'restart'
        $a.current | Should Be 'pc-v1.0.1'
    }
}

Describe 'Test-DeskQueueEmpty' {
    It 'is empty without a file, with count 0, broken JSON or a meeting long gone' {
        Test-DeskQueueEmpty '' $t0 | Should Be $true
        Test-DeskQueueEmpty '{"count":0,"next":""}' $t0 | Should Be $true
        Test-DeskQueueEmpty '{"count":' $t0 | Should Be $true
        Test-DeskQueueEmpty ('{"count":1,"next":"' + $t0.AddMinutes(-5).ToString('o') + '"}') $t0 | Should Be $true
    }
    It 'is not empty while a meeting waits' {
        Test-DeskQueueEmpty ('{"count":1,"next":"' + $t0.AddMinutes(40).ToString('o') + '"}') $t0 | Should Be $false
    }
}

$haveTools = (Get-Command git -ErrorAction SilentlyContinue) -and (Get-Command ssh-keygen -ErrorAction SilentlyContinue)
Describe 'end to end with signed tags' {
    if (-not $haveTools) { It 'needs git and ssh-keygen' -Skip { } ; return }
    $w = Join-Path ([IO.Path]::GetTempPath()) ('deskapps-' + [guid]::NewGuid().ToString('N'))
    $origin = Join-Path $w 'origin'; $root = Join-Path $w 'DeskApps'
    $data = @{ 'desk-tray' = (Join-Path $w 'DeskTray'); 'meeting-reminder' = (Join-Path $w 'meeting-reminder') }
    $null = New-Item -ItemType Directory -Force -Path $origin, (Join-Path $root 'releases'), $data['desk-tray'], (Join-Path $data['desk-tray'] 'lib'), $data['meeting-reminder']
    Set-Content (Join-Path $data['desk-tray'] 'config.json') '{"panel_webhook_url":"x","panel_stop_webhook_url":"x","push_token":"x"}'
    Set-Content (Join-Path $data['meeting-reminder'] 'config.json') '{"reminder_webhook_url":"x"}'
    Set-Content (Join-Path $data['desk-tray'] 'lib/deps.json') '{"deps":"d1"}'
    & ssh-keygen -q -t ed25519 -N '' -C owner -f (Join-Path $w 'owner')
    & ssh-keygen -q -t ed25519 -N '' -C other -f (Join-Path $w 'other')
    $pub = (Get-Content (Join-Path $w 'owner.pub')) -split ' '
    Set-Content (Join-Path $root 'allowed_signers') "tomek namespaces=`"git`" $($pub[0]) $($pub[1])"

    function G { & git -C $origin -c user.name=T -c user.email=t@example.invalid -c gpg.format=ssh @args 2>&1 | Out-Null }
    function Release([string]$Version, [string]$Manifest = $Version, [string]$Key = 'owner', [switch]$Unsigned) {
        Set-Content (Join-Path $origin 'windows/pc-manifest.json') (@{ version = $Manifest; requires = @{ launcher = 1; pwsh = '7.4'; deps = 'd1'; listen = 'x'; ha_api = 1
            config_keys = @{ 'desk-tray' = @('push_token'); 'meeting-reminder' = @('reminder_webhook_url') } } } | ConvertTo-Json -Depth 4)
        G add -A; G commit -q -m $Version
        if ($Unsigned) { G tag -a $Version -m $Version } else { G -c "user.signingkey=$(Join-Path $w $Key)" tag -s $Version -m $Version }
    }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $origin 'windows')
    # The fake app: logs its version, sleeps, exits with the code in its data folder (default 0).
    Set-Content (Join-Path $origin 'app.ps1') @'
param([string]$DataDir, [string]$AppVersion, [string]$DeskAppsRoot)
Add-Content (Join-Path $DataDir 'ran.txt') $AppVersion
$s = Join-Path $DataDir 'sleep.txt'; if (Test-Path $s) { Start-Sleep -Seconds ([int](Get-Content $s)) }
$c = Join-Path $DataDir "exit-$AppVersion.txt"; if (Test-Path $c) { exit ([int](Get-Content $c)) }
exit 0
'@
    & git init -q -b main $origin
    Release 'pc-v1.0.0'
    & git clone -q --no-checkout --no-tags $origin (Join-Path $root 'repo')
    $worker = Join-Path $launcher 'Update-DeskApps.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    function Check { & $pwsh -NoProfile -File $worker -Mode Check -Root $root | Out-Null; Get-Content -Raw (Join-Path $root 'update-check.json') | ConvertFrom-Json }
    function Prepare($c, [int]$HaApi = 1, [switch]$Initial) {
        & $pwsh -NoProfile -Command "& '$worker' -Mode Prepare -Root '$root' -Tag '$($c.tag)' -TagObject '$($c.tagObject)' -Commit '$($c.commit)' -HaApi $HaApi $(if ($Initial) { '-Initial' }) -DataDirs @{ 'desk-tray' = '$($data['desk-tray'])'; 'meeting-reminder' = '$($data['meeting-reminder'])' } -ListenCheck { `$true }" | Out-Null
        Get-Content -Raw (Join-Path $root 'update-prepare.json') | ConvertFrom-Json
    }
    function State { Get-Content -Raw (Join-Path $root 'state.json') | ConvertFrom-Json }

    It 'finds and installs the first signed release' {
        $c = Check
        $c.status | Should Be 'available'; $c.tag | Should Be 'pc-v1.0.0'
        (Prepare $c -Initial).status | Should Be 'ready'
        (State).apps.'desk-tray'.current | Should Be 'pc-v1.0.0'
        (State).apps.'meeting-reminder'.current | Should Be 'pc-v1.0.0'
        Test-Path (Join-Path $root 'releases/pc-v1.0.0/app.ps1') | Should Be $true
    }
    It 'ignores an unsigned tag, a foreign key and a manifest of another version' {
        Release 'pc-v1.0.1' -Unsigned
        Release 'pc-v1.0.2' -Key 'other'
        Release 'pc-v1.0.3' -Manifest 'pc-v1.0.0'
        (Check).status | Should Be 'none'
        Get-Content (Join-Path $root 'update.log') -Raw | Should Match 'skipped pc-v1.0.3'
    }
    It 'offers a good release and refuses one whose tag changed or whose needs are not met, writing nothing' {
        Release 'pc-v1.0.4'
        $c = Check
        $c.tag | Should Be 'pc-v1.0.4'
        $bad = [pscustomobject]@{ tag = $c.tag; tagObject = $c.tagObject; commit = ('0' * 40) }
        (Prepare $bad).reason | Should Match 'changed'
        (Prepare $c -HaApi 0).status | Should Be 'refused'
        Test-Path (Join-Path $root 'releases/pc-v1.0.4') | Should Be $false
        (Prepare $c).status | Should Be 'ready'
        (State).apps.'desk-tray'.pending | Should Be 'pc-v1.0.4'
    }
    $def = @{ exe = $pwsh; script = 'app.ps1'; dataDir = $data['desk-tray']; updater = $true }
    $starter = Join-Path $launcher 'Start-DeskApp.ps1'
    function Run-Starter { & $pwsh -NoProfile -Command "& '$starter' -App desk-tray -Root '$root' -TrialSeconds 30 -PollSeconds 1 -RestartDelaySeconds 1 -Definition @{ exe = '$pwsh'; script = 'app.ps1'; dataDir = '$($def.dataDir)'; updater = `$true }" | Out-Null; $LASTEXITCODE }

    It 'goes back to the previous release when the new one dies in its trial' {
        Set-Content (Join-Path $def.dataDir 'exit-pc-v1.0.4.txt') '7'
        Run-Starter | Should Be 0
        $a = (State).apps.'desk-tray'
        $a.current | Should Be 'pc-v1.0.0'; $a.failed | Should Be 'pc-v1.0.4'
        (Get-Content (Join-Path $def.dataDir 'ran.txt')) -join ',' | Should Be 'pc-v1.0.4,pc-v1.0.0'
        (Check).status | Should Be 'none'
    }
    It 'keeps a release that lives through its trial' {
        Release 'pc-v1.0.5'
        $c = Check; (Prepare $c).status | Should Be 'ready'
        Set-Content (Join-Path $def.dataDir 'sleep.txt') '3'
        & $pwsh -NoProfile -Command "& '$starter' -App desk-tray -Root '$root' -TrialSeconds 2 -PollSeconds 1 -Definition @{ exe = '$pwsh'; script = 'app.ps1'; dataDir = '$($def.dataDir)'; updater = `$true }" | Out-Null
        $a = (State).apps.'desk-tray'
        $a.current | Should Be 'pc-v1.0.5'; $a.previous | Should Be 'pc-v1.0.0'; $a.trial | Should Be $null
        Get-Content (Join-Path $root 'launcher.log') -Raw | Should Match 'trial passed: pc-v1.0.5'
    }
    It 'restarts the meeting reminder for an update only when no meeting waits' {
        $rd = $data['meeting-reminder']
        Release 'pc-v1.0.6'
        $c = Check; (Prepare $c).status | Should Be 'ready'
        Set-Content (Join-Path $rd 'sleep.txt') '60'
        Set-Content (Join-Path $rd 'queue.json') ('{"count":1,"next":"' + [DateTime]::UtcNow.AddMinutes(30).ToString('o') + '"}')
        # The reminder is already on pc-v1.0.0 with pc-v1.0.6 pending: start it as if after an earlier start.
        $null = Invoke-DeskStateLocked $root { param($s) $s.apps['meeting-reminder'].pending = $null; $s }
        $p = Start-Process -PassThru -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', "& '$starter' -App meeting-reminder -Root '$root' -TrialSeconds 30 -PollSeconds 1 -Definition @{ exe = '$pwsh'; script = 'app.ps1'; dataDir = '$rd'; updater = `$false }")
        Start-Sleep -Seconds 4
        $null = Invoke-DeskStateLocked $root { param($s) $s.apps['meeting-reminder'].pending = 'pc-v1.0.6'; $s }
        Start-Sleep -Seconds 4
        (Get-Content (Join-Path $rd 'ran.txt')) -join ',' | Should Be 'pc-v1.0.0'
        Set-Content (Join-Path $rd 'queue.json') '{"count":0,"next":""}'
        Start-Sleep -Seconds 5
        (Get-Content (Join-Path $rd 'ran.txt')) -join ',' | Should Be 'pc-v1.0.0,pc-v1.0.6'
        (State).apps.'meeting-reminder'.current | Should Be 'pc-v1.0.6'
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Get-Process pwsh -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.Id -ne $p.Id } | ForEach-Object { try { if ($_.CommandLine -match 'app\.ps1') { $_.Kill() } } catch { } }
    }
    It 'refuses a second starter for the same app' {
        $p = Start-Process -PassThru -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', "& '$starter' -App desk-tray -Root '$root' -PollSeconds 1 -Definition @{ exe = '$pwsh'; script = 'app.ps1'; dataDir = '$($def.dataDir)'; updater = `$true }")
        Set-Content (Join-Path $def.dataDir 'sleep.txt') '20'
        Start-Sleep -Seconds 3
        Run-Starter | Should Be 0
        Get-Content (Join-Path $root 'launcher.log') -Raw | Should Match 'another starter runs this app'
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    if (-not $env:DESKAPPS_KEEP) { Remove-Item -Recurse -Force $w -ErrorAction SilentlyContinue } else { Write-Host "kept $w" }
}
