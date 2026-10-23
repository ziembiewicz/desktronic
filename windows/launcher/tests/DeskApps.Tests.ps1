# Pester 4.10.1. Unit tests of DeskApps.psm1, and an end-to-end run of Update-DeskApps.ps1 and Start-DeskApp.ps1
# against a local repository whose main gets merges like Forgejo makes them (needs git; skipped otherwise).
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# The scripts default to folders under LOCALAPPDATA, which Linux does not set; the tests pass every folder.
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [IO.Path]::GetTempPath() }
$launcher = Split-Path -Parent $here
Import-Module (Join-Path $launcher 'DeskApps.psm1') -Force

function New-App { $a = New-DeskAppState; $h = @{}; foreach ($k in $a.Keys) { $h[$k] = $a[$k] }; $h }
$t0 = [datetime]::new(2026, 10, 23, 9, 0, 0, [DateTimeKind]::Utc)

Describe 'ConvertTo-DeskVersion' {
    It 'reads v<N>' { ConvertTo-DeskVersion 'v14' | Should Be 14 }
    It 'counts old signed-tag releases, leading zeros and anything else as 0' {
        foreach ($t in 'pc-v1.0.1', 'v014', 'v0', 'V14', 'v14 ', '', $null) { ConvertTo-DeskVersion $t | Should Be 0 }
    }
}

Describe 'Test-DeskManifest' {
    $good = '{"requires":{"launcher":1,"pwsh":"7.4","deps":"d","listen":"http://+:8765/desk/","ha_api":1,"config_keys":{"desk-tray":["push_token"]}}}'
    It 'accepts a complete manifest' { Test-DeskManifest ($good | ConvertFrom-Json) | Should Be $null }
    It 'refuses a key it does not know' { Test-DeskManifest ($good.Replace('{"requires"', '{"version":"x","requires"') | ConvertFrom-Json) | Should Match "unknown key 'version'" }
    It 'refuses requirements it does not know' {
        $m = $good.Replace('"ha_api":1', '"ha_api":1,"gpu":2') | ConvertFrom-Json
        Test-DeskManifest $m | Should Match "unknown requirement 'gpu'"
    }
    It 'refuses a missing requirement' {
        $m = $good.Replace('"ha_api":1,', '') | ConvertFrom-Json
        Test-DeskManifest $m | Should Match "'ha_api' missing"
    }
}

