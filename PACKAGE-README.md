# RS Thrusters v0.1.72

Installable directional thrusters for FiveM automobiles, with assisted hover, native angular-velocity stabilization, full 360-degree stunts, and synchronized vapor effects.

## Installation and update path

[GitHub source](https://github.com/RealitySucksRP/rs-thrusters)

Place the resource here, with `fxmanifest.lua` directly inside `rs-thrusters`:

```text
server-data/
  resources/
    [rs-resources]/
      rs-thrusters/
        fxmanifest.lua
        config.lua
        client/
        server/
        html/
        data/
```

When downloading the GitHub source ZIP, rename the extracted `rs-thrusters-main` folder to **`rs-thrusters`**. Keep this name for the inventory exports.

Add to `server.cfg` after optional inventory/target dependencies:

```cfg
ensure rs-thrusters
```

OneSync is required for server-side entity validation and replicated state. `ox_inventory` and `ox_target` are optional integrations. The resource stores installs and tank levels in `data/installs.json`, keyed by normalized model and plate.

For updates, back up the resource and preserve your `data/installs.json` and custom configuration. Merge the new configuration keys. Land and park before `restart rs-thrusters`; restarting while airborne interrupts lift. The public source excludes live vehicle records.

## What changed

- Native angular-velocity control drives assisted roll/flip rotation and assisted hover attitude, while thrust handles lift and translation.
- Geometric chassis tracking follows a full revolution through the inverted position, with acceleration and braking profiles approaching 360 degrees.
- Native barrel rolls start from one stunt input on any eligible vehicle model. The native controls rotation, braking, and final leveling without the manual direction probes.
- Peak stunt speed is now 2.50 rad/s for front/back flips and 1.75 rad/s for left/right rolls, 25% above v0.1.67. Braking ramps were adjusted with the speed increase.
- Controller stunts use **RB**, with the left stick choosing the direction. R3 holds forward boost.
- Native GTA camera is the default. The rear flight camera is optional in F7 or `/rstcam`.
- The optional jet-torque roll mode retains saved per-model calibration, including the live-verified Yosemite Rancher signs.
- Exhaust uses a narrow core and wider downstream vapor layers. F7 offers stock white, solid color, or speed-based colors, with a separate max-thrust color.

See [CHANGELOG.md](CHANGELOG.md) for recent changes and validation status.

## Controls

Set `Config.Keybinds.RollRight` and `Config.Keybinds.RollLeft` in `config.lua` to change the default roll keys. Use uppercase letters such as `K` and `L`. Players can rebind **RS Thrusters - Assisted right barrel roll** and **RS Thrusters - Assisted left barrel roll** under GTA Settings > Key Bindings > FiveM. Saved player bindings take precedence over the defaults.

| Action | Keyboard | Xbox |
| --- | --- | --- |
| Thrusters on/off | G | D-pad Down |
| Lift / climb | Space | A |
| Forward boost | Hold Shift | Hold R3 |
| Hover on/off | H | X |
| Hover forward / backward | W / S | RT / LT |
| Hover sideways in Helicopter mode | A / D | Left stick left / right |
| Turn in Helicopter mode | Left / Right arrows | Right stick left / right |
| Descend in Helicopter mode | Left Ctrl | B |
| Air brake | Z | LB + B in Helicopter mode |
| Full front/back flip | Alt + Up / Down | Hold RB, center left stick, then flick Up / Down |
| Full left/right roll | Alt + Left / Right | Hold RB, center left stick, then flick Left / Right |
| Front flip / right roll / left roll | J / K / L | RB + X also requests right roll |
| Cancel stunt and stabilize | Backspace | LB + D-pad Up |
| Settings | F7 | Use keyboard/menu |

Helicopter hover holds altitude when climb/descent input is released. In Car hover style, left-stick steering turns the nose instead of sliding. Xbox right-stick vertical pitch is **off by default**; F7 can enable it. Mouse look remains available during hover.

Assisted full stunts need open air, adequate clearance, and network ownership of the vehicle. The controller steadies or climbs before starting if needed. Use a stunt key or RB and the left stick to start directly.

## Commands and diagnostics

| Command | Purpose |
| --- | --- |
| `/rstmenu` | Open flight settings |
| `/rststyle` | Switch hover control style |
| `/rstcam` | Toggle the optional rear flight camera |
| `/rstflip` / `/rstbackflip` | Full front / back flip |
| `/rstroll` / `/rstrollleft` | Full right / left barrel roll |
| `/rstrecover` | Cancel a stunt and request stabilization |
| `/rstdiag` | Print version, vehicle, named nozzles, forces, pilot inputs, recovery state, and key/controller counters to F8 |
| `/rstnativecheck` | No-op angular-velocity native binding check |
| `/rstrollprobe` / `/rstrollprobeleft` | Optional short right / left probes for jet-torque calibration |

Native rolls are enabled by default with `Config.Physics.StuntRollGovernorEnabled`. If an administrator disables that option, the jet-torque roll controller requires calibration. Run both probes from a level, steady hover in open air at least 20 m up. The client saves matching signs per model across thruster toggles and restarts.

## Inventory and developer installation

For `ox_inventory`, merge the entries from [integration/ox_inventory_items.txt](integration/ox_inventory_items.txt) into the existing items table. The kit and refill exports are `rs-thrusters.installKit` and `rs-thrusters.refillKit`. The server validates installation/refill requests and removes an item after a successful action. `ox_target` adds vehicle installation and refill options when available.

For standalone development testing, explicitly enable the gated commands:

```cfg
set rs_thrusters_dev_mode 1
add_ace group.admin rs_thrusters.test allow
```

Then use `/rstinstall` or `/rstrefill` as the driver. These commands are disabled unless developer mode and the ACE permission are enabled.

## Configuration

- `Config.Debug = false` keeps routine flight and stunt logs quiet. Use `/rstdiag` for an on-demand snapshot.

- `Config.Pressure.ConsumptionEnabled = false` keeps effective gas pressure full for testing. Set it to `true` for tank consumption.
- `DefaultDurationSeconds = 180`, `MinDurationSeconds = 60`, and `MaxDurationSeconds = 600` control tank duration. `AllowPlayerDuration` allows the F7 slider within those limits. The baseline is four lift jets at full output. Actual duration depends on active jets and output.
- `Config.Physics.StuntPitchMaxRate`, `StuntPitchAcceleration`, and `StuntPitchDeceleration` tune front/back flip speed and braking.
- `StuntRollMaxRate`, `StuntRollGovernorMaxRoll`, and `StuntRollGovernorDeceleration` tune barrel roll speed and braking together.
- `AssistedHoverMoveSpeed = 14.0` m/s sets the assisted hover movement target. Boost has separate tuning.
- `Config.FlightCamera.EnabledByDefault = false` leaves GTA's native camera active. A saved player camera preference may override this default.
- `Config.Fx` controls particle layers, colors, and visual placement. `Config.Nozzles` provides normalized model-relative nozzle geometry; vehicle shape and particle orientation still need visual checks on new models.

The RPM display represents simulated nozzle activity. Gas pressure shows a percentage of tank capacity.

## Validation status

Live v0.1.67 feedback and logs confirmed all four stunts, including maneuvers while moving. One right-roll attempt reached 359 degrees and then overshot during settling. v0.1.68 kept the native active during that handoff.

v0.1.69 passed Lua syntax checks and 24 simulated native rolls from the stunt request through leveling without reading calibration. The simulation also checked the low-altitude queue, the optional jet-torque gate, and the return to hover when the native is unavailable. The new speed and direct-roll behavior await live FiveM validation.
