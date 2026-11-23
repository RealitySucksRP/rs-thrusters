-- OPTIONAL player-to-shop resale. Purchase catalogs belong to each shop resource.
-- This module does not change driving physics, inventory item use or ACE commands.
local cfg = Config.Buyback or {}
local busy, cooldown = {}, {}
local kit, refill = Config.ItemKit, Config.ItemRefill

local function inform(src, message)
    TriggerClientEvent('rs_thrusters:notice', src, message)
end

local function backend()
    if GetResourceState('ox_inventory') == 'started' then return 'ox' end
    if GetResourceState('qb-core') == 'started' then return 'qb' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
end

local function qbPlayer(src)
    local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
    if not ok or not core or not core.Functions or not core.Functions.GetPlayer then return nil end
    return core.Functions.GetPlayer(src)
end

local function esxPlayer(src)
    local ok, core = pcall(function() return exports['es_extended']:getSharedObject() end)
    if not ok or not core or not core.GetPlayerFromId then return nil end
    return core.GetPlayerFromId(src)
end

local function itemCount(src, item)
    local inventory = backend()
    if inventory == 'ox' then
        local ok, n = pcall(function() return exports.ox_inventory:GetItemCount(src, item) end)
        return ok and tonumber(n) or 0
    elseif inventory == 'qb' then
        local player = qbPlayer(src)
        if not player or not player.Functions or not player.Functions.GetItemByName then return 0 end
        local ok, value = pcall(function() return player.Functions.GetItemByName(item) end)
        return ok and value and (tonumber(value.amount or value.count) or 0) or 0
    elseif inventory == 'esx' then
        local player = esxPlayer(src)
        if not player or not player.getInventoryItem then return 0 end
        local ok, value = pcall(player.getInventoryItem, item)
        return ok and value and (tonumber(value.count or value.amount) or 0) or 0
    end
    return 0
end

local function debit(src, item)
    local inventory = backend()
    if inventory == 'ox' then
        local ok, result = pcall(function() return exports.ox_inventory:RemoveItem(src, item, 1) end)
        return ok and result == true
    elseif inventory == 'qb' then
        local player = qbPlayer(src)
        if not player or not player.Functions or not player.Functions.RemoveItem then return false end
        local ok, result = pcall(function() return player.Functions.RemoveItem(item, 1, nil, 'rs-thrusters:buyback') end)
        return ok and result == true
    elseif inventory == 'esx' then
        local player = esxPlayer(src)
        if not player or not player.removeInventoryItem then return false end
        local before = itemCount(src, item)
        local ok, result = pcall(player.removeInventoryItem, item, 1)
        return ok and result ~= false and before > 0 and itemCount(src, item) == before - 1
    end
    return false
end

local function refund(src, item)
    local inventory = backend()
    local ok, success = false, false
    if inventory == 'ox' then
        ok, success = pcall(function() return exports.ox_inventory:AddItem(src, item, 1) end)
    elseif inventory == 'qb' then
        local player = qbPlayer(src)
        if player and player.Functions and player.Functions.AddItem then
            ok, success = pcall(function() return player.Functions.AddItem(item, 1, nil, {}, 'rs-thrusters:buyback-refund') end)
        end
    elseif inventory == 'esx' then
        local player = esxPlayer(src)
        if player and player.addInventoryItem then
            local before = itemCount(src, item)
            ok, success = pcall(player.addInventoryItem, item, 1)
            if ok then success = success ~= false and itemCount(src, item) == before + 1 end
        end
    end
    if not ok or success ~= true then
        print(('[rs-thrusters][BUYBACK] REFUND FAILED for player %s, item %s; restore manually'):format(src, item))
        return false
    end
    return true
end

-- Checking the payout interface BEFORE taking the item prevents selling on an
-- unsupported economy. Do not pay black_money through Qbox/QBCore cash APIs.
local function paymentSupported(src, currency)
    if GetResourceState('qbx_core') == 'started' then
        if currency ~= 'cash' and currency ~= 'bank' then return false end
        local ok, balance = pcall(function() return exports.qbx_core:GetMoney(src, currency) end)
        return ok and type(balance) == 'number' 
    elseif GetResourceState('qb-core') == 'started' then
        local player = qbPlayer(src)
        return player ~= nil and player.Functions and player.Functions.AddMoney ~= nil
            and (currency == 'cash' or currency == 'bank')
    elseif GetResourceState('es_extended') == 'started' then
        local player = esxPlayer(src)
        if not player then return false end
        if currency == 'cash' then return player.addMoney ~= nil and player.getMoney ~= nil end
        return currency == 'black_money' and player.addAccountMoney ~= nil and player.getAccount ~= nil
    elseif backend() == 'ox' and currency == 'cash' then
        -- Standalone ox_inventory can pay an item named 'money'; an owner must
        -- register that item before enabling this mode.
        local ok, item = pcall(function() return exports.ox_inventory:Items('money') end)
        return ok and item ~= nil
    end
    return false
