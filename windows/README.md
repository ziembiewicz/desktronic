# Meeting reminder (Windows)

`meeting-reminder.ps1` raises the desk for a meeting. It reads the meeting reminder that Outlook on the web
shows as a Windows notification, takes the start time from it, and tells Home Assistant when to move:

```
Outlook on the web (Edge) ──toast──> meeting-reminder.ps1 ──POST webhook (LAN only)──> HA: desk_meeting_reminder
                                     keeps T0 in memory       T0 - 30 s: {"step":"warn"}   one nudge
                                                              T0 - 15 s: {"step":"go"}     two nudges, 3 s, M3
```

- The PC keeps the time; Home Assistant keeps no schedule and only moves the desk.
- If the PC sleeps, shuts down or the script restarts before the meeting, nothing is sent and the desk stays
  put. A step that would be more than 10 s late is skipped; a skipped warning cancels the move as well.
- A reminder whose title contains a blocker word (default `Blocker`) never moves the desk.
- Only the step name leaves the PC: no meeting titles, no locations, no times. The log has no titles either.
- No third-party agent, no MQTT broker, no Home Assistant token.

## Requirements

- **Outlook on the web open in Microsoft Edge** (a pinned tab is enough). Teams on the web shares the same
  calendar but does not send reminders to Windows by itself; Outlook does.
- In Outlook on the web: **Settings > General > Notifications > Calendar > Event reminders > Notification style
  = Browser**, and allow notifications for the Outlook site when Edge asks. With the default style (Alert) the
  reminder stays inside the Outlook tab and Windows never sees it.
- **Windows PowerShell 5.1** (`powershell.exe`, part of Windows). The notification listener is a WinRT API,
  which PowerShell 7 does not load.
- The Home Assistant side from `../homeassistant/` (helper, script and automation).

"Do not disturb" in Windows is fine: notifications still go to the notification center, where the script
reads them.

## Install

> **Updates from signed releases.** `windows/launcher/Install-DeskApps.ps1` ([`launcher/README.md`](launcher/README.md))
> moves this script and the desk panel onto a starter that installs signed releases from the panel. The script
> then runs from the release with `-DataDir %LOCALAPPDATA%\meeting-reminder` (config.json and the log stay
> there) and writes `queue.json`, so an update restarts it only when no meeting waits.

Everything lives in one folder, `%LOCALAPPDATA%\meeting-reminder\`:

1. Copy `meeting-reminder.ps1` there. If Windows blocks it as downloaded, run `Unblock-File` on it.
2. Create `config.json` in the same folder (keep it out of any repository):

   ```json
   { "reminder_webhook_url": "http://192.0.2.10:8123/api/webhook/MEETING_REMINDER_WEBHOOK_ID" }
   ```

   Optional `"apps"` overrides the senders that count (default: Microsoft Edge Stable,
   `Microsoft.MicrosoftEdge.Stable_8wekyb3d8bbwe!App`).

   Optional `"blocker_words"` lists words that mark a calendar blocker: a reminder whose title contains one of
   them (any letter case, any part of the title) is logged as `excluded` and never moves the desk.

   ```json
   { "reminder_webhook_url": "http://192.0.2.10:8123/api/webhook/MEETING_REMINDER_WEBHOOK_ID",
     "blocker_words": ["Blocker", "Focus time"] }
   ```

   - Missing or `null`: `["Blocker"]`. An empty list `[]` turns blockers off. Note the difference from `"apps"`,
     where an empty list falls back to the default.
   - It must be a list. A single string such as `"Blocker, Focus"` is one word; commas do not split it.
   - ASCII words only: the file is read with the system code page, so Polish letters in a word do not match.

3. **Run it once by hand**, so Windows can ask for access to notifications:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\meeting-reminder\meeting-reminder.ps1"
   ```

   Check that the log starts with `start: access=Allowed`, then stop it with Ctrl+C.

4. Register a logon task for the current user (no admin rights needed). The task starts the script through
   `conhost.exe --headless`, so no window appears even when Windows Terminal is the default console:

   ```powershell
   $dir = Join-Path $env:LOCALAPPDATA 'meeting-reminder'
   $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
     -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dir\meeting-reminder.ps1`""
   $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
   $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
     -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
     -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
   Register-ScheduledTask -TaskName 'meeting-reminder' -Action $action -Trigger $trigger `
     -Settings $settings -Description 'Raises the desk for Outlook meeting reminders via Home Assistant' -Force
   Start-ScheduledTask -TaskName 'meeting-reminder'
   ```

   `ExecutionTimeLimit` zero matters: the default (72 h) would end the script after three days logged in.
   The task must run as the logged-on user: the notifications belong to that user.

### Stop and upgrade

`Stop-ScheduledTask` ends only the `conhost.exe` wrapper; the script keeps running. To stop it:

```powershell
Stop-ScheduledTask -TaskName 'meeting-reminder'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*meeting-reminder.ps1*' } |
  Invoke-CimMethod -MethodName Terminate
```

To upgrade, copy the new script over the old one and run `Start-ScheduledTask -TaskName 'meeting-reminder'`.
Run `Stop-ScheduledTask -TaskName 'meeting-reminder'` first: while the task shows `Running`, a second start is
ignored. On start the script ends any older copy of itself (`replaced older copy PID ...` in the log). Meetings already
waiting in the old copy are forgotten; the new copy picks them up again only if their reminder is still in the
notification center.

`config.json` is read only on start, so a change to it (for example a new blocker word) needs the same restart.
After editing it, check that the log shows a new `start:` line: a broken `config.json` stops the script, and then
the desk does not react to any meeting.

## Check

- Tests (pure functions, no Windows APIs), from the folder with the `tests` subfolder:

  ```powershell
  Import-Module Pester -MaximumVersion 4.99 -Force
  Invoke-Pester .\tests
  ```

- Task running: `Get-ScheduledTask meeting-reminder | Select-Object State` shows `Running`.
- Log: `Get-Content "$env:LOCALAPPDATA\meeting-reminder\meeting-reminder.log" -Tail 20`. It records the start
  (with `access=` and `blockers=`, the number of blocker words in use; the words themselves are not logged), every
  reminder taken (`reminder T0=... queued|duplicate|too-late|excluded`), every step sent or skipped, and errors. "sent" means Home Assistant answered, not that the desk moved: Home Assistant answers a
  webhook call even when its conditions stop the automation. Check the automation trace for the move.
- Webhook reachable from the PC (this moves the desk if the conditions in Home Assistant allow it):
  `Invoke-RestMethod -Method Post -ContentType 'application/json' -Body '{"step":"warn"}' -Uri <reminder_webhook_url>`

## Known limits

- Any Edge notification whose second line starts with a time 1-60 min ahead counts as a reminder, for example
  a chat message on a website that starts with "17:20 ...". The listener does not tell which website sent it.
- A meeting cancelled after its reminder still raises the desk.
- Blocker words match any part of the title: `Blocker` also excludes "Blockers review". A blocker does not silence
  another meeting that starts at the same time.
- Blocker detection was checked with one reminder at a time; several reminders at once were not tested.
- A reminder dismissed within about 15 s may never be seen: the listener shows new toasts with a delay.
- Reminders set more than 60 min before the meeting, snoozed past the start, or set "at the time of the event"
  are ignored.
- Only Microsoft Edge Stable counts by default; another Edge channel or an Outlook app has a different sender ID.
- The webhook is plain HTTP and `local_only`: anyone on the home network who knows its ID can nudge the desk.
