local function GetPlayer(src)
    local success, player = pcall(function()
        return exports['corex-core']:GetPlayer(src)
    end)
    return success and player or nil
end

local function SetStat(src, stat, value)
    local ok, result = pcall(function()
        return exports['corex-core']:SetStat(src, stat, value)
    end)
    return ok and result == true
end

local function SavePlayer(src)
    pcall(function()
        exports['corex-core']:SavePlayer(src, true)
    end)
end

local function SetPlayerState(src, state)
    local ok, result = pcall(function()
        return exports['corex-core']:SetPlayerState(src, state)
    end)
    return ok and result == true
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

    if type(IsEntityDead) == 'function' then
        local ok, isDead = pcall(IsEntityDead, ped)
        if ok and isDead then return true end
    end

    if type(GetEntityHealth) == 'function' then
        local ok, health = pcall(GetEntityHealth, ped)
        health = ok and tonumber(health) or nil
        if health and health <= 100 then return true end
    end

    return false
end

local coreEpoch = 0
local function CaptureSession(src)
    local ok, session = pcall(function()
        local player = GetPlayer(src)
        if not player or type(player.identifier) ~= 'string' then return nil end
        for _, presence in ipairs(exports['corex-core']:GetPlayerPresence(player.identifier)) do
            if presence.source == src and type(presence.sessionToken) == 'string'
                and presence.sessionToken ~= '' then
                return { identifier = player.identifier, token = presence.sessionToken, epoch = coreEpoch }
            end
        end
    end)
    return ok and session or nil
end

local function CurrentSession(src, expected)
    if not expected or expected.epoch ~= coreEpoch then return false end
    local current = CaptureSession(src)
    return current and current.identifier == expected.identifier and current.token == expected.token
end

local function CaptureDeathCoords(src)
    local ok, coords = pcall(function()
        local ped = GetPlayerPed(src)
        if not ped or ped == 0 then return nil end
        return GetEntityCoords(ped)
    end)
    if not ok or not coords then return nil end
    for _, key in ipairs({ 'x', 'y', 'z' }) do
        local value = coords[key]
        if type(value) ~= 'number' or value ~= value or math.abs(value) >= math.huge then return nil end
    end
    return { x = coords.x, y = coords.y, z = coords.z }
end

local function ResetSurvivalRuntime(src)
    local ok, result = pcall(function()
        if GetResourceState('corex-survival') ~= 'started' then return false end
        return exports['corex-survival']:ResetPlayerDamageState(src)
    end)
    return ok and result == true
end

local function DropRandomItems(src, coords, session)
    if not coords then return end

    -- Whichever inventory CoreX has, not one named resource: a player who dies
    -- with a replacement inventory installed still drops what they carried.
    local carried = CoreXInventoryBridge.GetItems(src)
    if type(carried) ~= 'table' then return end

    local items = {}
    for _, item in ipairs(carried) do
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
        if not CurrentSession(src, session) then return end
        local item = shuffled[i]
        local dropped = CoreXInventoryBridge.DropItem(
            src,
            item.name,
            item.count,
            item.slot,
            vector3(coords.x, coords.y, coords.z)
        )

        if dropped ~= true then
            print(('[COREX-DEATH] Could not confirm item drop for player %d; stopped penalties without retry. Check inventory/provider logs.'):format(src))
            return
        end

        if Config.Debug then
            print(('[COREX-DEATH] Dropped %dx %s from player %d'):format(item.count, item.name, src))
        end
    end
end

local lastDeathLog = {}
local DEATH_LOG_RATE_MS = 5000
local recentDeathClaims = {}

-- Server-only integration: the Admin action already checks actor permission
-- and both sessions. Never expose a player-triggerable full-heal event.
exports('RevivePlayer', function(src)
    if GetInvokingResource() ~= 'corex-admin' then return false, 'permission_denied' end
    local session = CaptureSession(src)
    if not session then return false, 'target_offline' end
    for _, stat in ipairs({ 'hunger', 'thirst', 'stress', 'infection', 'bleeding', 'cold', 'sick', 'poison' }) do
        if not CurrentSession(src, session) then return false, 'session_changed' end
        local value = (stat == 'hunger' or stat == 'thirst') and 100 or 0
        if not SetStat(src, stat, value) then return false, 'vital_update_rejected_check_player' end
    end
    if not CurrentSession(src, session) then return false, 'session_changed' end
    if not SetPlayerState(src, 'active') then return false, 'state_update_rejected' end
    recentDeathClaims[src] = nil
    lastDeathLog[src] = nil
    ResetSurvivalRuntime(src)
    TriggerClientEvent('corex-death:client:adminRevive', src)
    return true
end)

local function MarkPlayerDead(src)
    if not SetPlayerState(src, 'dead') then return false end
    TriggerEvent('corex-spawn:server:playerDied', src)
    return true
end

local function StoreDeathClaim(src, coords, session)
    recentDeathClaims[src] = {
        at = GetGameTimer(),
        coords = coords,
        session = session
    }
    return recentDeathClaims[src]
end

local function GetRecentDeathClaim(src)
    local claim = recentDeathClaims[src]
    if not claim then return nil end

    -- One record per current session; waiting on the death screen must not
    -- silently restart its countdown after an arbitrary claim TTL.
    if not CurrentSession(src, claim.session) then
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

