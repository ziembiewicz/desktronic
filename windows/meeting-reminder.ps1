<#
.SYNOPSIS
  Nudges the standing desk before a meeting, driven by the Outlook on the web reminder toast.

.DESCRIPTION
  Outlook on the web, open in Microsoft Edge with Settings > General > Notifications > Calendar >
  Notification style = Browser, shows every event reminder as a Windows toast: the first line is the
  event title, the second line is "HH:MM <location>". This script reads the toasts through the Windows
  notification listener, takes the start time T0 from the second line and keeps it in memory.

  At T0 - 30 s it posts {"step":"warn"} to a Home Assistant webhook, at T0 - 15 s it posts {"step":"go"}
  (WarnLeadSeconds and GoLeadSeconds before T0): the desk is up when the meeting starts.
  Home Assistant only moves the desk (see homeassistant/). Nothing else leaves the PC: no titles,
  no locations, no times.

  The PC keeps the time, Home Assistant keeps no schedule. If the PC sleeps or shuts down, or the
  script restarts between the reminder and the meeting, nothing is sent and the desk stays where it
  is. A step that would go out more than LateSeconds late is skipped, and a skipped warning cancels
  that meeting's "go" too: the desk never moves late and never moves without the warning first.

  A reminder counts only when
    - the toast comes from an allowed app (config "apps", default Microsoft Edge Stable),
    - its second line starts with a 24-hour time, without AM/PM,
    - that time is in the future and at most MaxLeadMinutes after the toast was created.
  The last rule drops reminders snoozed past the start, reminders "at the time of the event" and
  stale toasts from yesterday that are still in the notification center.

  A reminder whose first line (the event title) contains a blocker word (config "blocker_words",
  default "Blocker", any letter case, any part of the title) is logged as "excluded" and never
  moves the desk. It does not silence another meeting that starts at the same time.

  Only one copy runs at a time: on start the script ends any older copy of itself.

.NOTES
  Windows PowerShell 5.1 (powershell.exe). The notification listener is a WinRT API, which
  PowerShell 7 does not load without extra libraries.
  This file is plain ASCII on purpose: Windows PowerShell 5.1 reads a script without a BOM as ANSI.

  Config file next to this script (not in the repository), config.json:
    { "reminder_webhook_url": "http://192.0.2.10:8123/api/webhook/MEETING_REMINDER_WEBHOOK_ID",
      "apps": ["Microsoft.MicrosoftEdge.Stable_8wekyb3d8bbwe!App"],
      "blocker_words": ["Blocker"] }
  "blocker_words" missing or null means ["Blocker"]; [] turns blockers off. ASCII words only.
  Log: meeting-reminder.log next to this script (UTF-8, rotated at 512 KB). It never contains titles
  or blocker words, only their count.
  Install: see windows/README.md.
#>
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [int]$PollSeconds = 2,
    [int]$WarnLeadSeconds = 30,
    [int]$GoLeadSeconds = 15,
    [int]$MaxLeadMinutes = 60,
    [int]$LateSeconds = 10
)

$logPath = Join-Path $PSScriptRoot 'meeting-reminder.log'
$logMaxBytes = 512KB
$defaultApps = @('Microsoft.MicrosoftEdge.Stable_8wekyb3d8bbwe!App')

function Write-Log {
    param([string]$Message)
    try {
        if ((Test-Path $logPath) -and (Get-Item $logPath).Length -ge $logMaxBytes) {
            Move-Item -Force -Path $logPath -Destination "$logPath.1"
        }
        Add-Content -Path $logPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message)
    }
    catch {
        # Logging must never stop the script.
    }
}

function Get-MeetingStart {
    # Start time of the meeting from the second line of the reminder toast, or $null.
    # Created is the local time the toast was created. Pure function: no clock, no I/O.
    param([string]$Text, [datetime]$Created, [int]$MaxLeadMinutes = 60)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    if ($Text -match '^\s*\d{1,2}:\d{2}\s*(AM|PM)\b') { return $null }
    if ($Text -notmatch '^\s*([01]?\d|2[0-3]):([0-5]\d)(\s|$)') { return $null }
    $start = $Created.Date.AddHours([int]$Matches[1]).AddMinutes([int]$Matches[2])
    if ($start -le $Created) { $start = $start.AddDays(1) }
    if (($start - $Created).TotalMinutes -gt $MaxLeadMinutes) { return $null }
    return $start
}

