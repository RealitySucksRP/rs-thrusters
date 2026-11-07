# RS Thrusters changelog

## 0.1.69 - 2026-11-07

- Start native barrel rolls directly from the existing keyboard and Xbox stunt inputs, including on models with no saved calibration.
- Keep the native in charge through rotation, braking, and leveling. If the native fails, cancel the roll and return to hover recovery.
- Keep the probes and saved signs available for the optional jet-torque controller.

## 0.1.68 - 2026-11-06

- Increase front/back flip peak angular speed from 2.00 to 2.50 rad/s, with acceleration 3.00 rad/s squared and planned deceleration 2.20 rad/s squared.
- Increase left/right roll peak speed from 1.40 to 1.75 rad/s and roll governor deceleration from 1.80 to 2.40 rad/s squared.
- Retain native angular-velocity control during the final roll leveling phase. Suppress physical attitude torque there to avoid the observed extra spin after the rotation target.
- Refresh installation path, control reference, configuration guidance, and current validation status for the GitHub source.
- Validation: four Lua files parse; 18 pitch simulations, 18 roll-profile simulations, and 12 disturbed leveling cases pass. These new settings await live validation.

## 0.1.67 - 2026-11-06

- Keep native attitude control active throughout assisted hover, including pre-stunt steadying, rather than handing ordinary hover back to the physical torque controller.
- Raise front/back flip speed to 2.00 rad/s and roll speed to 1.40 rad/s.
- Live feedback confirmed all four stunts, including while moving. One right-roll attempt overshot during final settling; addressed in 0.1.68.

## 0.1.65-0.1.66 - 2026-11-06

- Use native angular-velocity control for full front/back flips, with continuous geometric nose tracking, bounded spin, braking, and leveling.
- Move the controller stunt modifier from LB to RB. RB plus left-stick direction selects front/back flips or left/right rolls.
- Raise native pitch-stunt speed progressively after live tests.

## 0.1.64 - 2026-11-06

- Persist verified roll signs per model across thruster toggles and resource restarts; include the live-verified Yosemite Rancher signs.
- Add a wider downstream exhaust layer while retaining the narrow jet core.
- Increase assisted hover forward movement to 14 m/s.
- Default to the native GTA camera, with rear flight camera remaining optional.

## 0.1.61-0.1.63 - 2026-11-06

- Introduce native angular-velocity-driven rolls, continuous chassis rotation tracking, spin limits, and controlled braking.
- Verify left/right direction probes and full barrel rolls in FiveM Enhanced.
- Keep lift and translation separate from assisted angular control.

The earlier GitHub source snapshot was 0.1.53. Historical release downloads remain separate from the current main-branch source.
