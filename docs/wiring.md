# Wiring: control box port "F" → Seeed XIAO ESP32-C6

The Jiecang JCB36NE2A-230 control box has a free 6-position RJ12 jack labelled **F**. Only the four middle
positions (2–5) carry signals; positions 1 and 6 are empty. That is why both an **RJ12 6P6C** and an
**RJ11 6P4C** plug fit. An **RJ11 6P2C** plug (the common two-wire phone cable) does **not** work.

## Orientation

Plug held with the latch facing up, positions counted from the left: 1 … 6 (the convention used by DeskUp).
The numbers are **positions in the housing**, not wire numbers — in a 6P4C plug position 1 is empty.

## Pinout

| Position | RJ12 6P6C | RJ11 6P4C | Signal | XIAO ESP32-C6 | ESP32 DevKit V1 (alternative) |
|---|---|---|---|---|---|
| 1 | wire 1 | — (empty) | unused | — | — |
| 2 | wire 2 | wire 1 | ground | **GND** | GND |
| 3 | wire 3 | wire 2 | data from controller | **D0** = GPIO0 (RX) | RX2 = GPIO16 |
| 4 | wire 4 | wire 3 | 5 V from the desk | **5V** | VIN |
| 5 | wire 5 | wire 4 | data to controller | **D1** = GPIO1 (TX) | TX2 = GPIO17 |
| 6 | wire 6 | — (empty) | unused | — | — |

XIAO ESP32-C6, component side up, USB-C at the top: left edge **D0**, **D1**, D2 … D6; right edge **5V**,
**GND**, 3V3, D10 … D7 (check against the silkscreen). Never feed 5 V into 3V3 — it destroys the module.

## Measure before you solder — the convention was mirrored

The cable here is a home-made one: a 6P4C plug crimped onto a UTP cable, using only the four solid-colour
wires (green, blue, orange, brown; the white pair wires left unconnected). Looking at the plug, the wires
from left to right were brown, blue, orange, green.

Following the DeskUp convention ("latch up, position 1 on the left") the expectation was **variant A**:
brown = GND, orange = 5 V. The multimeter said otherwise:

| Probe | Result |
|---|---|
| black on green, red on blue | **4.94 V** → **variant B** (mirror image of the convention) |
| black on green, red on orange | ~5 V (data from controller, idle high) |
| black on green, red on brown | ~5 V (data to controller, idle high; dips slightly while the handset is used) |

Final mapping for this cable: **green = GND, blue = 5 V, orange = RX (D0), brown = TX (D1)**.

Lessons:
- Wire colours differ between cables and conventions can be mirrored — **solder by measured position, not by
  colour or by a diagram**.
- Both data lines idle at **~5 V**. The ESP32 inputs are specified for 3.3 V, so the direct connection used
  here is outside spec. It works on the test board; a **BSS138 bidirectional level shifter** is the proper fix.

### Measurement procedure

ESP32 **disconnected**. Cable plugged into port F, the free end stripped, desk powered. Multimeter on DC volts,
black probe on the wire you believe is ground (position 2).

| Measure | Expected | Otherwise |
|---|---|---|
| position 4 | about 5 V | stop — orientation mirrored or plug shifted by one position |
| position 3 | note the value | ~5 V → 5 V logic, plan a level shifter or a divider |
| position 5 | note the value | — |

Keep the stripped ends apart — shorting 5 V to ground goes straight into the control box supply.

## Mounting the control box

Keep the control box **screwed to the frame**, also while testing. Its collision detection uses a gyroscope:
a box hanging loose on its cables swings when the motors start, and the desk bounces back as if it hit an
obstacle, in both directions.

## Power

Never connect the board to a computer's USB and to the desk at the same time — the desk's 5 V and the USB
5 V would meet. First flash: USB with the desk **disconnected**. After that: OTA only.
