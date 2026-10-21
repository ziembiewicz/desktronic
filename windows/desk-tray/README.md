# Desk panel in the Windows tray

`desk-tray.ps1` puts a small desk icon in the Windows tray. A click opens a dark panel above the taskbar:
the live desk height on a seven-segment display with three status lights, ▲▼, the memory presets with their
heights, and a red stop.

```
                 ┌──────────── push: height, status, presets, refusals (LAN, token) ───────────┐
                 │                                                                              │
Home Assistant ──┘   desk_panel_push ──rest_command──>  http://<PC>:8765/desk/  ──>  desk-tray.ps1 ──> panel
       ^                                                                                │
       └──── desk_panel_cmd  <── webhook {"cmd": "step" | "hold_up" | "preset", "seq"} ──┤
       └──── desk_panel_stop <── webhook (stop) ────────────────────────────────────────┘
```

| Button | What the desk does |
|---|---|
| ▲ / ▼ tap (shorter than 0.6 s) | 3 mm up / down (the control box ignores smaller steps); quick taps add up into one move, so 5 × ▲ = one move of 1.5 cm |
| ▲ / ▼ hold (0.6 s or longer) | goes to the nearest memory preset above / below, as one command |
| 1-4 | goes to that preset (presets with height 0 are hidden) |
| red stop, tray menu **Cancel** | stop — see the warning below |
| keys while the panel is active: ↑ / ↓ or F13 / F14 | one tap each (a keyboard dial mapped to these keys gives one tap per notch); F15 = stop, Esc = hide |

- Home Assistant decides whether a move is safe and computes every target from its own readings. The PC never
  sends a height, so a forged push can at worst show a wrong number.
- **No messages.** A press lights the button (green; stop red). What waits stays lit until it goes out: when Home
  Assistant refuses a move for now (too soon, busy, move budget), the panel keeps it queued and sends it again,
  quietly, as soon as the guards allow — like a handset with a delay. A hold or a preset replaces queued taps,
  stop empties the queue, and an item that could not go out within 3 minutes is dropped, not done late.
- The preset the desk stands at glows green.
- Status lights under the height, one lit at a time: **green** ready · **yellow** moving or a command waits ·
  **red** locked, no data from Home Assistant, or Home Assistant does not answer.
- No Home Assistant token on the PC, no third-party agent, no MQTT. The PC only calls two webhooks and listens
  for pushes from Home Assistant's address.

## ⚠️ Safety first

- **The handset is the only reliable stop.** The control box stops on a command from Home Assistant only right
  after a move was sent; during a "go to height" or preset move it ignored stop in 3 of 3 tests. While the desk
  moves the panel says so.
- **Error E13 and the reset.** On 2026-10-21 about 16 moves in 80 s, with direction changes and commands sent
  during moves, put this control box (Jiecang JCB36NE2A) into **E13**. Waiting and unplugging the box did not
  help; only the reset did (hold ▼ on the handset). **The reset drives the desk to the very bottom and cannot
  be stopped.** Before any reset, and before testing moves, clear everything under the desk top and around its
  edges all the way down, and take heavy things off the top.
