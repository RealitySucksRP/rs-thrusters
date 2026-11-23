local RESOURCE = GetCurrentResourceName()
local STORAGE_FILE = 'data/installs.json'
local MAX_MASK = (1 << #Config.Nozzles) - 1
local records = {}
local active = {} -- keyed by player source; ONLY server may authorize FX and pressure
local dirty = false

-- Server-owned entitlement and fuel economy. All modes work without a
-- framework; only shop purchases need an inventory resource.
local function gasMode()
    local mode = Config.Gas and Config.Gas.Mode or 'unlimited'
    if mode ~= 'unlimited' and mode ~= 'refill' and mode ~= 'mixed' then
        return 'refill' -- fail closed if a server owner mistypes the mode
    end
    return mode
end

local function isUnlimited(src)
    local mode = gasMode()
    return mode == 'unlimited' or (mode == 'mixed'
        and IsPlayerAceAllowed(src, Config.Gas.UnlimitedAce or 'rs_thrusters.unlimited') == true)
end

local function refillSeconds()
    return math.max(60, tonumber(Config.Gas and Config.Gas.RefillMinutes) or 60) * 60
end

local function reserveMaximum()
    if not Config.Gas or Config.Gas.EmergencyLandingReserve ~= true then return 0 end
    return math.max(0, math.min(600, tonumber(Config.Gas.EmergencyReserveSeconds) or 60))
end

local function reserveFor(rec)
    if not rec or reserveMaximum() <= 0 then return 0 end
    if rec.reserveSeconds ~= nil then
        return math.max(0, tonumber(rec.reserveSeconds) or 0)
    end
    -- Older installations with remaining gas inherit one landing reserve;
    -- an already empty tank does not regenerate gas after a restart.
    return (tonumber(rec.pressure) or 0) > 0 and reserveMaximum() or 0
end

local function debugLog(message)
    if Config.Debug then print(('[rs-thrusters] %s'):format(message)) end
end

local function loadData()
    local raw = LoadResourceFile(RESOURCE, STORAGE_FILE)
    local ok, decoded = pcall(json.decode, raw or '{}')
    local valid = ok and type(decoded) == 'table'
    records = valid and decoded or {}
    if not valid then print('[rs-thrusters] WARNING: installs.json invalid; not overwriting until manually fixed.') end
    return valid
end

local storageValid = loadData()
local function flush()
    if not dirty or not storageValid then return true end
    local ok = SaveResourceFile(RESOURCE, STORAGE_FILE, json.encode(records), -1)
    if not ok then
        print('[rs-thrusters] ERROR: Could not write data/installs.json')
        return false
    end
    dirty = false
    return true
end

local function notify(src, message)
    TriggerClientEvent('rs_thrusters:notice', src, message)
end

local function validVehicle(src, netId, mustBeDriver, maxDistance)
    if type(netId) ~= 'number' or netId < 1 or netId > 65535 then return nil end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return nil end
    if GetVehicleType(vehicle) ~= 'automobile' then return nil end
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    if GetPlayerRoutingBucket(src) ~= GetEntityRoutingBucket(vehicle) then return nil end
    if mustBeDriver then
        if GetPedInVehicleSeat(vehicle, -1) ~= ped then return nil end
    else
        local p, v = GetEntityCoords(ped), GetEntityCoords(vehicle)
        if #(p - v) > (maxDistance or Config.InstallDistance) then return nil end
    end
    return vehicle, ped
end

local function vehicleKey(vehicle)
    local plate = GetVehicleNumberPlateText(vehicle)
    if type(plate) ~= 'string' then return nil end
    plate = plate:upper():gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then return nil end
    return ('%s:%s'):format(GetEntityModel(vehicle), plate)
end

local function setVehicleState(vehicle, rec)
    if not DoesEntityExist(vehicle) then return end
    local state = Entity(vehicle).state
    local installed = rec ~= nil and rec.installed == true
    local pressure = installed and math.floor((rec.pressure or 0) * 10 + 0.5) / 10 or 0.0
    local reserve = installed and math.floor(reserveFor(rec) * 10 + 0.5) / 10 or 0.0
    if state.rsThrustersInstalled ~= installed then state:set('rsThrustersInstalled', installed, true) end
    if state.rsThrustersPressure ~= pressure then state:set('rsThrustersPressure', pressure, true) end
    if state.rsThrustersReserveSeconds ~= reserve then state:set('rsThrustersReserveSeconds', reserve, true) end
    if not installed and state.rsThrustersFx ~= 0 then state:set('rsThrustersFx', 0, true) end
    if not installed and state.rsThrustersIntensity ~= 0 then state:set('rsThrustersIntensity', 0, true) end
end

local function getRecord(vehicle)
    local key = vehicleKey(vehicle)
    return key and records[key] or nil, key
end

local function syncDriverAccess(src, vehicle)
    -- Never accept entitlement from the client. Verify the CURRENT driver.
    if GetPedInVehicleSeat(vehicle, -1) ~= GetPlayerPed(src) then return end
    local state = Entity(vehicle).state
    local allowed = isUnlimited(src)
    if state.rsThrustersGasDriver ~= src then state:set('rsThrustersGasDriver', src, true) end
    if state.rsThrustersUnlimited ~= allowed then state:set('rsThrustersUnlimited', allowed, true) end
end

local function gasAvailable(src, rec)
    return isUnlimited(src) or (tonumber(rec.pressure) or 0) > 0 or reserveFor(rec) > 0
end

-- Qbox, QBCore, and ESX servers using ox_inventory use its exports.
-- Standard QBCore and ESX inventories use their framework player APIs.
-- All item debits remain server-authoritative, regardless of client inventory UI.
local function inventoryType()
    if GetResourceState('ox_inventory') == 'started' then return 'ox' end
    if GetResourceState('qb-core') == 'started' then return 'qb' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return nil
end

local function getQbPlayer(src)
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if not ok or not core or not core.Functions or not core.Functions.GetPlayer then return nil end
    return core.Functions.GetPlayer(src)
end

local function getEsx()
    local ok, esx = pcall(function() return exports['es_extended']:getSharedObject() end)
    if ok and esx then return esx end

    -- Compatibility fallback for older ESX Legacy installations.
    local legacy
    TriggerEvent('esx:getSharedObject', function(obj) legacy = obj end)
    return legacy
end

local function getEsxPlayer(src)
    local esx = getEsx()
    if not esx or not esx.GetPlayerFromId then return nil end
    local ok, player = pcall(esx.GetPlayerFromId, src)
    return ok and player or nil
end

local function hasItem(src, itemName)
    local backend = inventoryType()
    if backend == 'ox' then
        local ok, count = pcall(function() return exports.ox_inventory:GetItemCount(src, itemName) end)
        return ok and type(count) == 'number' and count >= 1
    elseif backend == 'qb' then
        local player = getQbPlayer(src)
        if not player or not player.Functions or not player.Functions.GetItemByName then return false end
        local ok, item = pcall(function() return player.Functions.GetItemByName(itemName) end)
        return ok and type(item) == 'table' and (tonumber(item.amount or item.count) or 0) >= 1
    elseif backend == 'esx' then
        local player = getEsxPlayer(src)
        if not player or not player.getInventoryItem then return false end
        local ok, item = pcall(player.getInventoryItem, itemName)
        return ok and type(item) == 'table' and (tonumber(item.count or item.amount) or 0) >= 1
    end
    return false
end

local function removeItem(src, itemName)
    local backend = inventoryType()
    if backend == 'ox' then
        local ok, result = pcall(function() return exports.ox_inventory:RemoveItem(src, itemName, 1) end)
        return ok and result == true
    elseif backend == 'qb' then
        local player = getQbPlayer(src)
        if not player or not player.Functions or not player.Functions.RemoveItem then return false end
        local ok, result = pcall(function()
            return player.Functions.RemoveItem(itemName, 1, nil, 'rs-thrusters:vehicle-install')
        end)
        return ok and result == true
    elseif backend == 'esx' then
        local player = getEsxPlayer(src)
        if not player or not player.getInventoryItem or not player.removeInventoryItem then return false end
        local beforeItem = player.getInventoryItem(itemName)
        local before = type(beforeItem) == 'table' and (tonumber(beforeItem.count or beforeItem.amount) or 0) or 0
        if before < 1 then return false end
        local ok, result = pcall(player.removeInventoryItem, itemName, 1)
        if not ok or result == false then return false end
        local afterItem = player.getInventoryItem(itemName)
        local after = type(afterItem) == 'table' and (tonumber(afterItem.count or afterItem.amount) or 0) or before
        return result == true or after <= before - 1
    end
    return false
end

local function giveBack(src, itemName)
    local backend = inventoryType()
    local ok, result = false, false
    if backend == 'ox' then
        ok, result = pcall(function() return exports.ox_inventory:AddItem(src, itemName, 1) end)
    elseif backend == 'qb' then
        local player = getQbPlayer(src)
        if player and player.Functions and player.Functions.AddItem then
            ok, result = pcall(function()
                return player.Functions.AddItem(itemName, 1, nil, {}, 'rs-thrusters:install-refund')
            end)
        end
    elseif backend == 'esx' then
        local player = getEsxPlayer(src)
        if player and player.getInventoryItem and player.addInventoryItem then
            local beforeItem = player.getInventoryItem(itemName)
            local before = type(beforeItem) == 'table' and (tonumber(beforeItem.count or beforeItem.amount) or 0) or 0
            ok, result = pcall(player.addInventoryItem, itemName, 1)
            if ok and result ~= false then
                local afterItem = player.getInventoryItem(itemName)
                local after = type(afterItem) == 'table' and (tonumber(afterItem.count or afterItem.amount) or 0) or before
                result = result == true or after >= before + 1
            end
        end
    end
    if not ok or result ~= true then
        print(('[rs-thrusters] REFUND FAILED: give %s to player %d manually'):format(itemName, src))
    end
end

local function performAction(src, netId, action, testing)
    if not storageValid then return notify(src, 'Thruster storage is invalid. Check server console.') end
    if testing then
        if GetConvarInt('rs_thrusters_dev_mode', 0) ~= 1 or not IsPlayerAceAllowed(src, Config.TestAce) then
            return notify(src, 'Test mode is off or ACE permission is missing.')
        end
    end

    local vehicle, ped = validVehicle(src, netId, testing, Config.InstallDistance)
    if not vehicle then return notify(src, 'No eligible nearby automobile / invalid vehicle access.') end
    if not testing then
        if GetVehiclePedIsIn(ped, false) ~= 0 then return notify(src, 'Get out of the car to install or refill.') end
        if #(GetEntityVelocity(vehicle)) > Config.MaxInstallSpeed then return notify(src, 'Park the vehicle before installing or refilling.') end
    end
    local rec, key = getRecord(vehicle)
    if not key then return notify(src, 'Vehicle has no valid plate. Upgrade was not installed.') end

    local itemName
    if action == 'install' then
        if rec and rec.installed then return notify(src, 'Thruster kit is already installed.') end
        itemName = Config.ItemKit
    elseif action == 'refill' then
        if not rec or not rec.installed then return notify(src, 'Install the thruster kit first.') end
        if (rec.pressure or 0) >= Config.MaxPressure - 0.1 then return notify(src, 'Tank is already full.') end
        itemName = Config.ItemRefill
    else return end

    if not testing then
        if not hasItem(src, itemName) then return notify(src, ('Missing item: %s'):format(itemName)) end
        if not removeItem(src, itemName) then return notify(src, 'Inventory could not consume the item.') end
    end

    local previous = records[key]
    records[key] = { installed = true, pressure = Config.MaxPressure, reserveSeconds = reserveMaximum() }
    dirty = true
    if not flush() then
        records[key] = previous
        dirty = true
        if not testing then giveBack(src, itemName) end
        return notify(src, 'Storage write failed. Installation cancelled; see server console.')
    end
    setVehicleState(vehicle, records[key])
    notify(src, action == 'install' and 'Cold-gas thruster kit installed. Enter car, press G.' or 'Thruster tank refilled to 100%.')
    debugLog(('Player %d %s %s'):format(src, action, key))
end

-- Ordinary framework players may use purchased / traded kits without ACE.
-- Any ox_inventory installation uses the item client.export instead, avoiding
-- a second framework usable-item handler for the same inventory action.
local function registerFrameworkUsableItems()
    local backend = inventoryType()
    if backend == 'ox' or not backend then return end

    if backend == 'qb' then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        if not ok or not core or not core.Functions or not core.Functions.CreateUseableItem then
            print('[rs-thrusters] WARNING: Could not register QBCore usable items.')
            return
        end
        core.Functions.CreateUseableItem(Config.ItemKit, function(src)
            TriggerClientEvent('rs_thrusters:useFrameworkItem', src, 'install')
        end)
        core.Functions.CreateUseableItem(Config.ItemRefill, function(src)
            TriggerClientEvent('rs_thrusters:useFrameworkItem', src, 'refill')
        end)
        print('[rs-thrusters] Registered QBCore usable shop items: '..Config.ItemKit..', '..Config.ItemRefill)
    elseif backend == 'esx' then
        local esx = getEsx()
        if not esx or not esx.RegisterUsableItem then
            print('[rs-thrusters] WARNING: Could not register ESX usable items.')
            return
        end
        esx.RegisterUsableItem(Config.ItemKit, function(src)
            TriggerClientEvent('rs_thrusters:useFrameworkItem', src, 'install')
        end)
        esx.RegisterUsableItem(Config.ItemRefill, function(src)
            TriggerClientEvent('rs_thrusters:useFrameworkItem', src, 'refill')
        end)
        print('[rs-thrusters] Registered ESX usable shop items: '..Config.ItemKit..', '..Config.ItemRefill)
    end
end

CreateThread(function()
    Wait(600)
    registerFrameworkUsableItems()
end)
AddEventHandler('onResourceStart', function(name)
    if name == 'qb-core' or name == 'es_extended' then
        CreateThread(function() Wait(600) registerFrameworkUsableItems() end)
    end
end)
AddEventHandler('onResourceStop', function(name)
    if name == 'ox_inventory' then
        CreateThread(function() Wait(600) registerFrameworkUsableItems() end)
    end
end)

RegisterNetEvent('rs_thrusters:install', function(netId, action)
    local src = source
    if action ~= 'install' and action ~= 'refill' then return end
    performAction(src, netId, action, false)
end)

RegisterNetEvent('rs_thrusters:testAction', function(netId, action)
    local src = source
    if action ~= 'install' and action ~= 'refill' then return end
    performAction(src, netId, action, true)
end)

RegisterNetEvent('rs_thrusters:syncVehicle', function(netId)
    local src = source
    local vehicle = validVehicle(src, netId, false, 12.0)
    if not vehicle then return end
    local rec = getRecord(vehicle)
    setVehicleState(vehicle, rec)
    syncDriverAccess(src, vehicle)
end)


RegisterNetEvent('rs_thrusters:gasDiag', function(netId)
    local src = source
    local vehicle = validVehicle(src, netId, true)
    if not vehicle then return end
    local rec = getRecord(vehicle)
    if not rec or not rec.installed then return end
    syncDriverAccess(src, vehicle)
    notify(src, ('Gas mode: %s | Your access: %s | Stored tank: %.1f%% | Landing reserve: %.0fs | Full tank: %.0fmin')
        :format(gasMode(), isUnlimited(src) and 'UNLIMITED' or 'REFILL',
            tonumber(rec.pressure) or 0, reserveFor(rec), refillSeconds()/60))
end)

-- Only a validated networked driver can publish active nozzles.
-- The authoritative pressure and nozzle mask are kept server-side.
RegisterNetEvent('rs_thrusters:control', function(netId, requestedMask, requestedPower, _requestedDuration)
    local src = source
    if type(requestedMask) ~= 'number' or requestedMask % 1 ~= 0 or requestedMask < 0 or requestedMask > MAX_MASK then return end
    if type(requestedPower) ~= 'number' or requestedPower ~= requestedPower or requestedPower < 0.25 or requestedPower > 1.0 then return end
    local vehicle = validVehicle(src, netId, true)
    if not vehicle then return end
    local rec, key = getRecord(vehicle)
    if not rec or not rec.installed then return end
    local state = Entity(vehicle).state
    if state.rsThrustersInstalled ~= true then setVehicleState(vehicle, rec) end
    syncDriverAccess(src, vehicle)
    -- The client-provided duration is intentionally ignored. Only config.lua
    -- sets how long a purchased refill lasts.
    local available = gasAvailable(src, rec)
    if not available then requestedMask = 0 end
    if requestedMask == 0 then requestedPower = 0 end
    local previous = active[src]
    local now = GetGameTimer()
    if previous and now - previous.lastRx < 80 then return end
    if previous and previous.vehicle ~= vehicle and DoesEntityExist(previous.vehicle) then
        Entity(previous.vehicle).state:set('rsThrustersFx', 0, true)
        Entity(previous.vehicle).state:set('rsThrustersIntensity', 0, true)
    end
    active[src] = { vehicle = vehicle, key = key, mask = requestedMask, power = requestedPower, lastRx = now,
        lastTick = (previous and previous.vehicle == vehicle and previous.lastTick) or now }
    if state.rsThrustersFx ~= requestedMask then state:set('rsThrustersFx', requestedMask, true) end
    -- Effective thrust/visual intensity stays constant until gas is exhausted;
    -- refill economy never weakens hover, boost or roll dynamics.
    local intensity = available and requestedPower or 0.0
    if math.abs((state.rsThrustersIntensity or 0)-intensity) > 0.05 or requestedMask == 0 then
        state:set('rsThrustersIntensity', intensity, true)
    end
end)

-- One full cartridge grants at least Config.Gas.RefillMinutes minutes of
-- ACTIVE flight, regardless of nozzle count or stunt type. A separate,
-- limited landing reserve activates only after those minutes have elapsed.
-- No gas drains while the vehicle is idle, the jets are off, or a VIP drives.
CreateThread(function()
    while true do
        Wait(250)
        local now = GetGameTimer()
        for src, a in pairs(active) do
            local vehicle = a.vehicle
            local ped = GetPlayerPed(src)
            local valid = GetPlayerName(src) ~= nil and DoesEntityExist(vehicle) and ped ~= 0
                and GetPedInVehicleSeat(vehicle, -1) == ped
                and (now - a.lastRx) <= 850
            if not valid then
                if DoesEntityExist(vehicle) then
                    Entity(vehicle).state:set('rsThrustersFx', 0, true)
                    Entity(vehicle).state:set('rsThrustersIntensity', 0, true)
                end
                active[src] = nil
            else
                local rec = records[a.key]
                syncDriverAccess(src, vehicle) -- ACE changes take effect immediately
                if not isUnlimited(src) and rec and rec.installed and a.mask ~= 0 then
                    local dt = math.max(0, math.min((now - a.lastTick) / 1000.0, 0.32))
                    local normal = math.max(0, tonumber(rec.pressure) or 0)
                    local reserve = reserveFor(rec)
                    local rate = Config.MaxPressure / refillSeconds()
                    local remainder = dt
                    if normal > 0 and dt > 0 then
                        local spend = math.min(normal, rate * dt)
                        rec.pressure = normal - spend
                        remainder = dt - spend / rate
                    end
                    if remainder > 0 and reserve > 0 then
                        rec.reserveSeconds = math.max(0, reserve - remainder)
                    elseif rec.reserveSeconds == nil then
                        rec.reserveSeconds = reserve
                    end
                    if dt > 0 then
                        dirty = true
                        local state = Entity(vehicle).state
                        local rounded = math.floor((rec.pressure or 0) * 10 + 0.5) / 10
                        local roundedReserve = math.floor(reserveFor(rec) * 10 + 0.5) / 10
                        -- Replicate roughly each 1% of tank or each reserve second.
                        if math.abs((state.rsThrustersPressure or 0) - rounded) >= 0.8 or rounded == 0 then
                            if state.rsThrustersPressure ~= rounded then state:set('rsThrustersPressure', rounded, true) end
                        end
                        if math.abs((state.rsThrustersReserveSeconds or 0) - roundedReserve) >= 1.0 or roundedReserve == 0 then
                            if state.rsThrustersReserveSeconds ~= roundedReserve then state:set('rsThrustersReserveSeconds', roundedReserve, true) end
                        end
                        if normal > 0 and (rec.pressure or 0) <= 0 and reserveFor(rec) > 0 then
                            notify(src, ('Regular gas empty: %.0f seconds of landing reserve. Descend and refill.'):format(reserveFor(rec)))
                        end
                        if not gasAvailable(src, rec) then
                            a.mask = 0
                            state:set('rsThrustersFx', 0, true)
                            state:set('rsThrustersIntensity', 0, true)
                            notify(src, 'Thruster gas exhausted. Refill the tank.')
                        end
                    end
                end
                a.lastTick = now
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(15000)
        flush()
    end
end)

AddEventHandler('playerDropped', function()
    local a = active[source]
    if a and DoesEntityExist(a.vehicle) then
        Entity(a.vehicle).state:set('rsThrustersFx', 0, true)
        Entity(a.vehicle).state:set('rsThrustersIntensity', 0, true)
    end
    active[source] = nil
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= RESOURCE then return end
    for _, a in pairs(active) do
        if DoesEntityExist(a.vehicle) then
            Entity(a.vehicle).state:set('rsThrustersFx', 0, true)
            Entity(a.vehicle).state:set('rsThrustersIntensity', 0, true)
        end
    end
    flush()
end)

print('[rs-thrusters] v' .. Config.Version .. ' started | inventory=' .. (inventoryType() or 'none') .. ' | dev_mode=' .. GetConvar('rs_thrusters_dev_mode', '0'))
