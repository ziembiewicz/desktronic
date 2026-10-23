<#
.SYNOPSIS
  Moves the desk panel and the meeting reminder onto the starter and signed releases. Run once, by hand.

.DESCRIPTION
  After this, a new release is installed from the panel (dot on the tray icon, then Yes); no files are copied
  by hand any more. What it does:
    1. checks Git for Windows and PowerShell 7.4;
    2. creates %LOCALAPPDATA%\DeskApps\: the starter (this folder's .ps1/.psm1 files), allowed_signers built
       from your SSH public key, and a clone of the GitHub mirror;
    3. finds the newest pc-vX.Y.Z tag signed by that key (stops if there is none);
    4. stops both apps, installs the panel libraries into %LOCALAPPDATA%\DeskTray (lib\deps.json),
       creates the release worktree and makes it current;
    5. moves the old hand-copied scripts into pre-launcher\ (config.json, logs and lib\ stay where they are);
    6. points the scheduled tasks "desk-tray" and "meeting-reminder" at the starter and starts them.
  Run it from your own clone of the repository (Forgejo), where this file was reviewed, not from a download:
  it decides which key the PC trusts.
  Running it again is safe: with a release already installed and nothing newer, it refreshes the starter files,
  allowed_signers and the scheduled tasks and leaves the apps and their release alone.

.NOTES
  PowerShell 7.4 or newer, your normal account (no admin rights):
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\launcher\Install-DeskApps.ps1 -PublicKey "$HOME\.ssh\id_ed25519.pub"
  -HaApi: the "api" the Home Assistant side already pushes (1 once desk_panel_push carries it).
#>
#Requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$PublicKey,
    [string]$Principal = 'tomek',
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'DeskApps'),
    [int]$HaApi = 1
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeskApps.psm1') -Force

function Step([string]$Text) { Write-Host "-- $Text" }

Step 'Git for Windows'
$g = Get-DeskGit
$ver = (& $g.git --version) -replace '^git version ([0-9]+\.[0-9]+).*$', '$1'
if ([version]$ver -lt [version]'2.34') { throw "Git $ver is too old for SSH signatures (2.34+): winget upgrade --id Git.Git" }

Step "folder $Root"
$launcher = Join-Path $Root 'launcher'
$null = New-Item -ItemType Directory -Force -Path $launcher, (Join-Path $Root 'releases')
foreach ($f in 'DeskApps.psm1', 'Start-DeskApp.ps1', 'Update-DeskApps.ps1') { Copy-Item -Force (Join-Path $PSScriptRoot $f) $launcher }

Step 'allowed_signers'
$key = (Get-Content -Raw -Path $PublicKey).Trim()
if ($key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+|sk-ssh-ed25519@openssh\.com) [A-Za-z0-9+/=]+') { throw "$PublicKey does not look like an SSH public key" }
$parts = $key -split ' '
Set-Content -Path (Join-Path $Root 'allowed_signers') -Encoding ascii -Value "$Principal namespaces=`"git`" $($parts[0]) $($parts[1])"

Step 'clone of the GitHub mirror'
$repo = Join-Path $Root 'repo'
if (-not (Test-Path (Join-Path $repo '.git'))) {
    & $g.git -c credential.helper= clone --no-checkout --no-tags (Get-DeskRemoteUrl) $repo
    if ($LASTEXITCODE -ne 0) { throw 'git clone failed' }
}
& $g.git -C $repo config transfer.fsckObjects true
& $g.git -C $repo config fetch.fsckObjects true

$worker = Join-Path $launcher 'Update-DeskApps.ps1'
$pwsh = (Get-Process -Id $PID).Path
Step 'newest signed release'
& $pwsh -NoProfile -File $worker -Mode Check -Root $Root
$check = Get-Content -Raw (Join-Path $Root 'update-check.json') | ConvertFrom-Json
$installed = (Invoke-DeskStateLocked $Root { param($s) $null }).apps['desk-tray'].current
$rerun = $check.status -eq 'none' -and $installed -and (Test-Path (Join-Path (Join-Path $Root 'releases') $installed))
if ($rerun) { Write-Host "   $installed is installed and nothing newer is signed: keeping it" }
elseif ($check.status -ne 'available') { throw "no signed release found ($($check.status) $($check.reason)); see $Root\update.log" }
else { Write-Host "   $($check.tag) ($($check.commit.Substring(0, 12)))" }

$deskData = Join-Path $env:LOCALAPPDATA 'DeskTray'
if (-not $rerun) {
    Step 'stopping both apps'
    foreach ($t in 'desk-tray', 'meeting-reminder') { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'desk-tray\.ps1|meeting-reminder\.ps1|Start-DeskApp\.ps1' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2

    Step 'panel libraries (lib\deps.json)'
    & $pwsh -NoProfile -File (Join-Path $PSScriptRoot '..\desk-tray\Install-DeskTrayDeps.ps1') -Root $deskData
    if ($LASTEXITCODE -ne 0) { throw 'Install-DeskTrayDeps.ps1 failed' }

    Step "release $($check.tag)"
    & $pwsh -NoProfile -File $worker -Mode Prepare -Root $Root -Tag $check.tag -TagObject $check.tagObject -Commit $check.commit -HaApi $HaApi -Initial
    $prep = Get-Content -Raw (Join-Path $Root 'update-prepare.json') | ConvertFrom-Json
    if ($prep.status -ne 'ready') { throw "release not prepared: $($prep.reason)" }
}

Step 'old hand-copied scripts -> pre-launcher\'
$old = @{
    $deskData = @('desk-tray.ps1', 'panel.html', 'autostart.ps1', 'Install-DeskTrayDeps.ps1', 'Set-DeskTrayFirewall.ps1')
    (Join-Path $env:LOCALAPPDATA 'meeting-reminder') = @('meeting-reminder.ps1')
}
foreach ($dir in $old.Keys) {
    $keep = Join-Path $dir 'pre-launcher'
    foreach ($f in $old[$dir]) {
        $src = Join-Path $dir $f
        if (Test-Path $src) { $null = New-Item -ItemType Directory -Force -Path $keep; Move-Item -Force $src $keep }
    }
}

Step 'scheduled tasks -> starter'
$start = Join-Path $launcher 'Start-DeskApp.ps1'
foreach ($app in 'desk-tray', 'meeting-reminder') {
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
        -Argument "--headless `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$start`" -App $app"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    # No task-level restarts: the starter restarts the app itself and stops after 3 crashes an hour.
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $null = Register-ScheduledTask -TaskName $app -Action $action -Trigger $trigger -Settings $settings `
        -Description "Desk app $app through the starter (DeskApps)" -Force
    # A task that already runs keeps its starter (the new definition counts from the next logon).
    if ((Get-ScheduledTask -TaskName $app).State -ne 'Running') { Start-ScheduledTask -TaskName $app }
}
Start-Sleep -Seconds 10
Get-Content (Join-Path $Root 'launcher.log') -Tail 4
$now = (Invoke-DeskStateLocked $Root { param($s) $null }).apps['desk-tray'].current
Write-Host "Done: both apps run $now. Next releases come through the dot on the tray icon."