- That is why Home Assistant refuses a move when any of these holds (the panel retries the first six quietly
  and drops the rest; `locked` turns the red light on):

  | Refusal | Meaning |
  |---|---|
  | `locked` | the last command did not move the desk as expected; turn off **Desk panel locked** after a look at the desk |
  | `not_ready` | no height reading, or the board booted less than 30 s ago |
  | `busy` | the desk moves, its height changed less than 3 s ago, or the meeting reminder runs |
  | `too_soon` | less than 6 s since the last panel move |
  | `budget` | 4 panel moves in the last 2 minutes |
  | `motor` | more than 60 s of motor time in the last 10 minutes (the motors' 10 % duty cycle) |
  | `reverse` | the opposite direction less than 20 s after the last move |
  | `limit` | the step would end closer than 3 mm to the minimum or maximum height (a longer step stops 3 mm short) |
  | `no_preset` | no preset in that direction, or the preset is empty |
  | `here` | the desk is already at that preset |

  The thresholds are cautious guesses: the cause of E13 on this box is not known.
- Stop is never refused, but a burst of clicks gives at most one stop every ~2.3 s.

## Requirements

- Windows 10 or 11 with the **WebView2 Runtime** (part of Windows 11 and of current Windows 10).
- **PowerShell 7.4 or newer**, 64-bit (`pwsh.exe`; `winget install --id Microsoft.PowerShell`). The panel needs
  no WinRT, so unlike the meeting reminder it does not have to run on Windows PowerShell 5.1.
- Home Assistant with the desk from this repository and `rest_command` support.
- The PC and Home Assistant on the same LAN; the PC needs a fixed address (a DHCP reservation is fine).

## Install — Home Assistant

1. **Helpers** (`../../homeassistant/helpers/desk_panel.yaml`): create in the UI, with exactly these names:
   Toggle **Desk panel dry run**, Toggle **Desk panel locked**, Text **Desk panel moves** (max length 255),
   Date and time **Desk panel last hello**. Turn **Desk panel dry run** on.
2. **Secrets** — add to `secrets.yaml`:

   ```yaml
   desk_panel_push_url: http://192.0.2.20:8765/desk/
   desk_panel_push_token: <random text, at least 32 characters>
   ```

   Generate the token on the PC (keep it; it also goes into `config.json` there):

   ```powershell
   $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); ($b | ForEach-Object { $_.ToString('x2') }) -join ''
   ```

3. **rest_command** (`../../homeassistant/rest_command/desk_panel_push.yaml`): add it under `rest_command:` in
   `configuration.yaml`. The first `rest_command` needs a Home Assistant restart; later changes need only the
   action `rest_command.reload`.
4. **Automations** (`../../homeassistant/automations/desk_panel_cmd.yaml`, `desk_panel_stop.yaml`,
   `desk_panel_push.yaml`): add them to `automations.yaml`, each webhook with its own random ID
   (`openssl rand -hex 16`). In all files replace `biurko_xxxxxx` with your desk's entity prefix.

## Install — PC

Everything lives in `%LOCALAPPDATA%\DeskTray\`:

1. Create the folder and copy the four files there:

   ```powershell
   $dir = Join-Path $env:LOCALAPPDATA 'DeskTray'
   New-Item -ItemType Directory -Force $dir | Out-Null
   # copy desk-tray.ps1, panel.html, Install-DeskTrayDeps.ps1, Set-DeskTrayFirewall.ps1 into $dir, then:
   Get-ChildItem $dir -Filter *.ps1 | Unblock-File
   ```

2. Download the WebView2 SDK and the display font (pinned versions, hash and signature checks):

   ```powershell
   pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$dir\Install-DeskTrayDeps.ps1"
   ```

   It ends with `OK -> ...\DeskTray\lib`.

3. Allow the pushes, once, from your normal account (it asks for admin rights). Use Home Assistant's address:

   ```powershell
   pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$dir\Set-DeskTrayFirewall.ps1" -HomeAssistant 192.0.2.10
   ```

   This reserves `http://+:8765/desk/` for your account and adds the firewall rule **Desk tray push**
   (TCP 8765, only from that address, all network profiles). `-Remove` undoes both.

4. Create `config.json` in the same folder (keep it out of any repository):

   ```json
   { "panel_webhook_url":      "http://192.0.2.10:8123/api/webhook/DESK_PANEL_WEBHOOK_ID",
     "panel_stop_webhook_url": "http://192.0.2.10:8123/api/webhook/DESK_PANEL_STOP_WEBHOOK_ID",
     "push_token":             "<the same token as desk_panel_push_token>" }
   ```

5. Run it once by hand and check the log starts with `start: WebView2 Runtime ..., listener=True`:

   ```powershell
   pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "$dir\desk-tray.ps1"
   ```

   Click the icon: the height appears within a few seconds. Exit from the tray menu.

6. Start it at logon (no admin rights needed; no window, like the meeting reminder):

   ```powershell
   $pwsh = (Get-Command pwsh.exe).Source
   $action = New-ScheduledTaskAction -Execute 'conhost.exe' `
     -Argument "--headless `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$dir\desk-tray.ps1`""
   $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
   $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) `
     -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
   Register-ScheduledTask -TaskName 'desk-tray' -Action $action -Trigger $trigger -Settings $settings `
     -Description 'Desk panel in the tray (Home Assistant)' -Force
   Start-ScheduledTask -TaskName 'desk-tray'
   ```

### Stop and upgrade

`Stop-ScheduledTask` ends only the `conhost.exe` wrapper; the script keeps running. Use **Exit** in the tray
menu, or:

```powershell
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -like '*desk-tray.ps1*' } | Invoke-CimMethod -MethodName Terminate
```

To upgrade, copy the new files over the old ones and start the task again; a new copy ends the older one.

## Dry run

While **Desk panel dry run** is on (or missing), Home Assistant writes every move and stop to the logbook as
`DRY ...` and the desk does not move. All guards still run, so every refusal can be tried safely. In dry run a
command may carry `"test": {"h": 58.2}`, `{"busy": true}` or `{"boot_age": 5}` to fake a height, a busy desk or
a fresh boot; outside dry run `test` is ignored. Clear **Desk panel moves** before you turn dry run off.

## Check

- Tests (pure functions), from this folder, in `pwsh` with Pester 4.10.1 (`Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser` once):
  `Import-Module Pester -RequiredVersion 4.10.1 -Force; Invoke-Pester .\tests`
- Log: `Get-Content "$env:LOCALAPPDATA\DeskTray\desk-tray.log" -Tail 20` — start, panel open times, dropped
  commands and errors. It never holds the webhook URLs, the token or the pushed data.
- No height on the panel: is the task running, does the log show `listener=True`, is the PC's address in
  `desk_panel_push_url` current, and did Home Assistant get a hello (helper **Desk panel last hello**)?

## Known limits

- Presets changed on the handset reach Home Assistant only when the board restarts: until then the panel shows
  the old heights and "hold" goes to the old height.
- Plain HTTP on the LAN: the token and the webhook IDs are visible on the network. The webhooks are `local_only`,
  so anyone on the home network who knows an ID can send a command; the guards still apply.
- One PC only: Home Assistant pushes to one address.
