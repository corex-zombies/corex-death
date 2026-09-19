-- The CoreX inventory bridge.
--
-- CoreX modules are meant to be replaceable. A module that needs items
-- therefore asks CoreX for whichever inventory is installed rather than naming
-- one resource, so that a server owner can stop or delete `corex-inventory` and
-- start a different inventory without everything that used it breaking, and so
-- that stopping it never takes those modules down with it.
--
-- This file is the canonical copy. Every CoreX module that needs items ships a
-- byte-identical copy at `server/inventory_bridge.lua`, and
-- `corex-capabilities/tests/test_replaceable_modules.py` proves the copies have
-- not drifted. It is copied rather than included so that a module gains no new
-- dependency: with no capability layer installed it calls `corex-inventory`
-- exactly as that module always did, and with no inventory at all it answers
-- "no" instead of pretending an item was given.
--
-- Inventories differ. Only five operations are required of one; everything else
-- is optional, so a caller that needs more asks `SupportsOperation` first rather
-- than calling and hoping. An operation the installed inventory cannot do is
-- refused in those words - not reported as "no inventory installed", which
-- would send the owner looking for a problem that is not there.

local CAPABILITIES = 'corex-capabilities'
local NATIVE_INVENTORY = 'corex-inventory'
local WARNING_INTERVAL = 60000
local UNAVAILABLE = 'inventory-unavailable'
local CONTESTED = 'inventory-contested'

CoreXInventoryBridge = CoreXInventoryBridge or {}

local lastWarnedAt = {}

-- The exports the inventory that ships with CoreX publishes, per capability
-- operation. This map is only ever consulted when no capability layer is
-- running at all; it is what "behave exactly as this module always did" means.
-- An operation absent from this map has no pre-capability equivalent.
local nativeExportFor = {
    addItem = 'AddItem',
    removeItem = 'RemoveItem',
    getItemCount = 'GetItemCount',
    canCarryItem = 'CanCarryItem',
    getItemData = 'GetItemData',
    getCatalog = 'GetAllItemsData',
    getItems = 'GetInventory',
    getItemMetadata = 'GetItemMeta',
    dropItem = 'DropItem',
}

local function now()
    if type(GetGameTimer) ~= 'function' then return 0 end
    return GetGameTimer() or 0
end

--- One plain sentence a server owner can act on, at most once a minute. A
--- module that fails silently makes the owner read a console dump and guess.
local function warn(code, message)
    local moment = now()
    local previous = lastWarnedAt[code]
    if previous and (moment - previous) < WARNING_INTERVAL then return end
    lastWarnedAt[code] = moment
    print(('[%s] %s'):format(GetCurrentResourceName(), message))
end

local function warnFailure(failureCode, operation)
    if failureCode == 'CAPABILITY_CALL_FAILED' then
        warn(
            'inventory-reply-unknown',
            ('CoreX could not confirm the inventory reply for "%s", so %s did not retry it in another inventory. Check the capability/provider logs and actual item state before retrying.')
                :format(tostring(operation), GetCurrentResourceName())
        )
        return
    end
    if failureCode == 'PROVIDER_CONFLICT' then
        warn(
            CONTESTED,
            ('More than one resource is claiming the inventory, so CoreX refuses rather than guess which one is in charge, and %s cannot handle items. Stop all but one of them.')
                :format(GetCurrentResourceName())
        )
        return
    end
    if failureCode == 'OPERATION_UNAVAILABLE' then
        -- Saying "no inventory is installed" here would be false, and would
        -- send the owner looking for a problem that is not there.
        warn(
            'inventory-cannot-' .. tostring(operation),
            ('The inventory installed here cannot do "%s", so %s skipped that part. Everything else still works.')
                :format(tostring(operation), GetCurrentResourceName())
        )
        return
    end
    warn(
        UNAVAILABLE,
        ('No inventory is installed, so %s cannot handle items. Start corex-inventory, or another resource that provides an inventory to CoreX.')
            :format(GetCurrentResourceName())
    )
end

local function started(resource)
    if type(GetResourceState) ~= 'function' then return false end
    return GetResourceState(resource) == 'started'
end

local function isItemName(itemName)
    return type(itemName) == 'string' and itemName ~= ''
end

--- Route one operation through the capability layer.
--- @return any value, string? failureCode
local function capability(operation, ...)
    if not started(CAPABILITIES) then return nil, 'CAPABILITY_LAYER_ABSENT' end

    local called, result = pcall(function(...)
        return exports[CAPABILITIES]:Call('inventory', operation, {
            originResource = GetCurrentResourceName(),
            traceId = ('%s:inventory:%s'):format(GetCurrentResourceName(), operation),
        }, ...)
    end, ...)

    -- A lost/malformed reply is not absence: the selected inventory may have
    -- already mutated items. Never retry that operation against a second store.
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return nil, 'CAPABILITY_CALL_FAILED'
    end
    if result.ok == true then return result.value, nil end
    local failure = type(result.error) == 'table' and result.error or {}
    -- This sentinel belongs only to the local resource-state check above.
    if failure.code == 'CAPABILITY_LAYER_ABSENT' then return nil, 'CAPABILITY_CALL_FAILED' end
    return nil, failure.code or 'CAPABILITY_UNAVAILABLE'
