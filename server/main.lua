local RESOURCE = GetCurrentResourceName()
local STORAGE_FILE = 'data/installs.json'
local MAX_MASK = (1 << #Config.Nozzles) - 1
local records = {}
local active = {} -- keyed by player source; ONLY server may authorize FX and pressure
local dirty = false

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
    if state.rsThrustersInstalled ~= installed then state:set('rsThrustersInstalled', installed, true) end
    if state.rsThrustersPressure ~= pressure then state:set('rsThrustersPressure', pressure, true) end
    if not installed and state.rsThrustersFx ~= 0 then state:set('rsThrustersFx', 0, true) end
    if not installed and state.rsThrustersIntensity ~= 0 then state:set('rsThrustersIntensity', 0, true) end
end

local function getRecord(vehicle)
    local key = vehicleKey(vehicle)
    return key and records[key] or nil, key
end

local function hasItem(src, itemName)
    if GetResourceState('ox_inventory') ~= 'started' then return false end
    local ok, count = pcall(function()
        return exports.ox_inventory:GetItemCount(src, itemName)
    end)
    return ok and type(count) == 'number' and count >= 1
end

local function removeItem(src, itemName)
    if GetResourceState('ox_inventory') ~= 'started' then return false end
    local ok, result = pcall(function()
        return exports.ox_inventory:RemoveItem(src, itemName, 1)
    end)
    return ok and result == true
end

local function giveBack(src, itemName)
    if GetResourceState('ox_inventory') == 'started' then
        local ok, result = pcall(function() return exports.ox_inventory:AddItem(src, itemName, 1) end)
        if not ok or not result then
            print(('[rs-thrusters] REFUND FAILED: give %s to player %d manually'):format(itemName, src))
        end
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
    records[key] = { installed = true, pressure = Config.MaxPressure }
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
end)

-- Only a validated networked driver can publish active nozzles.
-- The authoritative pressure and nozzle mask are kept server-side.
RegisterNetEvent('rs_thrusters:control', function(netId, requestedMask, requestedPower, requestedDuration)
    local src = source
    if type(requestedMask) ~= 'number' or requestedMask % 1 ~= 0 or requestedMask < 0 or requestedMask > MAX_MASK then return end
    if type(requestedPower) ~= 'number' or requestedPower ~= requestedPower or requestedPower < 0.25 or requestedPower > 1.0 then return end
    local vehicle = validVehicle(src, netId, true)
    if not vehicle then return end
    local rec, key = getRecord(vehicle)
    if not rec or not rec.installed then return end
    local state = Entity(vehicle).state
    if state.rsThrustersInstalled ~= true then setVehicleState(vehicle, rec) end
    local duration = Config.Pressure.DefaultDurationSeconds
    if Config.Pressure.AllowPlayerDuration and type(requestedDuration) == 'number'
        and requestedDuration == requestedDuration then
        duration = math.max(Config.Pressure.MinDurationSeconds,
            math.min(Config.Pressure.MaxDurationSeconds, math.floor(requestedDuration)))
    end
    local availablePressure = Config.Pressure.ConsumptionEnabled and (rec.pressure or 0) or Config.MaxPressure
    if availablePressure <= 0 then requestedMask = 0 end
    if requestedMask == 0 then requestedPower = 0 end
    local previous = active[src]
    local now = GetGameTimer()
    if previous and now - previous.lastRx < 80 then return end
    if previous and previous.vehicle ~= vehicle and DoesEntityExist(previous.vehicle) then
        Entity(previous.vehicle).state:set('rsThrustersFx', 0, true)
        Entity(previous.vehicle).state:set('rsThrustersIntensity', 0, true)
    end
    active[src] = { vehicle = vehicle, key = key, mask = requestedMask, power = requestedPower, duration = duration, lastRx = now,
        lastTick = (previous and previous.vehicle == vehicle and previous.lastTick) or now }
    if state.rsThrustersFx ~= requestedMask then state:set('rsThrustersFx', requestedMask, true) end
    local intensity = requestedPower * math.sqrt(math.max(0,availablePressure)/Config.MaxPressure)
    if math.abs((state.rsThrustersIntensity or 0)-intensity) > 0.05 or requestedMask == 0 then
        state:set('rsThrustersIntensity', intensity, true)
    end
end)

-- One debit per *physical* active nozzle. Server determines which jets consume gas.
-- Duty cycle is approximated by the on/off mask; malicious client force is not trusted.
local function drain(mask)
    local burn = 0.0
    for _, nozzle in ipairs(Config.Nozzles) do
        if (mask & nozzle.bit) ~= 0 then
            burn = burn + (Config.Pressure.BurnPerNozzle[Config.PropulsionKind(nozzle.kind)] or 0.0)
        end
    end
    return burn
end

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
                if Config.Pressure.ConsumptionEnabled and rec and rec.installed and a.mask ~= 0 then
                    local dt = math.min((now - a.lastTick) / 1000.0, 0.32)
                    -- Duration is calibrated against four lift jets at 100% output.
                    local liftBurn = 4 * Config.Pressure.BurnPerNozzle.belly
                    local used = drain(a.mask) / liftBurn * (Config.MaxPressure / a.duration)
                        * a.power * math.max(dt, 0)
                    if used > 0 then
                        local nextPressure = math.max(0.0, (rec.pressure or 0) - used)
                        rec.pressure = nextPressure
                        dirty = true
                        local state = Entity(vehicle).state
                        local rounded = math.floor(nextPressure * 10 + 0.5) / 10
                        -- A replication update each ~1% keeps bandwidth manageable.
                        if math.abs((state.rsThrustersPressure or 0) - rounded) >= 0.8 or nextPressure == 0 then
                            state:set('rsThrustersPressure', rounded, true)
                        end
                        if nextPressure == 0 then
                            a.mask = 0
                            state:set('rsThrustersFx', 0, true)
                            state:set('rsThrustersIntensity', 0, true)
                            notify(src, 'Thruster pressure empty. Refill the tank.')
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

print('[rs-thrusters] v' .. Config.Version .. ' started | standalone | dev_mode=' .. GetConvar('rs_thrusters_dev_mode', '0'))
