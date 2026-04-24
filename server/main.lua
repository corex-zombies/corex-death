local function GetPlayer(src)
    local success, player = pcall(function()
        return exports['corex-core']:GetPlayer(src)
    end)
    return success and player or nil
end

local function SetStat(src, stat, value)
    pcall(function()
        exports['corex-core']:SetStat(src, stat, value)
    end)
end

local function SavePlayer(src)
    pcall(function()
        exports['corex-core']:SavePlayer(src, true)
    end)
end

local function SetPlayerState(src, state)
    pcall(function()
        exports['corex-core']:SetPlayerState(src, state)
    end)
end

local function GetPlayerState(src)
    local ok, state = pcall(function()
        return exports['corex-core']:GetPlayerState(src)
    end)
    return ok and state or nil
end

local function IsPlayerActuallyDead(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end

    local checked = false
    if type(IsEntityDead) == 'function' then
        checked = true
        local ok, isDead = pcall(IsEntityDead, ped)
        if ok and isDead then return true end
    end

    if type(GetEntityHealth) == 'function' then
        checked = true
        local ok, health = pcall(GetEntityHealth, ped)
        health = ok and tonumber(health) or nil
        if health and health <= 100 then return true end
    end

    return not checked
end

local function SyncStateBag(src, key, value)
    pcall(function()
        local playerState = Player(src)
        local pState = playerState and playerState.state or nil
        if pState then
            pState:set(key, value, true)
        end
    end)
end

local function DropRandomItems(src, coords)
    if not coords then return end

    local success, inventory = pcall(function()
        return exports['corex-inventory']:GetInventory(src)
    end)
    if not success or not inventory then return end

    local inventoryItems = inventory.items
    if type(inventoryItems) ~= 'table' then return end

    local items = {}
    for _, item in ipairs(inventoryItems) do
        if item and item.name and item.count and item.count > 0 then
            items[#items + 1] = {
                slot = item.slot,
                name = item.name,
                count = item.count
            }
        end
    end

    if #items == 0 then return end

    local dropCount = math.max(1, math.floor(#items * Config.Penalties.loseItemsPercent))

    local shuffled = {}
    for i, v in ipairs(items) do
        shuffled[i] = v
    end
    for i = #shuffled, 2, -1 do
        local j = math.random(1, i)
        shuffled[i], shuffled[j] = shuffled[j], shuffled[i]
    end

    for i = 1, math.min(dropCount, #shuffled) do
        local item = shuffled[i]
        pcall(function()
            exports['corex-inventory']:DropItem(
                src,
                item.name,
                item.count,
                item.slot,
                vector3(coords.x, coords.y, coords.z)
            )
        end)

        if Config.Debug then
            print(('[COREX-DEATH] Dropped %dx %s from player %d'):format(item.count, item.name, src))
        end
    end
end

local lastDeathLog = {}
local DEATH_LOG_RATE_MS = 5000
local recentDeathClaims = {}
local DEATH_CLAIM_TTL_MS = 120000

local function MarkPlayerDead(src)
    SetPlayerState(src, 'dead')
    TriggerEvent('corex-spawn:server:playerDied', src)
end

local function StoreDeathClaim(src, coords)
    recentDeathClaims[src] = {
        at = GetGameTimer(),
        coords = coords
    }
end

local function GetRecentDeathClaim(src)
    local claim = recentDeathClaims[src]
    if not claim then return nil end

    if GetGameTimer() - claim.at > DEATH_CLAIM_TTL_MS then
        recentDeathClaims[src] = nil
        return nil
    end

    return claim
end

local function RejectRespawn(src, reason)
    TriggerClientEvent('corex-death:client:respawnRejected', src, reason or 'not_dead')
end

local function BuildRespawnPayload(player)
    local metadata = player and player.metadata or {}

    return {
        isNew = false,
        position = nil,
        skin = metadata and metadata.skin or nil,
        isRespawn = true,
        isResourceRestart = false,
        playerData = player and {
            name = player.name,
            money = player.money,
            metadata = metadata
        } or nil
    }
end

local function CompleteRespawn(src, player, dropCoords)
    if Config.Penalties.loseItems and dropCoords then
        DropRandomItems(src, dropCoords)
    end

    SetStat(src, 'hunger', Config.Penalties.resetHunger)
    SetStat(src, 'thirst', Config.Penalties.resetThirst)
    SetStat(src, 'infection', Config.Penalties.resetInfection)

    SyncStateBag(src, 'hunger', Config.Penalties.resetHunger)
    SyncStateBag(src, 'thirst', Config.Penalties.resetThirst)
    SyncStateBag(src, 'infection', Config.Penalties.resetInfection)

    SetPlayerState(src, 'loading')
    recentDeathClaims[src] = nil
    if player then
        SavePlayer(src)
    end

    TriggerClientEvent('corex-death:client:prepareRespawn', src)
    TriggerClientEvent('corex-spawn:client:clearSpawnFlags', src)
    TriggerClientEvent('corex-spawn:client:spawnPlayer', src, BuildRespawnPayload(player))
end

RegisterNetEvent('corex-death:server:playerDied', function(coords)
    local src = source
    local player = GetPlayer(src)
    if not player then return end

    if type(coords) ~= 'table' and type(coords) ~= 'vector3' then return end
    local cx = tonumber(coords.x) or 0
    local cy = tonumber(coords.y) or 0
    local cz = tonumber(coords.z) or 0
    local deathCoords = { x = cx, y = cy, z = cz }
    StoreDeathClaim(src, deathCoords)

    if not IsPlayerActuallyDead(src) then return end

    local now = GetGameTimer()
    if lastDeathLog[src] and (now - lastDeathLog[src]) < DEATH_LOG_RATE_MS then return end
    lastDeathLog[src] = now

    MarkPlayerDead(src)

    if Config.Debug then
        print(('[COREX-DEATH] %s (ID: %d) died at %.1f, %.1f, %.1f'):format(
            player.name, src, cx, cy, cz
        ))
    end
end)

AddEventHandler('playerDropped', function()
    lastDeathLog[source] = nil
    recentDeathClaims[source] = nil
end)

AddEventHandler('corex:server:playerReady', function(source, player)
    if not player or not player.metadata then
        return
    end

    if player.metadata.lifecycleState ~= 'dead' then
        return
    end

    CreateThread(function()
        Wait(1500)
        TriggerClientEvent('corex-death:client:resumeDeath', source)
    end)
end)

RegisterNetEvent('corex-death:server:requestRespawn', function(deathCoords)
    local src = source
    local player = GetPlayer(src)

    local playerState = GetPlayerState(src)
    local deathClaim = GetRecentDeathClaim(src)

    if playerState ~= 'dead' then
        if IsPlayerActuallyDead(src) or deathClaim then
            MarkPlayerDead(src)
        else
            RejectRespawn(src, 'not_dead')
            return
        end
    end

    local dropCoords = deathCoords or (deathClaim and deathClaim.coords) or nil
    CompleteRespawn(src, player, dropCoords)

    if Config.Debug and player then
        print(('[COREX-DEATH] %s (ID: %d) respawned'):format(player.name, src))
    end
end)

RegisterNetEvent('corex-death:server:emergencyRespawn', function(deathCoords)
    local src = source
    local player = GetPlayer(src)
    local deathClaim = GetRecentDeathClaim(src)
    local dropCoords = deathCoords or (deathClaim and deathClaim.coords) or nil

    MarkPlayerDead(src)
    CompleteRespawn(src, player, dropCoords)

    if Config.Debug then
        print(('[COREX-DEATH] Emergency respawn completed for ID %d'):format(src))
    end
end)

RegisterNetEvent('corex-death:server:localRespawnFinished', function()
    local src = source
    local player = GetPlayer(src)

    SetPlayerState(src, 'active')
    recentDeathClaims[src] = nil

    SetStat(src, 'hunger', Config.Penalties.resetHunger)
    SetStat(src, 'thirst', Config.Penalties.resetThirst)
    SetStat(src, 'infection', Config.Penalties.resetInfection)

    SyncStateBag(src, 'hunger', Config.Penalties.resetHunger)
    SyncStateBag(src, 'thirst', Config.Penalties.resetThirst)
    SyncStateBag(src, 'infection', Config.Penalties.resetInfection)

    if player then
        SavePlayer(src)
    end
end)
