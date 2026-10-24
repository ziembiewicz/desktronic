# desktronic — a standing desk in Home Assistant via ESPHome

Control a **Desktronic HomePro** electric standing desk from Home Assistant with a small ESP32 board plugged into
the free RJ12 port of its control box. No cloud, no app, no soldering on the desk itself — and the desk's own
safety logic (collision detection, limits) stays in charge, because the board sends the same commands as the
handset.

What you get in Home Assistant: current height, a height slider ("go to 110 cm" — not yet tested on this desk), memory presets M1–M4
(buttons and their stored heights), nudge up/down, stop, desk status (idle / raising / lowering), idle time,
plus Wi-Fi signal and the reason of the last reboot for diagnostics. Optionally, the desk raises itself for
your meetings — see [Meeting reminder](#meeting-reminder-optional) — and a desk panel sits in the Windows tray —
see [Desk panel](#desk-panel-in-the-windows-tray-optional).

## Hardware

| Part | Notes |
|---|---|
| Desk | Desktronic HomePro, control box **Jiecang JCB36NE2A-230**, handset JCHT35M41C |
| Board | **Seeed XIAO ESP32-C6** (an ESP32 DevKit V1 also works — see `docs/wiring.md`) |
| Cable | RJ12 6P6C or RJ11 6P4C plug into the box's port **F**; 4 wires used |

Many Jiecang-based desks (Desky, Uplift, Fully Jarvis, …) use the same protocol — see the DeskUp compatibility
list before you buy anything.

## How it works

The desk logic is **not** in this repository. It comes from
[DeskUp Pro](https://github.com/SmartHomeGuys/DeskUp-Pro-Controller-RJ12), pulled by ESPHome at build time
as a remote package and **pinned to a commit**, so an upstream change can't silently alter what runs under the
desk. `esphome/desktronic.yaml` contains only overrides on top of it:

- **Hardening.** Removed the "retail" extras: fallback hotspot, captive portal, Improv (serial and BLE), web
  server, OTA over HTTP. API and OTA are encrypted with one key.
- **Full Wi-Fi power.** The upstream XIAO config lowers TX power to 9.5 dB; under the desk that meant
  −79…−93 dBm and constant disconnects. 20 dB fixed it.
- **Diagnostics.** Wi-Fi signal and reset-reason sensors — when the board reboots you see whether it was a
  brownout, a watchdog or a software restart.
- **Empty memory presets after reboot.** The controller reports M1–M4 only when asked, and the upstream config
  asks once at boot without waking the controller first. A sleeping controller ignores it, so M1–M4 stayed
  "unknown". The override wakes the controller and asks again (and once more if needed).
- **"Offline" in Device Builder.** Upstream appends the MAC suffix to the hostname; Builder looks for
  `desktronic.local` and never finds it. `use_address` points it at the real name.

## Setup

1. Wire the board — **read [`docs/wiring.md`](docs/wiring.md) and measure first**. In this build the actual
   pinout turned out to be the mirror image of the documented convention.
2. In ESPHome Device Builder create the device from `esphome/desktronic.yaml` and add the keys from
   `esphome/secrets.yaml.example` to Secrets. Generate the API key yourself (`openssl rand -base64 32`).
3. First flash over USB **with the desk disconnected**. Find the hostname the board announces
   (`desktronic-xxxxxx`) in the logs or your DHCP leases and put it into `desktronic_address`.
4. Plug the board into port F (USB disconnected), adopt it in Home Assistant, and from now on update over OTA.
5. In the device settings enable **Send Wake Up Cmd** — the controller falls asleep after a few seconds idle
   and otherwise drops the first command.

## Things worth knowing

- For about 5 seconds after the board boots, the height shows the configured minimum (58 cm) — a placeholder,
  not a reading. Automations that react to height changes should ignore that window.
- The motors have a duty cycle of 10 % (2 min on, 18 min off). Don't build automations that move the desk in
  a loop.
- Keep the control box screwed to the frame; its gyroscope-based collision detection misfires when it hangs loose.
- The data lines are 5 V logic wired directly to the ESP32 here — outside spec; use a level shifter for a
  permanent build.

## Meeting reminder (optional)

Stand up for your meetings without thinking about it. 30 s before a meeting the desk gives a short nudge (it
goes 3 mm up and back down, which you feel rather than see); 15 s before the start it nudges twice, pauses for 3 s and rises to memory preset **M3**
(set M3 to your standing height first). The start time comes from the reminder that Outlook on the web shows
as a Windows notification. Calendar blockers stay put: a reminder whose title contains a blocker word
(default `Blocker`, configurable) does not move the desk.

- `windows/` — `meeting-reminder.ps1` reads the reminder on the PC and posts `warn` / `go` to a Home Assistant
  webhook at the right moments. Requirements, install and limits: [`windows/README.md`](windows/README.md).
- `homeassistant/` — what Home Assistant needs:
  1. Helper `input_boolean.desk_meeting_auto` (`helpers/desk_meeting_auto.yaml`) — the master switch. Create it
     in the UI as a Toggle named **Desk meeting auto** (the UI builds the entity ID from the name) and turn it on.
  2. Script `desk_nudge` (`scripts/desk_nudge.yaml`) — add it to `scripts.yaml`.
  3. Automation `desk_meeting_reminder` (`automations/desk_meeting_reminder.yaml`) — add it to
     `automations.yaml` with a random webhook ID (for example `openssl rand -hex 16`).
  4. With the desk panel only: helpers **Desk meeting window at** and **Desk meeting cancelled at**
     (`helpers/desk_meeting.yaml`, Date and time) — create them before the automation; they let the panel cancel
     the raise (below).

  In all these files replace `biurko_xxxxxx` with your desk's entity prefix.

**Cancel a raise** from the [desk panel](#desk-panel-in-the-windows-tray-optional): the red stop or **Cancel** in
the tray menu, or a height or preset you send from the panel, between the first nudge and the moment the desk
starts for M3. Before go the desk then stays where it is (no go nudges, no M3); during the go nudges M3 is not
pressed. Once the desk drives to M3, only the handset stops it. The handset does not cancel the raise: lowered
by hand and standing still at go, the desk still rises to M3 (moved to M3 or higher, or still moving, it does
not). The logbook says `meeting raise cancelled` or `meeting raise stopped before M3`; the panel shows nothing
extra.

The desk only ever moves **up**: nothing happens when it is already at M3 or higher, while it is moving, when
the switch is off, or right after the board boots (placeholder height). If the PC sleeps or the script stops,
nothing is sent and the desk stays where it is. The desk moves on its own here, so keep the space above and
around it clear and the control box screwed to the frame (collision detection).

## Desk panel in the Windows tray (optional)

A tray icon on the PC opens a small dark panel: the live height on a seven-segment display, the memory presets,
a stop and a field to type a height to go to. Home Assistant pushes the height to the PC and
guards every move: on this control box a burst of moves led to error **E13**, whose reset drives the desk to the
bottom without a way to stop it. The handset stays the only reliable stop.

- `windows/desk-tray/` — the panel, its installers and tests: [`windows/desk-tray/README.md`](windows/desk-tray/README.md).
- `windows/launcher/` — the starter and updater: both PC apps run from main; every merge that changes
  `windows/` is offered as an update in the panel: [`windows/launcher/README.md`](windows/launcher/README.md).
- `homeassistant/` — helpers `helpers/desk_panel.yaml`, `rest_command/desk_panel_push.yaml` and the automations
  `desk_panel_cmd`, `desk_panel_stop`, `desk_panel_push`; with the meeting reminder also `desk_panel_meeting`,
  which shows the panel (without taking the focus) while the reminder raises the desk.

## Licenses

- Files in this repository: **MIT** (see `LICENSE`).
- **DeskUp Pro** has its own license: personal, non-commercial use only, no redistribution. This repository
  does not redistribute any DeskUp code — it only references it. Check the license before using it.
- The manufacturer's manual is not included; get it from Desktronic.
- The panel downloads the **WebView2 SDK** (Microsoft, BSD-3-Clause) and the **DSEG7** font (keshikan, SIL OFL 1.1)
  at install time; neither is stored in this repository.