end

--- Fall back to the resource this module used before the capability layer
--- existed. Only correct while that resource is actually running.
--- @return any value, boolean reached
local function native(name, ...)
    if not name or not started(NATIVE_INVENTORY) then return nil, false end
    local called, value = pcall(function(...)
        local handler = exports[NATIVE_INVENTORY][name]
        if not handler then error('no such export: ' .. name, 0) end
        return handler(exports[NATIVE_INVENTORY], ...)
    end, ...)
    if not called then return nil, false end
    return value, true
end

--- The common shape: ask the capability layer, and only reach for the shipped
--- inventory by name when there is no capability layer at all.
---
--- Once the layer is running it is the authority. Falling back past it would
--- quietly overrule a deliberate refusal: a capability two resources are
--- contesting, or a stateful selection the layer has blocked until an operator
--- recovers it. Either way the honest answer is no, said out loud.
--- @return any value, boolean answered
local function route(operation, ...)
    local value, failure = capability(operation, ...)
    if not failure then return value, true end

    if failure == 'CAPABILITY_LAYER_ABSENT' then
        local fallback, reached = native(nativeExportFor[operation], ...)
        if reached then return fallback, true end
    end

    warnFailure(failure, operation)
    return nil, false
end

--- The provider CoreX has selected for items, as the registry describes it.
--- @return table?
local function descriptor()
    if not started(CAPABILITIES) then return nil end
    local called, result = pcall(function()
        return exports[CAPABILITIES]:GetProvider('inventory')
    end)
    if not called or type(result) ~= 'table' or result.ok ~= true then return nil end
    return type(result.value) == 'table' and result.value or nil
end

--- Is any inventory reachable at all?
--- @return boolean
function CoreXInventoryBridge.IsAvailable()
    return CoreXInventoryBridge.ProviderId() ~= nil
end

--- Which resource is currently answering for items, if any.
--- @return string?
function CoreXInventoryBridge.ProviderId()
    if started(CAPABILITIES) then
        local selected = descriptor()
        -- The layer answered, and if its answer was no it is not second-guessed.
        return selected and selected.id or nil
    end
    if started(NATIVE_INVENTORY) then return NATIVE_INVENTORY end
    return nil
end

--- Can the inventory that is actually installed do this?
---
--- Only five operations are required of an inventory. Anything past those is
--- asked about first, so a caller degrades on purpose instead of discovering a
--- refusal halfway through something.
--- @return boolean
function CoreXInventoryBridge.SupportsOperation(operation)
    if type(operation) ~= 'string' or operation == '' then return false end

    if started(CAPABILITIES) then
        local selected = descriptor()
        local inventory = selected
            and type(selected.capabilities) == 'table'
            and selected.capabilities.inventory
            or nil
        if type(inventory) ~= 'table' or type(inventory.operations) ~= 'table' then return false end
        for _, published in pairs(inventory.operations) do
            if published == operation then return true end
        end
        return false
    end

    local exportName = nativeExportFor[operation]
    if not exportName or not started(NATIVE_INVENTORY) then return false end
    local called, handler = pcall(function() return exports[NATIVE_INVENTORY][exportName] end)
    return called and handler ~= nil
end

--- @return number
function CoreXInventoryBridge.GetItemCount(source, itemName)
    if not isItemName(itemName) then return 0 end
    local value = route('getItemCount', source, itemName)
    return type(value) == 'number' and value or 0
end

--- @return boolean
function CoreXInventoryBridge.HasItem(source, itemName, count)
    if not isItemName(itemName) then return false end
    return CoreXInventoryBridge.GetItemCount(source, itemName) >= (tonumber(count) or 1)
end

--- @return boolean
function CoreXInventoryBridge.AddItem(source, itemName, count, metadata)
    if not isItemName(itemName) then return false end
    local value = route('addItem', source, itemName, tonumber(count) or 1, metadata)
    return value == true
end

--- @return boolean
function CoreXInventoryBridge.RemoveItem(source, itemName, count)
    if not isItemName(itemName) then return false end
    local value = route('removeItem', source, itemName, tonumber(count) or 1)
    return value == true
end

--- @return boolean
function CoreXInventoryBridge.CanCarryItem(source, itemName, count, metadata)
    if not isItemName(itemName) then return false end
    local value = route('canCarryItem', source, itemName, tonumber(count) or 1, metadata)
    return value == true
