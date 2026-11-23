# RS Thrusters v0.1.83 — Gas Mode Configuration

Configure once in **`config.lua`**. The gas economy is server-authoritative and does not change the existing hover, stunts, lift or Xbox bindings. Retail setup and buyback from v0.1.82 remain as before.

```lua
Config.Gas = {
    Mode = 'unlimited', -- 'unlimited', 'refill', or 'mixed'
    RefillMinutes = 60, -- minimum 60 minutes of jet-on time per FULL refill
    UnlimitedAce = 'rs_thrusters.unlimited',
    EmergencyLandingReserve = true,
    EmergencyReserveSeconds = 60, -- one additional minute to descend safely
}
```

## Choose a mode

- **unlimited (default)**: all drivers fly indefinitely. It does not consume the vehicle's saved gas. Refills are unnecessary.
- **refill**: all drivers use stored gas. A full tank provides at least 60 minutes of active propulsion; no gas is used while jets are off. An extra 60 seconds of jet-on reserve becomes available when the normal tank reaches zero.
- **mixed**: the *current driver* with `rs_thrusters.unlimited` ACE flies without gas drain; other drivers consume the vehicle's stored tank and can purchase `rs_thruster_refill` from your existing mechanic / black-market shops. An ACE player entering a near-empty vehicle does not recharge it, and their unlimited access never transfers to the next driver.

To make refills last **90 or 120 minutes**, set `RefillMinutes = 90` or `120` and restart the resource. The server enforces a minimum of 60 minutes even if the config value is lower. Changing the length affects future active drain, not the saved percentage of existing tanks. Nozzle count, boost intensity and barrel rolls do *not* reduce tank lifetime below the configured time. Tank time does not drain while an installed kit is not firing.

## Give a specific player unlimited gas under mixed mode

Add this to `server.cfg`, then restart your server (replace the placeholder license):

```cfg
add_ace group.thruster_vip rs_thrusters.unlimited allow
add_principal identifier.license:REPLACE_WITH_PLAYER_LICENSE group.thruster_vip
```

Grant an existing staff group the same perk (optional):

```cfg
add_ace group.admin rs_thrusters.unlimited allow
```

ACE is checked by `server/main.lua` against the *real driver* each time a control packet is accepted. A player without ACE cannot claim it in client UI or transfer it by giving someone their vehicle. Under the `refill` mode, VIP ACE is ignored and everyone uses refills. Under `unlimited`, ACE is not necessary.

## Refill and installation items

- `rs_thruster_kit`: install onto an eligible parked automobile; regular item Use does not require ACE.
- `rs_thruster_refill`: refill a fitted vehicle's tank to 100% and reset the separate landing reserve. Each successful refill consumes one cartridge. If the tank is already full, no item is consumed.
- Your existing mechanic or black-market shops must actually stock these products; adding the resource ZIP alone cannot modify live third-party shop catalogs. See `integration/STORE_SETUP.md`.

**Restricted admin test commands remain separate:**

```cfg
set rs_thrusters_dev_mode 1
add_ace group.admin rs_thrusters.test allow
```

Authorized staff may use `/rstinstall` or `/rstrefill`. Ordinary customers should buy and use inventory items. Do not grant the test ACE to everyone.

## Debug and expected behavior

In an upgraded vehicle, run **`/rstgas`** to display the server-confirmed gas mode, your access, saved tank level, remaining emergency reserve, and full-tank duration. You can use `/rstdiag` for existing flight diagnostics.

1. Start with default `unlimited` and verify installed vehicles fly normally, including any with old saved pressure=0.
2. Switch to `refill` and verify the tank only drains when jets fire. At 60 minutes of total active jet time, normal gas is empty; the extra landing reserve becomes available.
3. Switch to `mixed` and test with a VIP and normal player using the *same* upgraded car. VIP must not drain gas; normal driver must resume using stored tank.
4. Try a refill with a partially empty tank, verify one cartridge is consumed, then restart and verify pressure and reserve persist.
5. Confirm flight behavior (pitch, yaw, hovering and controls) remains unchanged. The gas limiter never reduces thruster power as the tank empties.

**Back up `data/installs.json` before upgrading**. The ZIP deliberately includes an empty starter database for privacy. Your live file stores installed cars and the gas status; do not replace it with the starter file during an update. Existing records without a reserve field remain compatible.

**Note:** The landing reserve provides additional propulsion time and an on-screen warning, not an automatic landing. Players should descend before it runs out. All gameplay claims require a live GTA V Legacy/Enhanced test on your server.