Describe 'Test-DeskRequirements' {
    $m = '{"requires":{"launcher":1,"pwsh":"7.4","deps":"d1","listen":"x","ha_api":2,"config_keys":{"desk-tray":["push_token"]}}}' | ConvertFrom-Json
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
        $a = New-App; $a.current = 'v1'; $a.pending = 'v2'
        $null = Step-DeskApply $a $t0
        $a.current | Should Be 'v2'; $a.previous | Should Be 'v1'; $a.pending | Should Be $null
        $a.trial.version | Should Be 'v2'
    }
    It 'exit 3 applies, exit 0 ends without failure' {
        $a = New-App; $a.current = 'v2'; $a.trial = @{ version = 'v2'; since = $t0.ToString('o') }
        Step-DeskExit $a 3 $t0.AddSeconds(5) | Should Be 'apply'
        Step-DeskExit $a 0 $t0.AddSeconds(5) | Should Be 'end'
        @($a.failed).Count | Should Be 0
    }
    It 'a crash within the trial rolls back and marks the release failed' {
        $a = New-App; $a.current = 'v2'; $a.previous = 'v1'; $a.trial = @{ version = 'v2'; since = $t0.ToString('o') }
        Step-DeskExit $a 1 $t0.AddSeconds(10) | Should Be 'rollback'
        $a.current | Should Be 'v1'; $a.failed | Should Be 'v2'
    }
    It 'a crash within the trial with nothing to go back to stops' {
        $a = New-App; $a.current = 'v1'; $a.trial = @{ version = 'v1'; since = $t0.ToString('o') }
        Step-DeskExit $a 1 $t0.AddSeconds(10) | Should Be 'stop'
    }
    It 'a crash after the trial restarts the same release' {
        $a = New-App; $a.current = 'v2'; $a.previous = 'v1'; $a.trial = @{ version = 'v2'; since = $t0.ToString('o') }
        Step-DeskTrialPassed $a $t0.AddSeconds(61) | Should Be $true
        Step-DeskExit $a 1 $t0.AddSeconds(3600) | Should Be 'restart'
        $a.current | Should Be 'v2'
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

$haveTools = [bool](Get-Command git -ErrorAction SilentlyContinue)
Describe 'end to end with releases from main' {
    if (-not $haveTools) { It 'needs git' -Skip { } ; return }
    $w = Join-Path ([IO.Path]::GetTempPath()) ('deskapps-' + [guid]::NewGuid().ToString('N'))
    $origin = Join-Path $w 'origin'; $root = Join-Path $w 'DeskApps'
    $data = @{ 'desk-tray' = (Join-Path $w 'DeskTray'); 'meeting-reminder' = (Join-Path $w 'meeting-reminder') }
    $null = New-Item -ItemType Directory -Force -Path $origin, (Join-Path $root 'releases'), $data['desk-tray'], (Join-Path $data['desk-tray'] 'lib'), $data['meeting-reminder']
    Set-Content (Join-Path $data['desk-tray'] 'config.json') '{"panel_webhook_url":"x","panel_stop_webhook_url":"x","push_token":"x"}'
    Set-Content (Join-Path $data['meeting-reminder'] 'config.json') '{"reminder_webhook_url":"x"}'
    Set-Content (Join-Path $data['desk-tray'] 'lib/deps.json') '{"deps":"d1"}'

    function G { & git -C $origin -c user.name=T -c user.email=t@example.invalid @args 2>&1 | Out-Null }
    # A merge into main: a pull request branch with one commit, merged with --no-ff like Forgejo does.
    function Merge([string]$Name, [string]$File = 'windows/change.txt', [string]$Manifest) {
        G checkout -q -b $Name
        Set-Content (Join-Path $origin $File) $Name
        if ($Manifest) { Set-Content (Join-Path $origin 'windows/pc-manifest.json') $Manifest }
        G add -A; G commit -q -m $Name
        G checkout -q main; G merge -q --no-ff -m "Merge $Name" $Name
    }
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $origin 'windows'), (Join-Path $origin 'homeassistant')
    Set-Content (Join-Path $origin 'windows/pc-manifest.json') (@{ requires = @{ launcher = 2; pwsh = '7.4'; deps = 'd1'; listen = 'x'; ha_api = 1
        config_keys = @{ 'desk-tray' = @('push_token'); 'meeting-reminder' = @('reminder_webhook_url') } } } | ConvertTo-Json -Depth 4)
    # The fake app: logs its version, sleeps, exits with the code in its data folder (default 0).
    Set-Content (Join-Path $origin 'app.ps1') @'
param([string]$DataDir, [string]$AppVersion, [string]$DeskAppsRoot)
Add-Content (Join-Path $DataDir 'ran.txt') $AppVersion
$s = Join-Path $DataDir 'sleep.txt'; if (Test-Path $s) { Start-Sleep -Seconds ([int](Get-Content $s)) }
$c = Join-Path $DataDir "exit-$AppVersion.txt"; if (Test-Path $c) { exit ([int](Get-Content $c)) }
exit 0
'@
    & git init -q -b main $origin
    G add -A; G commit -q -m init
    & git clone -q --no-checkout --no-tags $origin (Join-Path $root 'repo')
    $worker = Join-Path $launcher 'Update-DeskApps.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    function Check { & $pwsh -NoProfile -File $worker -Mode Check -Root $root | Out-Null; Get-Content -Raw (Join-Path $root 'update-check.json') | ConvertFrom-Json }
    function Prepare($c, [int]$HaApi = 1, [switch]$Initial) {
        & $pwsh -NoProfile -Command "& '$worker' -Mode Prepare -Root '$root' -Tag '$($c.tag)' -Commit '$($c.commit)' -HaApi $HaApi $(if ($Initial) { '-Initial' }) -DataDirs @{ 'desk-tray' = '$($data['desk-tray'])'; 'meeting-reminder' = '$($data['meeting-reminder'])' } -ListenCheck { `$true }" | Out-Null
        Get-Content -Raw (Join-Path $root 'update-prepare.json') | ConvertFrom-Json
    }
    function State { Get-Content -Raw (Join-Path $root 'state.json') | ConvertFrom-Json }

    It 'installs main as the first release' {
        $c = Check
        $c.status | Should Be 'available'; $c.tag | Should Be 'v1'
        (Prepare $c -Initial).status | Should Be 'ready'
        (State).apps.'desk-tray'.current | Should Be 'v1'
        (State).apps.'meeting-reminder'.current | Should Be 'v1'
        Test-Path (Join-Path $root 'releases/v1/app.ps1') | Should Be $true
    }
    It 'offers nothing for a merge outside windows/' {
        Merge 'ha-only' 'homeassistant/a.yaml'
        (Check).status | Should Be 'none'
    }
    It 'refuses an invalid manifest on main' {
        Merge 'bad-manifest' -Manifest '{"requires":{},"extra":1}'
        $c = Check
        $c.status | Should Be 'error'; $c.reason | Should Match "v2: manifest: unknown key 'extra'"
    }
    It 'offers the next merge, from an old signed-tag release too, and refuses a stale or unmet one, writing nothing' {
        G checkout -q HEAD~1 -- windows/pc-manifest.json; G commit -q -m 'fix manifest'
        Merge 'feature-a'
        $null = Invoke-DeskStateLocked $root { param($s) $s.apps['meeting-reminder'].current = 'pc-v1.0.1'; $s }
        $c = Check
        $c.status | Should Be 'available'; $c.tag | Should Be 'v4'
        $null = Invoke-DeskStateLocked $root { param($s) $s.apps['meeting-reminder'].current = 'v1'; $s }
        $stale = [pscustomobject]@{ tag = 'v3'; commit = $c.commit }
        (Prepare $stale).reason | Should Match 'is not v3'
        (Prepare $c -HaApi 0).status | Should Be 'refused'
        Test-Path (Join-Path $root 'releases/v4') | Should Be $false
        (Prepare $c).status | Should Be 'ready'
        (State).apps.'desk-tray'.pending | Should Be 'v4'
    }
    It 'accepts the -TagObject an older panel still passes' {
        $c = Check
        $psi = [Diagnostics.ProcessStartInfo]::new($pwsh)
        foreach ($x in @('-NoProfile', '-File', $worker, '-Mode', 'Prepare', '-Root', $root, '-Tag', $c.tag, '-TagObject', '', '-Commit', $c.commit, '-HaApi', '1')) { $psi.ArgumentList.Add($x) }
        $psi.UseShellExecute = $false
        $p = [Diagnostics.Process]::Start($psi); $p.WaitForExit()
        (Get-Content -Raw (Join-Path $root 'update-prepare.json') | ConvertFrom-Json).reason | Should Not Match 'required|cannot be found'
    }
    $def = @{ exe = $pwsh; script = 'app.ps1'; dataDir = $data['desk-tray']; updater = $true }
    $starter = Join-Path $launcher 'Start-DeskApp.ps1'
    function Run-Starter { & $pwsh -NoProfile -Command "& '$starter' -App desk-tray -Root '$root' -TrialSeconds 30 -PollSeconds 1 -RestartDelaySeconds 1 -Definition @{ exe = '$pwsh'; script = 'app.ps1'; dataDir = '$($def.dataDir)'; updater = `$true }" | Out-Null; $LASTEXITCODE }

    It 'goes back to the previous release when the new one dies in its trial, and waits for the next merge' {
        Set-Content (Join-Path $def.dataDir 'exit-v4.txt') '7'
        Run-Starter | Should Be 0
        $a = (State).apps.'desk-tray'
        $a.current | Should Be 'v1'; $a.failed | Should Be 'v4'
        (Get-Content (Join-Path $def.dataDir 'ran.txt')) -join ',' | Should Be 'v4,v1'
        (Check).status | Should Be 'none'
        Get-Content (Join-Path $root 'update.log') -Raw | Should Match 'v4 failed its trial before'
    }
    It 'keeps a release that lives through its trial' {
        Merge 'feature-b'
        $c = Check; $c.tag | Should Be 'v5'; (Prepare $c).status | Should Be 'ready'
        Set-Content (Join-Path $def.dataDir 'sleep.txt') '3'
        & $pwsh -NoProfile -Command "& '$starter' -App desk-tray -Root '$root' -TrialSeconds 2 -PollSeconds 1 -Definition @{ exe = '$pwsh'; script = 'app.ps1'; dataDir = '$($def.dataDir)'; updater = `$true }" | Out-Null
        $a = (State).apps.'desk-tray'
        $a.current | Should Be 'v5'; $a.previous | Should Be 'v1'; $a.trial | Should Be $null
        Get-Content (Join-Path $root 'launcher.log') -Raw | Should Match 'trial passed: v5'
    }
    It 'restarts the meeting reminder for an update only when no meeting waits' {
        $rd = $data['meeting-reminder']
        Merge 'feature-c'
        $c = Check; (Prepare $c).status | Should Be 'ready'
        Set-Content (Join-Path $rd 'sleep.txt') '60'
        Set-Content (Join-Path $rd 'queue.json') ('{"count":1,"next":"' + [DateTime]::UtcNow.AddMinutes(30).ToString('o') + '"}')
        # The reminder is already on v1 with v6 pending: start it as if after an earlier start.
        $null = Invoke-DeskStateLocked $root { param($s) $s.apps['meeting-reminder'].pending = $null; $s }
        $p = Start-Process -PassThru -FilePath $pwsh -ArgumentList @('-NoProfile', '-Command', "& '$starter' -App meeting-reminder -Root '$root' -TrialSeconds 30 -PollSeconds 1 -Definition @{ exe = '$pwsh'; script = 'app.ps1'; dataDir = '$rd'; updater = `$false }")
        Start-Sleep -Seconds 4
        $null = Invoke-DeskStateLocked $root { param($s) $s.apps['meeting-reminder'].pending = 'v6'; $s }
        Start-Sleep -Seconds 4
        (Get-Content (Join-Path $rd 'ran.txt')) -join ',' | Should Be 'v1'
        Set-Content (Join-Path $rd 'queue.json') '{"count":0,"next":""}'
        Start-Sleep -Seconds 5
        (Get-Content (Join-Path $rd 'ran.txt')) -join ',' | Should Be 'v1,v6'
        (State).apps.'meeting-reminder'.current | Should Be 'v6'
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
