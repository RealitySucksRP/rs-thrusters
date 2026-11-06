# RS Thrusters | Full Source FiveM Resource

**Version:** 0.1.53  
**Author:** Reality Sucks Scripts  
**Price:** FREE  
**Source:** Complete, readable Lua/HTML/CSS/JavaScript source; no escrow or code obfuscation.

## Overview

RS Thrusters is an installable cold-gas-style propulsion and hover-control system for FiveM automobiles. It adds configurable directional jets, visual exhaust, flight assistance, maneuvering and aerial stunt inputs. This is an original GTA V gameplay simulation, not a representation of actual Tesla hardware.

## Included features

- **14 adjustable nozzle mounts:** four rear, four underbody, two front and four lateral jets.
- Directional propulsion for upward lift, forward boost, air braking, movement in hover, pitch/roll/yaw and flight stabilization.
- **Assisted, Sport and Manual** flight modes, plus **Car / Helicopter** hover control layouts.
- Configurable output and hover target, approach/landing assist and rear flight camera.
- White vapor FX with selectable exhaust colors, synchronized for nearby players.
- Compact flight status HUD and transparent F7 settings panel (no fullscreen dark overlay).
- Keyboard and Xbox controller inputs; vehicle-specific handling depends on model and game physics.
- Optional inventory kit and refill items, with optional target interaction, persisted by vehicle plate + model.
- Optional pressure depletion and configurable duration; **unlimited fuel is the default** (`Config.Pressure.ConsumptionEnabled = false`).
- F8 diagnostics via `/rstdiag` and configuration for nozzle placement and force tuning.

## Requirements

- FiveM server with OneSync networking and a supported GTA V automobile.
- No required framework. `ox_inventory` and `ox_target` are optional integrations.
- No packaged vehicle model, encrypted files, proprietary license checker, or external web service.

## Install

1. Extract the ZIP so the path is `resources/[rs-resources]/rs-thrusters/fxmanifest.lua` (or another resources folder).
2. Add `ensure rs-thrusters` to `server.cfg`, then restart the resource/server.
3. Optional inventory installation: copy the two definitions from `integration/ox_inventory_items.txt` into your existing `ox_inventory/data/items.lua` and restart `ox_inventory`.
4. Give a player `rs_thruster_kit`; use it near a **parked automobile while on foot**. The optional `ox_target` interaction may also be used. For a depleted tank, use `rs_thruster_refill`.
5. Enter the installed car and press **G** (keyboard) or **D-pad Down** (Xbox) to arm the system. Press **F7** to configure flight mode and controls.

**Inventory integration:** Keep the supplied item definitions at `consume = 0`. The resource checks ownership and removes items server-side **after** validating a successful operation. Do not configure automatic item consumption separately.

**Upgrading:** Back up and retain `data/installs.json` from your existing installation; it stores vehicle installations and tank levels. The distribution ZIP deliberately does not include this file. Do not overwrite an existing storage file when updating.

## Controls

| Action | Keyboard | Xbox controller |
|---|---|---|
| Arm/disarm thrusters | G | D-pad Down |
| Raise / lift | Space (hold) | A (hold) |
| Hover on/off | H | X |
| Hover forward / reverse | W / S | RT / LT or left stick forward/back |
| Helicopter layout: strafe | A / D | Left stick left/right |
| Helicopter layout: yaw | Left / Right arrows | Right stick left/right |
| Boost outside hover | Shift (hold) | R3 (hold) |
| Air brake | Z (hold) | Context-dependent; see F7 |
| Assisted front flip / right roll | J / K | Hold LB and flick left stick |
| Manual stunt direction | Left Alt + arrows | Hold LB and flick left stick |
| Flight options | F7 or `/rstmenu` | F7 from keyboard |
| Diagnostics | `/rstdiag` | N/A |

When hovering in Helicopter mode, **Space/A climbs** and **Ctrl/B descends**. Releasing the lift/descent input aims to hold the current altitude. Optional right-stick pitch is toggled from F7. In Car mode the side steering behaves differently; review the built-in controls before flight. Other resources (seatbelt, handbrake, etc.) may use overlapping bindings; adjust keyboard bindings through FiveM settings and test controller bindings on your server.

## Configuration

- `config.lua` controls nozzle locations, force strengths, flight assistance, hover limits, camera behavior, FX and pressure use.
- Change `Config.Pressure.ConsumptionEnabled = true` to enable gas depletion. You can also disable players choosing the tank duration with `AllowPlayerDuration = false`.
- `Config.Nozzles` defines normalized mount positions; different vehicles can need different tuning.
- `Config.Debug` enables additional console debugging. `/rstdiag` prints vehicle and flight state to F8.

### Optional ACE-restricted installation testing

Development commands are **off by default**. Server operators who need them can temporarily add:

```cfg
set rs_thrusters_dev_mode 1
add_ace group.admin rs_thrusters.test allow
```

Grant the test account the corresponding `group.admin` principal. As the **driver**, use `/rstinstall` or `/rstrefill`. Remove the dev setting when finished; never grant testing privileges to `builtin.everyone`.

## Technical limitations / customer information

- Real vehicle mass, tuning, slope, collisions, network ownership, and steering bindings affect results. Test a vehicle in open space before use on a public server.
- Automatic stabilization and stunt flips are simulated with GTA physics; behavior is not guaranteed identical on every model or server configuration.
- Persistent records use **model + normalized plate**. Servers with duplicate plates should integrate an authoritative garage vehicle ID/VIN before relying on them for unique ownership.
- Particle FX and simulated nozzle RPM are gameplay visuals, not measurements of a real cold-gas system.
- No custom vehicle model, sound library, custom 3D tank, or installation minigame is included.
- Server validates upgrade and FX state, but this is not a complete anti-cheat solution against malicious clients.
- Full Lua and web UI source is provided for inspection and customization. See `LICENSE` for permitted use and redistribution terms.

## Files

```text
rs-thrusters/
  fxmanifest.lua
  config.lua
  client/main.lua
  server/main.lua
  html/index.html
  html/style.css
  html/app.js
  integration/ox_inventory_items.txt
  data/                    # game creates installs.json here
  README.md
  LICENSE
```