local function CompleteRespawn(src, claim)
    -- Lock before any export can yield or re-enter. Normal and emergency
    -- requests share this operation, so item penalties can run only once.
    claim.respawnStarted = true
    local values = {
        { 'hunger', Config.Penalties.resetHunger }, { 'thirst', Config.Penalties.resetThirst },
        { 'infection', Config.Penalties.resetInfection }, { 'cold', 0 }, { 'bleeding', 0 }
    }
    for _, stat in ipairs(values) do
        if not CurrentSession(src, claim.session) then return false, 'session_changed' end
        if not SetStat(src, stat[1], stat[2]) then
            claim.respawnStarted = false -- no item operations have run; these vital writes are idempotent
            return false, 'vital_update_rejected'
        end
    end
    if not CurrentSession(src, claim.session) then return false, 'session_changed' end
    if not SetPlayerState(src, 'loading') then
        claim.respawnStarted = false
        return false, 'state_update_rejected'
    end
    if Config.Penalties.loseItems and claim.coords then DropRandomItems(src, claim.coords, claim.session) end
    if not CurrentSession(src, claim.session) then return false, 'session_changed' end
    ResetSurvivalRuntime(src)
    SavePlayer(src)
    if not CurrentSession(src, claim.session) then return false, 'session_changed' end
    local player = GetPlayer(src)
    claim.dispatched = true

    TriggerClientEvent('corex-death:client:prepareRespawn', src)
    TriggerClientEvent('corex-spawn:client:clearSpawnFlags', src)
    TriggerClientEvent('corex-spawn:client:spawnPlayer', src, BuildRespawnPayload(player))
    return true
end

RegisterNetEvent('corex-death:server:playerDied', function(coords)
    local src = source
    local player = GetPlayer(src)
    if not player then return end

    if not IsPlayerActuallyDead(src) then return end
    local session = CaptureSession(src)
    if not session then return end
    local existing = GetRecentDeathClaim(src)
    if existing and (not existing.respawnStarted or GetPlayerState(src) ~= 'active') then return end
    -- Ignore client coordinates: item drops belong at the server-observed ped.
    local deathCoords = CaptureDeathCoords(src)
    if not MarkPlayerDead(src) then return end
    StoreDeathClaim(src, deathCoords, session)

    local now = GetGameTimer()
    if lastDeathLog[src] and (now - lastDeathLog[src]) < DEATH_LOG_RATE_MS then return end
    lastDeathLog[src] = now

    if Config.Debug and deathCoords then
        print(('[COREX-DEATH] %s (ID: %d) died at %.1f, %.1f, %.1f'):format(
            player.name, src, deathCoords.x, deathCoords.y, deathCoords.z
        ))
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= 'corex-core' then return end
    coreEpoch = coreEpoch + 1
    lastDeathLog, recentDeathClaims = {}, {}
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

    local session = CaptureSession(source)
    if not session then return end
    StoreDeathClaim(source, CaptureDeathCoords(source), session)
    CreateThread(function()
        Wait(1500)
        if not CurrentSession(source, session) or GetPlayerState(source) ~= 'dead' then return end
        TriggerClientEvent('corex-death:client:resumeDeath', source)
    end)
end)

local function RequestRespawn(src)
    local player = GetPlayer(src)
    local session = CaptureSession(src)
    if not player or not session then return false, 'player_unavailable' end
    local playerState = GetPlayerState(src)
    local deathClaim = GetRecentDeathClaim(src)
    if deathClaim and deathClaim.respawnStarted then return true end
    if playerState ~= 'dead' then
        if not IsPlayerActuallyDead(src) then return false, 'not_dead' end
        if not MarkPlayerDead(src) then return false, 'state_update_rejected' end
    end
    if not deathClaim then
        deathClaim = StoreDeathClaim(src, CaptureDeathCoords(src), session)
    end
    if ((GetGameTimer() - deathClaim.at) & 0xffffffff) < Config.DeathScreen.duration then
        return false, 'countdown_not_finished'
    end
    return CompleteRespawn(src, deathClaim)
end

local function HandleRespawnRequest(src)
    local ok, reason = RequestRespawn(src)
    if not ok then RejectRespawn(src, reason) end
    return ok, reason
end
RegisterNetEvent('corex-death:server:requestRespawn', function() HandleRespawnRequest(source) end)
RegisterNetEvent('corex-death:server:emergencyRespawn', function() HandleRespawnRequest(source) end)
exports('RequestRespawn', function(src)
    if GetInvokingResource() ~= 'corex-spawn' then return false, 'permission_denied' end
    return HandleRespawnRequest(src)
end)

RegisterNetEvent('corex-death:server:localRespawnFinished', function()
    local src = source
    local deathClaim = GetRecentDeathClaim(src)
    if not deathClaim or not deathClaim.dispatched or deathClaim.finished or deathClaim.finishing then return end
    deathClaim.finishing = true
    local function confirm(attempt)
        if recentDeathClaims[src] ~= deathClaim or not CurrentSession(src, deathClaim.session) then return end
        local ped = GetPlayerPed(src)
        local ok, health = pcall(GetEntityHealth, ped)
        if ped and ped ~= 0 and ok and type(health) == 'number' and health > 100 then
            if SetPlayerState(src, 'active') then
                deathClaim.finished = true
                SavePlayer(src)
            end
            deathClaim.finishing = false
        elseif attempt < 8 then
            -- Native resurrection can reach the server after the completion
            -- event. Bounded confirmation, never another heal or item drop.
            SetTimeout(250, function() confirm(attempt + 1) end)
        else
            deathClaim.finishing = false
        end
    end
    confirm(0)
end)