end

--- One held item, or nil when the player does not have it.
--- @return table?
function CoreXInventoryBridge.GetItem(source, itemName)
    if not isItemName(itemName) then return nil end
    local value = route('getItem', source, itemName)
    return type(value) == 'table' and value or nil
end

--- The metadata attached to a held item.
---
--- Inventories that publish `getItemMetadata` answer directly; the rest carry
--- metadata inside `getItem`, so that is read instead rather than reporting the
--- item as having none.
--- @return table?
function CoreXInventoryBridge.GetItemMetadata(source, itemName)
    if not isItemName(itemName) then return nil end

    if CoreXInventoryBridge.SupportsOperation('getItemMetadata') then
        local direct = route('getItemMetadata', source, itemName)
        return type(direct) == 'table' and direct or nil
    end

    local held = CoreXInventoryBridge.GetItem(source, itemName)
    if type(held) ~= 'table' then return nil end
    return type(held.metadata) == 'table' and held.metadata or nil
end

--- Attach metadata to one held item.
--- @return boolean
function CoreXInventoryBridge.SetItemMetadata(source, slot, metadata)
    if type(metadata) ~= 'table' then return false end
    local value = route('setItemMetadata', source, slot, metadata)
    return value == true
end

--- An item definition from the catalog, not a held item.
--- @return table?
function CoreXInventoryBridge.GetItemDefinition(itemName)
    if not isItemName(itemName) then return nil end
    local value = route('getItemData', itemName)
    return type(value) == 'table' and value or nil
end

--- Every item definition the installed inventory knows, keyed by item name.
--- Catalog weights are neutral grams, including the native-only fallback.
--- @return table
function CoreXInventoryBridge.GetCatalog()
    local value, failure = capability('getCatalog')
    if failure == 'CAPABILITY_LAYER_ABSENT' then
        local fallback, reached = native(nativeExportFor.getCatalog)
        if reached and type(fallback) == 'table' then
            local catalog = {}
            for name, definition in pairs(fallback) do
                if type(definition) == 'table' then
                    local item = {}
                    for key, field in pairs(definition) do item[key] = field end
                    item.weight = (tonumber(definition.weight) or 0) * 1000
                    catalog[name] = item
                end
            end
            return catalog
        end
    end
    if failure then warnFailure(failure, 'getCatalog'); return {} end
    return type(value) == 'table' and value or {}
end

--- Where the installed inventory keeps this item's picture, if it has one.
---
--- Icons belong to the inventory that ships them, so this is a question for the
--- provider rather than a path assembled from a resource name.
--- @return string?
function CoreXInventoryBridge.GetItemImage(itemName)
    if not isItemName(itemName) then return nil end
    local value = route('getItemImage', itemName)
    return type(value) == 'string' and value ~= '' and value or nil
end

--- The grid an inventory lays items out on, when it uses one at all. Slot-based
--- inventories have no grid and answer nil, which is not a failure.
--- @return table? { width = number, height = number }
function CoreXInventoryBridge.GetGridSize()
    local value = route('getGridSize')
    if type(value) ~= 'table' then return nil end
    local width, height = tonumber(value.width), tonumber(value.height)
    if not width or not height then return nil end
    return { width = width, height = height }
end

--- Everything a player is carrying, as a flat list. An inventory that will not
--- list its contents yields an empty list rather than a pretended one.
--- @return table
function CoreXInventoryBridge.GetItems(source)
    local value, failure = capability('getItems', source)
    if not failure and type(value) == 'table' then return value end

    if failure == 'CAPABILITY_LAYER_ABSENT' then
        local fallback, reached = native(nativeExportFor.getItems, source)
        if reached then
            local slots = type(fallback) == 'table' and fallback.items or nil
            if type(slots) ~= 'table' then return {} end
            local items = {}
            for _, slot in pairs(slots) do
                if type(slot) == 'table' and type(slot.name) == 'string' then
                    items[#items + 1] = {
                        name = slot.name,
                        count = slot.count,
                        slot = slot.slot or slot.slotId,
                        metadata = slot.metadata,
                    }
                end
            end
            return items
        end
    end

    if failure then warnFailure(failure, 'getItems') end
    return {}
end

--- Replace everything a player is carrying.
---
--- Only an inventory that keeps its items inside the framework's own player
--- data publishes this; one with a store of its own owns the list and refuses,
--- because writing it from outside would make a second copy that drifts.
--- @return boolean
function CoreXInventoryBridge.SetItems(source, items)
    if type(items) ~= 'table' then return false end
    local value = route('setItems', source, items)
    return value == true
end

--- One occupied slot, as the inventory describes it.
--- @return table?
function CoreXInventoryBridge.GetSlot(source, slot)
    local value = route('getSlot', source, slot)
    return type(value) == 'table' and value or nil
