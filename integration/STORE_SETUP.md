# RS Thrusters v0.1.83 — shop purchase, inventory use, optional resale and gas policy

## What is supported

| Inventory / framework | Shops sell items to players | Player uses kit/refill | Player sells unused items back |
|---|---|---|---|
| QBCore + qb-inventory | Via qb-shops or any compatible shop | Registered QBCore usable item | Optional in-resource buyback at configured shops |
| Qbox + ox_inventory | Via RS Zombiemart, ox_inventory shops or any compatible shop | ox_inventory item client exports | Optional in-resource buyback at configured shops |
| ESX Legacy + ESX inventory | Via esx_shops or compatible shop | ESX.RegisterUsableItem | Optional in-resource buyback at configured shops |
| ESX/QBCore + ox_inventory | Via compatible ox-based shops | ox_inventory item client exports | Optional in-resource buyback at configured shops |
| Standalone + ox_inventory | Via ox_inventory shops | ox_inventory item client exports | Optional with a registered `money` item |

**Important distinction:** A resource ZIP alone cannot add stock to an unrelated shop that is on your live server. Items and icons must be installed in that server's inventory, and the products must be inserted into the shop's **real active config**. Examples below are snippets, not automatically installed stock. No custom physical shop/coordinates are invented in this package.

Item names:
- `rs_thruster_kit` — RS Thruster Kit — suggested retail **$25,000**.
- `rs_thruster_refill` — Thruster Gas Cartridge — suggested retail **$2,500**.

Any player may purchase and use a kit (no ACE) if allowed to access the configured store. The player must leave the vehicle and use the inventory item next to a parked, networked automobile. The server checks ownership and consumes **one** item only after passing validation. Vehicles are saved by model and plate. Installations that already exist do not consume items.

## 1. QBCore + qb-inventory + qb-shops

1. Merge `integration/qbcore_items.txt` **inside** the item table in `qb-core/shared/items.lua` (do not replace the table).
2. Copy the two PNGs in `integration/images/` into your installed `qb-inventory/html/images/` directory (forks may differ).
3. Edit the shop that players actually use, normally in `qb-shops/config.lua`. Add the TWO rows from `integration/qb_shops_products.txt` into `Config.Products['hardware']` if a mechanic/hardware shop uses that list, or into your existing mechanic/blackmarket product list. Verify its `Config.Locations` entry actually references that list. A product array with no shop location never appears in game.
4. Start `qb-core` and `qb-inventory` before `rs-thrusters`; start `qb-shops` as appropriate. Restart server after editing `qb-core/shared/items.lua`.
5. Buy one kit, confirm the icon and item count, exit a parked car, select **Use**, confirm one item is deducted and installation persists after a resource restart.

QBCore usable-item registration is automatic when `qb-core` is running **without** `ox_inventory`. No extra usable-item event is needed.

## 2. Qbox or any framework using ox_inventory

1. Merge both entries from `integration/ox_inventory_items.txt` into the table returned by `ox_inventory/data/items.lua`. **For Qbox, do not edit `qbx_core/shared/items.lua`.**
2. Copy the two PNGs into `ox_inventory/web/images/` (match your installation).
3. For the built-in shop system, append the two entries from `integration/ox_shops_products.txt` to the `inventory` array of an **existing** mechanic or black-market shop in `ox_inventory/data/shops.lua`. Confirm the shop actually has locations or targets. A shop may instead be registered by another resource; then edit that resource's product catalog instead of creating duplicate shops.
4. Restart the server after changing item/shop files. The items use `client.export='rs-thrusters.installKit'` and `client.export='rs-thrusters.refillKit'`, both defined in the resource. `consume=0` is deliberate: the resource deducts one item after successful server validation, not just upon opening the inventory action.

### Reality Sucks RP: RS Zombiemart and RS Blackmarket

According to the supplied development log, the live Qbox server uses **RS Zombiemart** for its public Car Parts shop. In that configuration, keep `ox_inventory/data/shops.lua` managed as you already do. Put the items in the **actual** `rs-zombiemart/config.lua` catalog under `Config.Items.shop8.Item` (Car-Parts), using the field shape already in that file. Do not paste a qb-shops or ox_inventory shop row into a custom shop with different fields.

For **RS Blackmarket**, add both items to the existing catalog in `rs-blackmarket/shared/config.lua`, again matching that resource's actual field names. A prior development log indicated that `rs-blackmarket` was commented out in `server.cfg`. Confirm it is enabled if you want that storefront to appear. **This download cannot verify or overwrite your local `rs-zombiemart`, `rs-blackmarket`, or `ox_inventory` files.**

## 3. ESX Legacy (default ESX inventory)

1. Back up the database. Import `integration/esx_items.sql` if compatible with your ESX schema; adjust columns if your fork differs.
2. Use `integration/esx_shops_products.txt` in the actual `Items = {...}` list of your `esx_shops/shared/config/shops.lua` shop zone (`Config.Zones.Mechanic` or your black market zone). Older forks use `esx_shops/config.lua` instead. Ensure the zone has a `Pos` list with actual locations. The item's category must exist in `Categories` if the UI requires grouping.
3. Install the icons into the image path used by your ESX inventory/shop UI (this varies by fork).
4. Start `es_extended` before `rs-thrusters` and test inventory **Use**. `ESX.RegisterUsableItem` is registered automatically when default ESX inventory is in use.

