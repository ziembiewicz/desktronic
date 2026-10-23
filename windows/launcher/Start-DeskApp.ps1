<#
.SYNOPSIS
  Starter for one desk app (the panel or the meeting reminder): runs it from the current release, applies a
  prepared update when the app restarts, and goes back to the previous release when a new one does not stay up.

.DESCRIPTION
  The scheduled tasks "desk-tray" and "meeting-reminder" run this script (conhost --headless pwsh) instead of
  the apps. It stays as their parent and decides what happens when the app ends:
    exit 3            the panel asks for an update: a pending release becomes current, the app starts again
    exit 0            the owner chose Exit: the starter ends too (and with it the task)
    any other end     within the trial (the first TrialSeconds of a new release): back to the previous release,
                      the failed one is never offered again; after the trial: start again after 60 s, at most
                      3 times an hour, then stop
  The meeting reminder cannot ask for an update itself: while a release is pending for it, the starter restarts
  it as soon as it waits for no meeting (queue.json), because a restart forgets the meetings it waits for.
  One starter per app (mutex Local\DeskApps.Launcher.<app>); a second one ends at once.
  A file "simulate-crash" in the DeskApps folder that holds the app name makes the next start within a trial
  count as a crash (used once to try the way back on a real PC; the file is deleted when used).
  Log: launcher.log in the DeskApps folder.
#>
#Requires -Version 7.4
param(
    [Parameter(Mandatory)][ValidateSet('desk-tray', 'meeting-reminder')][string]$App,
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'DeskApps'),
    [int]$TrialSeconds = 60,
    [int]$PollSeconds = 5,
    [int]$RestartDelaySeconds = 60,
    # Tests replace the app: @{ exe; script (relative to the release); dataDir }.
    [hashtable]$Definition
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DeskApps.psm1') -Force
$logPath = Join-Path $Root 'launcher.log'

function Write-Log([string]$Message) {
    try {
        if ((Test-Path $logPath) -and (Get-Item $logPath).Length -ge 512KB) { Move-Item -Force $logPath "$logPath.1" }
        Add-Content -Path $logPath -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss} {1} {2}' -f (Get-Date), $App, $Message)
    }
    catch { }
}

if (-not $Definition) {
    $Definition = switch ($App) {
        'desk-tray' { @{ exe = (Get-Process -Id $PID).Path; script = 'windows/desk-tray/desk-tray.ps1'; dataDir = (Join-Path $env:LOCALAPPDATA 'DeskTray'); updater = $true } }
        'meeting-reminder' { @{ exe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); script = 'windows/meeting-reminder.ps1'; dataDir = (Join-Path $env:LOCALAPPDATA 'meeting-reminder'); updater = $false } }
    }
}

$mutex = [Threading.Mutex]::new($false, "Local\DeskApps.Launcher.$App")
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { Write-Log 'another starter runs this app; ending'; exit 0 }

$restarts = New-Object System.Collections.Generic.List[datetime]
$script:Decision = $null
try {
    while ($true) {
        $st = Invoke-DeskStateLocked $Root { param($s) $null = Step-DeskApply $s.apps[$App] ([DateTime]::UtcNow); $s }
        $a = $st.apps[$App]
        if (-not $a.current) { Write-Log 'no release installed (run Install-DeskApps.ps1)'; exit 1 }
        $release = Join-Path (Join-Path $Root 'releases') $a.current
        $code = $null
        $sim = Join-Path $Root 'simulate-crash'
        if ($a.trial -and (Test-Path $sim) -and ((Get-Content -Raw $sim).Trim() -eq $App)) {
            Remove-Item -Force $sim
            Write-Log "simulated crash of $($a.current)"
            $code = 99
        }
        else {
            $psi = [Diagnostics.ProcessStartInfo]::new($Definition.exe)
            foreach ($x in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $release $Definition.script),
                             '-DataDir', $Definition.dataDir, '-AppVersion', $a.current)) { $psi.ArgumentList.Add($x) }
            if ($Definition.updater) { $psi.ArgumentList.Add('-DeskAppsRoot'); $psi.ArgumentList.Add($Root) }
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $p = [Diagnostics.Process]::Start($psi)
            Write-Log "started $($a.current)$(if ($a.trial) { ' (trial)' }) pid $($p.Id)"
            while (-not $p.WaitForExit($PollSeconds * 1000)) {
                if ($a.trial) {
                    $null = Invoke-DeskStateLocked $Root {
                        param($s)
                        if (Step-DeskTrialPassed $s.apps[$App] ([DateTime]::UtcNow) $TrialSeconds) { Write-Log "trial passed: $($s.apps[$App].current)"; return $s }
                        $null
                    }
                    $a = (Invoke-DeskStateLocked $Root { param($s) $null }).apps[$App]
                }
                if (-not $Definition.updater) {
                    $now = (Invoke-DeskStateLocked $Root { param($s) $null }).apps[$App]
                    $qf = Join-Path $Definition.dataDir 'queue.json'
                    $q = if (Test-Path $qf) { Get-Content -Raw $qf -ErrorAction SilentlyContinue } else { '' }
                    if ($now.pending -and $now.pending -ne $now.current -and (Test-DeskQueueEmpty $q ([DateTime]::UtcNow))) {
                        Write-Log "no meeting waiting: restarting for $($now.pending)"
                        try { $p.Kill($true) } catch { }
                        $p.WaitForExit()
                        $code = 3
                        break
                    }
                }
            }
            if ($null -eq $code) { $code = $p.ExitCode }
        }
        $null = Invoke-DeskStateLocked $Root { param($s) $script:Decision = Step-DeskExit $s.apps[$App] $code ([DateTime]::UtcNow) $TrialSeconds; $s }
        $now = (Invoke-DeskStateLocked $Root { param($s) $null }).apps[$App]
        switch ($script:Decision) {
            'apply' { Write-Log "exit 3: applying $(if ($now.pending) { $now.pending } else { 'nothing new' })" }
            'end' { Write-Log 'exit 0: the app was closed'; exit 0 }
            'rollback' { Write-Log "exit $code during the trial: back to $($now.current); $($a.current) marked failed" }
            'stop' { Write-Log "exit $code during the trial and no previous release: stopping"; exit 1 }
            'restart' {
                $cut = [DateTime]::UtcNow.AddHours(-1)
                $null = $restarts.RemoveAll({ param($t) $t -lt $cut })
                if ($restarts.Count -ge 3) { Write-Log "exit ${code}: 3 restarts in the last hour, stopping"; exit 1 }
                $restarts.Add([DateTime]::UtcNow)
                Write-Log "exit $code`: starting again in $RestartDelaySeconds s"
                Start-Sleep -Seconds $RestartDelaySeconds
            }
        }
    }
}
catch {
    # Without this the starter would end without a trace and leave the app running on its own.
    Write-Log "starter failed: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber) of $(Split-Path -Leaf $_.InvocationInfo.ScriptName))"
    exit 1
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