end

--- Every slot, including empty ones where the inventory reports them.
--- @return table
function CoreXInventoryBridge.GetSlots(source)
    local value = route('getSlots', source)
    return type(value) == 'table' and value or {}
end

--- How worn one held item is, on the inventory's own scale.
--- @return number?
function CoreXInventoryBridge.GetDurability(source, slot)
    local value = route('getDurability', source, slot)
    return type(value) == 'number' and value or nil
end

--- @return boolean
function CoreXInventoryBridge.SetDurability(source, slot, durability)
    if type(durability) ~= 'number' then return false end
    local value = route('setDurability', source, slot, durability)
    return value == true
end

--- @return number?
function CoreXInventoryBridge.GetWeight(source)
    local value = route('getWeight', source)
    return type(value) == 'number' and value or nil
end

--- @return number?
function CoreXInventoryBridge.GetMaxWeight(source)
    local value = route('getMaxWeight', source)
    return type(value) == 'number' and value or nil
end

--- Drop an item on the ground. Where a dropped item goes is the inventory's own
--- business, so this asks rather than places it.
--- @return boolean
function CoreXInventoryBridge.DropItem(source, itemName, count, slot, coords)
    if not isItemName(itemName) then return false end
    local value = route('dropItem', source, itemName, tonumber(count) or 1, slot, coords)
    return value == true
end

--- Put an item on the ground where nobody was carrying it - a body's pockets,
--- a crate that broke open. Not every inventory can create a drop out of
--- nothing, so callers ask first and hand the item to the player instead.
--- The first return preserves the boolean API. A caller must not retry a drop
--- using AddItem after an unknown reply: the drop may already exist.
--- @return boolean confirmed, string outcome
function CoreXInventoryBridge.CreateDrop(itemName, count, coords)
    if not isItemName(itemName) then return false, 'rejected' end
    -- There is intentionally no legacy native createDrop mapping. A resource
    -- checks SupportsOperation first when it can offer direct-item delivery.
    local value, failure = capability('createDrop', itemName, tonumber(count) or 1, coords)
    if not failure and value == true then return true, 'confirmed' end
    if not failure and value == false then return false, 'rejected' end
    -- Even a structured provider error can follow a side effect. Only an
    -- explicit successful false reply proves this attempt was refused.
    warnFailure('CAPABILITY_CALL_FAILED', 'createDrop')
    return false, 'unknown'
end

--- Show a player their own inventory, or another inventory the provider knows.
--- @return boolean
function CoreXInventoryBridge.OpenInventory(source, inventoryType, inventoryId)
    local value = route('openInventory', source, inventoryType, inventoryId)
    return value == true
end

--- Show a player the contents of a container another resource owns, such as a
--- looted crate. Only some inventories can draw one.
--- @return boolean
function CoreXInventoryBridge.OpenContainer(source, containerId, items, label, options)
    if type(containerId) ~= 'string' and type(containerId) ~= 'number' then return false end
    local value = route('openContainer', source, containerId, items, label, options)
    return value == true
end

--- Declare a shared storage the inventory should own from now on.
--- @return boolean
function CoreXInventoryBridge.RegisterStash(stashId, label, slots, maxWeight, owner)
    if type(stashId) ~= 'string' or stashId == '' then return false end
    local value = route('registerStash', stashId, label, slots, maxWeight, owner)
    return value == true
end

--- @return table
function CoreXInventoryBridge.GetStashItems(stashId)
    if type(stashId) ~= 'string' or stashId == '' then return {} end
    local value = route('getStashItems', stashId)
    return type(value) == 'table' and value or {}
end

--- @return boolean
function CoreXInventoryBridge.SetStashItems(stashId, items)
    if type(stashId) ~= 'string' or stashId == '' or type(items) ~= 'table' then return false end
    local value = route('setStashItems', stashId, items)
    return value == true
end

--- Ask the inventory to call this back when a player uses the named item.
--- @return boolean
function CoreXInventoryBridge.RegisterUsableItem(itemName, handler)
    if not isItemName(itemName) then return false end
    local value = route('registerUsableItem', itemName, handler)
    return value == true
end

--- @return boolean
function CoreXInventoryBridge.UseItem(source, itemName)
    if not isItemName(itemName) then return false end
    local value = route('useItem', source, itemName)
    return value == true
end

--- The weapons a player owns, where the inventory tracks weapons as items.
--- @return table
function CoreXInventoryBridge.GetWeapons(source)
    local value = route('getWeapons', source)
    return type(value) == 'table' and value or {}
end

--- @return boolean
function CoreXInventoryBridge.HasWeapon(source, weaponName)
    if not isItemName(weaponName) then return false end
    local value = route('hasWeapon', source, weaponName)
    return value == true
end