If ESX uses **ox_inventory**, use the instructions in section 2 instead, including ox_inventory item exports, and do not install duplicate ESX usable items.

## 4. Optional: players SELL UNUSED KITS TO SHOPS (buyback)

Retail stock in sections 1–3 lets a **shop sell to players**. To let a player **sell an unused inventory kit to a mechanic shop or black market**, v0.1.82 includes a separate, optional *server-authoritative buyback* service.

The service is **OFF by default**, because only the server owner knows the shop coordinates and economy. Edit `config.lua`:

```lua
Config.Buyback = {
    Enabled = true,
    MaxDistance = 3.0,
    CooldownMs = 1800,
    Prices = {
        mechanic    = { rs_thruster_kit = 12500, rs_thruster_refill = 1250 },
        blackmarket = { rs_thruster_kit = 10000, rs_thruster_refill = 1000 },
    },
    Locations = {
        { type = 'mechanic',    coords = vector3(YOUR_MECHANIC_X, YOUR_MECHANIC_Y, YOUR_MECHANIC_Z),    currency = 'cash' },
        { type = 'blackmarket', coords = vector3(YOUR_BLACKMARKET_X, YOUR_BLACKMARKET_Y, YOUR_BLACKMARKET_Z), currency = 'cash' },
    },
}
```

**Replace every placeholder with coordinates from your actual running shop config before restarting.** Do not paste placeholders into production `config.lua` unchanged. All sales are one item per command. Players stand within 3 meters of an allowed location and run:

- `/rstsellkit` — sell one *unused* `rs_thruster_kit` from inventory.
- `/rstsellrefill` — sell one *unused* `rs_thruster_refill`.

Server validates shop category, location and routing bucket, quantity, inventory debit and currency credit. It rate-limits repeat attempts and attempts to refund an item if payment fails. QBCore and Qbox payouts support `cash` or `bank`. ESX also supports an account named `black_money` if present. Standalone ox_inventory cash buyback pays the `money` inventory item if registered. If you lack a compatible currency backend, sellback is rejected before taking the item.

**No extra shop UI is added**: the commands work next to your actual shop counter. Existing shop scripts can supply an interaction that executes these player commands. Installed vehicle upgrades are not removable or sellable: resale applies only to unused inventory items. Configure buyback below retail price to avoid an economy exploit. Do not enable multiple overlapping shop sale scripts at the same counter unless intentional.

## 5. ACE-only install/refill commands (unchanged)

The ACE test commands bypass inventory and are distinct from ordinary retail item Use and buyback. In `server.cfg`:

```cfg
set rs_thrusters_dev_mode 1
add_ace group.admin rs_thrusters.test allow
```

Authorized admins **seated as driver** may use `/rstinstall` and `/rstrefill`. Ordinary players never gain an ACE install merely by owning a purchased item. You can disable ACE testing in production with `set rs_thrusters_dev_mode 0`.

## 6. Validation checklist after installing

- [ ] Correct inventory item table loads both items (check icon and item counts).
- [ ] At least one **active** mechanic shop stocks both items, with prices and real coordinates.
- [ ] Optional black-market resource is actually started and its catalog stocks both items.
- [ ] Player can buy kit, inventory receives one, and cash is charged by the **shop**.
- [ ] Player can **Use** it by a parked networked automobile without ACE.
- [ ] One item is removed **only** on successful install; repeat install does not consume another.
- [ ] Gas cartridge works on an already-installed vehicle when pressure is below maximum.
- [ ] `/rstinstall` without admin ACE is rejected; test command works only for authorized admin.
- [ ] If buyback is enabled and real coordinates are configured, `/rstsellkit` pays at that shop; from far away it rejects, and missing items cannot generate money.
- [ ] Restart `rs-thrusters` and re-enter an upgraded car to confirm persistence.

**Preserve the live** `rs-thrusters/data/installs.json`; the distribution ZIP includes an empty starter file to prevent releasing saved player/vehicle records.

Flight/stunt mechanics are not changed in v0.1.82. Isolated Lua simulations and syntax checks are not a substitute for live FiveM transaction tests.

## 7. Unlimited gas, 60-minute refills, mixed VIP access (v0.1.83)

See `README.md` and `Config.Gas` in `config.lua`. The default is `Mode = 'unlimited'` for everyone. Use `Mode = 'refill'` to require all drivers to buy gas cartridges, or `Mode = 'mixed'` to require refills only for drivers without `rs_thrusters.unlimited` ACE. A full tank lasts **at least 60 minutes of active use** regardless of nozzle count or stunt style; idle/disabled thrusters do not drain. After that, a configurable emergency landing reserve provides extra time. A cartridge refills the regular tank and reserve in one successful use. `/rstgas` shows driver-specific access without requiring admin privileges.

For mixed VIP players, add this to `server.cfg` (replace the license):

```cfg
add_ace group.thruster_vip rs_thrusters.unlimited allow
add_principal identifier.license:REPLACE_WITH_LICENSE group.thruster_vip
```

The unlimited entitlement is checked **server-side for each current driver**; it does not transfer with the car. The admin-only install/refill test ACE remains `rs_thrusters.test` and is not implied by the unlimited permission. Regular shop purchases, installation items, inventories, and optional shop buyback remain unchanged.