end

local function payout(src, amount, currency)
    if GetResourceState('qbx_core') == 'started' then
        local ok, result = pcall(function()
            return exports.qbx_core:AddMoney(src, currency, amount, 'rs-thrusters-buyback')
        end)
        return ok and result == true
    elseif GetResourceState('qb-core') == 'started' then
        local player = qbPlayer(src)
        if not player or not player.Functions then return false end
        local ok, result = pcall(function()
            return player.Functions.AddMoney(currency, amount, 'rs-thrusters-buyback')
        end)
        return ok and result == true
    elseif GetResourceState('es_extended') == 'started' then
        local player = esxPlayer(src)
        if not player then return false end
        if currency == 'cash' then
            local before = tonumber(player.getMoney()) or 0
            local ok, result = pcall(player.addMoney, amount)
            return ok and result ~= false and (tonumber(player.getMoney()) or 0) >= before + amount
        elseif currency == 'black_money' then
            local beforeAccount = player.getAccount('black_money')
            if not beforeAccount then return false end
            local before = tonumber(beforeAccount.money) or 0
            local ok, result = pcall(player.addAccountMoney, 'black_money', amount)
            local afterAccount = player.getAccount('black_money')
            return ok and result ~= false and afterAccount and (tonumber(afterAccount.money) or 0) >= before + amount
        end
    elseif backend() == 'ox' and currency == 'cash' then
        local ok, result = pcall(function() return exports.ox_inventory:AddItem(src, 'money', amount) end)
        return ok and result == true
    end
    return false
end

local function getNearestShop(src)
    local ped = GetPlayerPed(src)
    if ped == 0 or not DoesEntityExist(ped) then return nil end
    local pos = GetEntityCoords(ped)
    local allowedDistance = tonumber(cfg.MaxDistance) or 3.0
    for _, shop in ipairs(cfg.Locations or {}) do
        if type(shop) == 'table' and shop.coords and (shop.type == 'mechanic' or shop.type == 'blackmarket')
            and (GetPlayerRoutingBucket(src) == (shop.bucket or 0)) then
            local ok, distance = pcall(function() return #(pos - shop.coords) end)
            if ok and distance <= allowedDistance then return shop end
        end
    end
end

local function attempt(src, item)
    if src == 0 then return print('[rs-thrusters] Buyback commands must be used by an in-game player.') end
    if not cfg.Enabled then return inform(src, 'Shop buyback is not enabled on this server.') end
    if busy[src] then return end
    local now = GetGameTimer()
    if now - (cooldown[src] or -100000) < (tonumber(cfg.CooldownMs) or 1800) then return end
    cooldown[src] = now
    busy[src] = true
    local ok, problem = pcall(function()
        local shop = getNearestShop(src)
        if not shop then return inform(src, 'Visit a participating mechanic shop or black market to sell this item.') end
        local price = cfg.Prices and cfg.Prices[shop.type] and cfg.Prices[shop.type][item]
        if type(price) ~= 'number' or price < 1 or price % 1 ~= 0 then
            return inform(src, 'This shop does not buy that item.')
        end
        local currency = shop.currency or 'cash'
        if not paymentSupported(src, currency) then
            return inform(src, 'This shop has no supported payout account; item was not removed.')
        end
        if itemCount(src, item) < 1 then return inform(src, 'You do not have this item to sell.') end
        if not debit(src, item) then return inform(src, 'Inventory could not remove the item; sale cancelled.') end
        local paidOK, paid = pcall(payout, src, price, currency)
        if not paidOK or paid ~= true then
            if not paidOK then
                print(('[rs-thrusters][BUYBACK] PAYOUT ERROR src=%s %s'):format(src, tostring(paid)))
            end
            local restored = refund(src, item)
            return inform(src, restored and 'Payment failed; your item was returned.'
                or 'Payment failed; contact staff for an item refund.')
        end
        inform(src, ('Sold %s to %s for $%d (%s).'):format(item, shop.type, price, currency))
        print(('[rs-thrusters][BUYBACK] src=%d shop=%s item=%s payment=%d currency=%s'):
            format(src, shop.type, item, price, currency))
    end)
    busy[src] = nil
    if not ok then
        print(('[rs-thrusters][BUYBACK] ERROR src=%s %s'):format(src, tostring(problem)))
        inform(src, 'Sale failed; check server console.')
    end
end

RegisterCommand('rstsellkit', function(src) attempt(src, kit) end, false)
RegisterCommand('rstsellrefill', function(src) attempt(src, refill) end, false)
AddEventHandler('playerDropped', function()
    busy[source], cooldown[source] = nil, nil
end)

if cfg.Enabled and #(cfg.Locations or {}) == 0 then
    print('[rs-thrusters][BUYBACK] WARNING: Enabled but no mechanic/blackmarket coordinates are configured; no sales can occur.')
end