function Get-BlockerWords {
    # Blocker words from the config value: $null (key missing or null) means the default list,
    # anything else keeps only its non-blank strings, trimmed. So [] turns blockers off.
    param($Value)
    if ($null -eq $Value) { return @('Blocker') }
    $words = @()
    foreach ($w in @($Value)) {
        if ($w -is [string] -and -not [string]::IsNullOrWhiteSpace($w)) { $words += $w.Trim() }
    }
    return $words
}

function Test-Blocker {
    # True when the title contains one of the words, ignoring letter case. Blank words never match,
    # so a stray " " in the config cannot silence every meeting. Pure function.
    param([string]$Title, [object[]]$Words)
    if ([string]::IsNullOrEmpty($Title)) { return $false }
    foreach ($w in @($Words)) {
        if ($w -isnot [string] -or [string]::IsNullOrWhiteSpace($w)) { continue }
        if ($Title.IndexOf($w.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Add-Meeting {
    # Adds a meeting to the in-memory schedule. Returns 'queued', 'duplicate' or 'too-late'.
    param([System.Collections.ArrayList]$Schedule, [datetime]$Start, [datetime]$Now, [int]$WarnLeadSeconds = 30)
    if ($Start -le $Now.AddSeconds($WarnLeadSeconds + 5)) { return 'too-late' }
    foreach ($e in $Schedule) { if ($e.Start -eq $Start) { return 'duplicate' } }
    [void]$Schedule.Add([pscustomobject]@{ Start = $Start; Warned = $false })
    return 'queued'
}

function Get-DueStep {
    # Steps due at Now: 'warn', 'go', 'skip-warn' or 'skip-go'. Removes finished and skipped meetings
    # from the schedule. A skipped warning removes the meeting, so the desk never moves unwarned.
    # The warning is due WarnLeadSeconds before the start, go GoLeadSeconds before it.
    param([System.Collections.ArrayList]$Schedule, [datetime]$Now, [int]$WarnLeadSeconds = 30, [int]$LateSeconds = 10, [int]$GoLeadSeconds = 0)
    foreach ($e in @($Schedule)) {
        $warnAt = $e.Start.AddSeconds(-$WarnLeadSeconds)
        $goAt = $e.Start.AddSeconds(-$GoLeadSeconds)
        if (-not $e.Warned -and $Now -ge $warnAt) {
            $e.Warned = $true
            if (($Now - $warnAt).TotalSeconds -le $LateSeconds) {
                [pscustomobject]@{ Start = $e.Start; Step = 'warn' }
            }
            else {
                $Schedule.Remove($e)
                [pscustomobject]@{ Start = $e.Start; Step = 'skip-warn' }
                continue
            }
        }
        if ($Now -ge $goAt) {
            $Schedule.Remove($e)
            if (($Now - $goAt).TotalSeconds -le $LateSeconds) {
                [pscustomobject]@{ Start = $e.Start; Step = 'go' }
            }
            else {
                [pscustomobject]@{ Start = $e.Start; Step = 'skip-go' }
            }
        }
    }
}

function Stop-OlderInstance {
    # The newest copy wins, so an upgraded script replaces the old one instead of running beside it.
    $scriptName = Split-Path -Leaf $PSCommandPath
    $self = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    $older = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*$scriptName*" -and
                       $_.CreationDate -lt $self.CreationDate }
    foreach ($p in $older) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Log "replaced older copy PID $($p.ProcessId) started $($p.CreationDate)"
    }
}

function Wait-WinRt {
    # Waits for a WinRT IAsyncOperation and returns its result (Windows PowerShell 5.1).
    param($Operation, [type]$ResultType)
    $task = $script:asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void]$task.Wait(-1)
    $task.Result
}

function Send-Step {
    param([string]$Url, [string]$Step)
    $body = @{ step = $Step } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 5 | Out-Null
}

function Start-Main {
    $ErrorActionPreference = 'Stop'
    try {
        $raw = Get-Content -Raw -Path $ConfigPath
        # The ConvertFrom-Json error quotes the file, blocker words included: keep them out of the log.
        try { $config = $raw | ConvertFrom-Json }
        catch { throw "$ConfigPath is not valid JSON" }
        $url = $config.reminder_webhook_url
        if (-not $url) { throw "reminder_webhook_url missing in $ConfigPath" }
        $apps = @($config.apps | Where-Object { $_ })
        if ($apps.Count -eq 0) { $apps = $defaultApps }
        $blockerWords = @(Get-BlockerWords $config.blocker_words)
    }
    catch {
        Write-Log "ERROR config: $($_.Exception.Message)"
        exit 1
    }
    try { Stop-OlderInstance }
    catch { Write-Log "ERROR older copy check: $($_.Exception.Message)" }

    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        [void][Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.UI.Notifications.UserNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current
        $access = "$($listener.GetAccessStatus())"
        if ($access -eq 'Unspecified') {
            # First run: Windows asks the user once. Run the script by hand the first time (see README).
            $access = "$(Wait-WinRt ($listener.RequestAccessAsync()) ([Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]))"
        }
    }
    catch {
        Write-Log "ERROR notification listener: $($_.Exception.Message)"
        exit 1
    }
    $listT = [System.Collections.Generic.IReadOnlyList[Windows.UI.Notifications.UserNotification]]
    $toastKind = [Windows.UI.Notifications.NotificationKinds]::Toast
    $generic = [Windows.UI.Notifications.KnownNotificationBindings]::ToastGeneric
    Write-Log "start: access=$access apps=$($apps -join ',') poll=${PollSeconds}s warn=${WarnLeadSeconds}s go=-${GoLeadSeconds}s maxlead=${MaxLeadMinutes}min blockers=$($blockerWords.Count)"

    $schedule = [System.Collections.ArrayList]::new()
    $seen = @{}
    $lastError = $null
    $lastAccess = $access

    while ($true) {
        try {
            $access = "$($listener.GetAccessStatus())"
            if ($access -ne $lastAccess) { Write-Log "access=$access"; $lastAccess = $access }
            if ($access -eq 'Allowed') {
                # Remember only the IDs still in the notification center, so the set stays small.
                $current = @{}
                foreach ($n in (Wait-WinRt ($listener.GetNotificationsAsync($toastKind)) $listT)) {
                    $current[$n.Id] = 1
                    if ($seen.ContainsKey($n.Id)) { continue }
                    if ($apps -notcontains $n.AppInfo.AppUserModelId) { continue }
                    $binding = $n.Notification.Visual.GetBinding($generic)
                    if ($null -eq $binding) { continue }
                    $texts = @($binding.GetTextElements() | ForEach-Object { $_.Text })
                    if ($texts.Count -lt 2) { continue }
                    $start = Get-MeetingStart -Text $texts[1] -Created $n.CreationTime.LocalDateTime -MaxLeadMinutes $MaxLeadMinutes
                    if ($null -eq $start) { continue }
                    # Its own try: an error here must not stop the other notifications of this round.
                    # On error the reminder counts as a meeting, as before blockers existed.
                    $blocked = $false
                    try { $blocked = Test-Blocker -Title $texts[0] -Words $blockerWords }
                    catch { Write-Log 'ERROR blocker check' }
                    if ($blocked) {
                        Write-Log ('reminder T0={0:yyyy-MM-dd HH:mm} excluded' -f $start)
                        continue
                    }
                    $result = Add-Meeting -Schedule $schedule -Start $start -Now (Get-Date) -WarnLeadSeconds $WarnLeadSeconds
                    Write-Log ('reminder T0={0:yyyy-MM-dd HH:mm} {1}' -f $start, $result)
                }
                $seen = $current
            }
            foreach ($d in @(Get-DueStep -Schedule $schedule -Now (Get-Date) -WarnLeadSeconds $WarnLeadSeconds -LateSeconds $LateSeconds -GoLeadSeconds $GoLeadSeconds)) {
                if ($d.Step -in 'warn', 'go') {
                    try {
                        Send-Step -Url $url -Step $d.Step
                        Write-Log ('{0} sent T0={1:HH:mm}' -f $d.Step, $d.Start)
                    }
                    catch { Write-Log ('ERROR {0} T0={1:HH:mm}: {2}' -f $d.Step, $d.Start, $_.Exception.Message) }
                }
                else { Write-Log ('{0} T0={1:HH:mm} (late)' -f $d.Step, $d.Start) }
            }
            $lastError = $null
        }
        catch {
            # A transient read error: keep polling. Log each distinct error once, not every round.
            if ($_.Exception.Message -ne $lastError) {
                $lastError = $_.Exception.Message
                Write-Log "ERROR: $lastError"
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

# Dot-sourcing (tests) only defines the functions above; running the file starts the loop.
if ($MyInvocation.InvocationName -ne '.') { Start-Main }
