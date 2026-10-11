# desktronic — a standing desk in Home Assistant via ESPHome

Control a **Desktronic HomePro** electric standing desk from Home Assistant with a small ESP32 board plugged into
the free RJ12 port of its control box. No cloud, no app, no soldering on the desk itself — and the desk's own
safety logic (collision detection, limits) stays in charge, because the board sends the same commands as the
handset.

What you get in Home Assistant: current height, a height slider ("go to 110 cm" — not yet tested on this desk), memory presets M1–M4
(buttons and their stored heights), nudge up/down, stop, desk status (idle / raising / lowering), idle time,
plus Wi-Fi signal and the reason of the last reboot for diagnostics. Optionally, the desk raises itself for
your meetings — see [Meeting reminder](#meeting-reminder-optional).

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
goes 3 mm up and back down, which you feel rather than see); at the start it nudges twice, pauses for 3 s and rises to memory preset **M2**
(set M2 to your standing height first). The start time comes from the reminder that Outlook on the web shows
as a Windows notification.

- `windows/` — `meeting-reminder.ps1` reads the reminder on the PC and posts `warn` / `go` to a Home Assistant
  webhook at the right moments. Requirements, install and limits: [`windows/README.md`](windows/README.md).
- `homeassistant/` — what Home Assistant needs:
  1. Helper `input_boolean.desk_meeting_auto` (`helpers/desk_meeting_auto.yaml`) — the master switch. Create it
     in the UI and turn it on.
  2. Script `desk_nudge` (`scripts/desk_nudge.yaml`) — add it to `scripts.yaml`.
  3. Automation `desk_meeting_reminder` (`automations/desk_meeting_reminder.yaml`) — add it to
     `automations.yaml` with a random webhook ID (for example `openssl rand -hex 16`).

  In all three files replace `biurko_xxxxxx` with your desk's entity prefix.

The desk only ever moves **up**: nothing happens when it is already at M2 or higher, while it is moving, when
the switch is off, or right after the board boots (placeholder height). If the PC sleeps or the script stops,
nothing is sent and the desk stays where it is. The desk moves on its own here, so keep the space above and
around it clear and the control box screwed to the frame (collision detection).

## Licenses

- Files in this repository: **MIT** (see `LICENSE`).
- **DeskUp Pro** has its own license: personal, non-commercial use only, no redistribution. This repository
  does not redistribute any DeskUp code — it only references it. Check the license before using it.
- The manufacturer's manual is not included; get it from Desktronic.
