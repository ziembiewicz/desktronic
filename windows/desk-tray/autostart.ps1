<#
.SYNOPSIS
  Starts the desk panel at logon, with no window: registers the scheduled task "desk-tray" and starts it.

.DESCRIPTION
  The task runs desk-tray.ps1 from %LOCALAPPDATA%\DeskTray\ through "conhost.exe --headless", so no console
  window shows, like the meeting reminder. It needs no admin rights and runs only for your account.
  Running this again replaces the task; the copy of the panel it starts ends the one already running.
  Ends by showing the last lines of the panel log: "start: ... listener=True" means the panel is up.

.NOTES
  PowerShell 7.4 or newer, from your normal account:
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File .\autostart.ps1
  Stop-ScheduledTask ends only the conhost.exe wrapper; close the panel with Exit in the tray menu.
  Unregister-ScheduledTask -TaskName desk-tray removes the task.
#>
#Requires -Version 7.4
$ErrorActionPreference = 'Stop'

$dir = Join-Path $env:LOCALAPPDATA 'DeskTray'
$script = Join-Path $dir 'desk-tray.ps1'
if (-not (Test-Path $script)) { throw "Not found: $script (see README.md, Install - PC)" }

$pwsh = (Get-Command pwsh.exe).Source
$action = New-ScheduledTaskAction -Execute 'conhost.exe' `
  -Argument "--headless `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'desk-tray' -Action $action -Trigger $trigger -Settings $settings `
  -Description 'Desk panel in the tray (Home Assistant)' -Force | Out-Null
Start-ScheduledTask -TaskName 'desk-tray'

Start-Sleep -Seconds 5
Get-Content (Join-Path $dir 'desk-tray.log') -Tail 3
