-- Space attacks the next creature in the battle list, and the run's kit is put
-- on the action bar so the player can see it and bind it however they like.
--
-- This lives in its own module rather than in the hotkeys manager's defaults,
-- for two reasons. loadDefautComboKeys only runs when a profile has NO saved
-- hotkeys, so a default added there never reaches anyone who has already used
-- the client. And hotkeys_manager.lua is upstream, so editing it would cost a
-- conflict on every merge from opentibiabr for one key.
--
-- Space is bound to the game root panel on purpose. A key bound there does not
-- fire while the chat console holds focus, which is what keeps Space typing a
-- space when the player is actually talking. With chat off, it attacks.
--
-- The kit used to be bound to F1 through F6 here, chosen by us. That was wrong:
-- it is the player's keyboard. The kit now goes into action bar slots, which is
-- the surface Tibia already has for this, and every player assigns their own
-- keys through the action bar's own hotkey UI.

-- Opcode 176 is claimed in docs/opcodes.md, and the version token has to match
-- ArenaConfig.hud.version on the server and WIRE_VERSION in
-- modules/game_arenahud/arenahud.lua. A mismatch leaves the bar untouched,
-- which is the intended failure: a slot holding the wrong thing is worse than
-- an empty one.
local OPCODE_KEYS = 176
local WIRE_VERSION = 'v5'

local BINDING = 'Space'

-- The first bar, which is the row along the bottom of the screen.
local ACTION_BAR = 1

-- How far along the bar to look for room. The bar holds 50 buttons; a kit that
-- needed more than the first 30 free would be lost off the end of what anyone
-- can see anyway.
local SLOT_SEARCH_LIMIT = 30

-- Slots this run's manifest has already claimed, so six entries arriving as six
-- separate messages do not all pick the same free slot. Reset when a manifest
-- starts, which is the first bind after any non-bind verb.
local taken = {}

local bound = false

local function attackNext()
    if not g_game.isOnline() then
        return
    end
    -- Guarded rather than assumed. game_battle is loaded from game_interface's
    -- load-later list, and that list is one Exp Arena trims, so an unguarded
    -- call would turn every Space press into a nil index the day it is dropped.
    if modules.game_battle then
        modules.game_battle.attackNext()
    end
end

local function bind()
    if bound then
        return
    end
    local panel = modules.game_interface and modules.game_interface.getRootPanel()
    if not panel then
        return
    end
    g_keyboard.bindKeyDown(BINDING, attackNext, panel)
    bound = true
end

local function unbind()
    if not bound then
        return
    end
    local panel = modules.game_interface and modules.game_interface.getRootPanel()
    if panel then
        -- Pass the callback, not just the widget. unbindKeyDown with a nil
        -- callback disconnects every listener on that combo, which would take
        -- any other module's Space binding down with ours.
        g_keyboard.unbindKeyDown(BINDING, attackNext, panel)
    end
    bound = false
end

local function actionBar()
    local bars = modules.game_actionbar and modules.game_actionbar.actionBars
    return bars and bars[ACTION_BAR]
end

local function buttonAt(slot)
    local bar = actionBar()
    if not bar or not bar.tabBar then
        return nil
    end

    local id = ACTION_BAR .. '.' .. slot
    for _, child in ipairs(bar.tabBar:getChildren()) do
        if child:getId() == id then
            return child
        end
    end
    return nil
end

-- The first slot on the bar that holds nothing, searched from the start.
--
-- Searched rather than assumed, because the obvious slots are taken. The shipped
-- defaults fill buttons 1 to 5 for every vocation, and a profile that has been
-- played fills more: this machine's Paladin set occupies 1 to 6. Placing the kit
-- at 1 to 6 therefore placed nothing at all, six times, silently.
local function firstFreeSlot(api, taken)
    for slot = 1, SLOT_SEARCH_LIMIT do
        if not taken[slot] then
            local existing = api.getMapping(ACTION_BAR, slot)
            if not (existing and existing.actionsetting) then
                return slot
            end
        end
    end
    return nil
end

-- Writes one kit entry into the first free slot.
--
-- Never overwriting is the whole point. A player who dragged the potion where
-- they want it keeps it there, a player who filled slot 3 with something of
-- their own keeps that, and the arena only ever fills what is free. The
-- alternative, rewriting the bar at every run start, would undo the player's
-- own arrangement several times an evening and would read as the client fighting
-- them.
local function placeOnBar(taken, entry)
    local api = modules.game_actionbar and modules.game_actionbar.ApiJson
    local update = modules.game_actionbar and modules.game_actionbar.updateButton
    if not api or not update then
        g_logger.info('arena kit: no action bar to place ' .. entry.label .. ' on')
        return false
    end

    local slot = firstFreeSlot(api, taken)
    if not slot then
        -- Said out loud. This used to return quietly, so a bar with no room
        -- looked exactly like a kit that had been delivered.
        g_logger.info('arena kit: no free action bar slot for ' .. entry.label)
        return false
    end
    taken[slot] = true

    if entry.kind == 'say' then
        -- sendAutomatically, so the slot casts rather than typing the words into
        -- the chat box and waiting for a return.
        api.createOrUpdateText(ACTION_BAR, slot, entry.payload, true)
    elseif entry.kind == 'item' then
        -- useType is the action bar's own name for it, and it has to be the
        -- name: the consumer reads UseTypes[value] from a table with string keys
        -- only, so a number falls through to plain Use and fires the item at
        -- nothing. A rune or a machete used at nothing does nothing.
        api.createOrUpdateAction(ACTION_BAR, slot, entry.useType, entry.itemId, 0)
    else
        return false
    end

    local button = buttonAt(slot)
    if button then
        update(button)
    end
    if api.saveData then
        api.saveData()
    end

    g_logger.info(string.format('arena kit slot %d: %s', slot, entry.label))
    return true
end

-- Splits on the delimiter, keeping empty fields and stopping after `limit`
-- fields so the last one holds whatever is left. The label is human text and is
-- the only field allowed to run long; everything before it is a fixed token.
local function split(buffer, limit)
    local parts = {}
    local from = 1

    while #parts < limit - 1 do
        local at = buffer:find('|', from, true)
        if not at then
            break
        end
        parts[#parts + 1] = buffer:sub(from, at - 1)
        from = at + 1
    end
    parts[#parts + 1] = buffer:sub(from)

    return parts
end

-- Opcode 176. The arena kit for this run. The field count varies by verb, a
-- bind carrying four fields the clear does not, so this splits rather than
-- matching a fixed shape, the way opcode 173 is handled in arenahud.lua.
--
-- The key field is still on the wire and is now ignored entirely. It once named
-- a binding, then it named a slot, and neither survived contact: the slots it
-- named were already full. The order entries arrive in is the order they go on
-- the bar, and which key fires them is the player's business.
local function onArenaKeys(protocol, opcode, buffer)
    local parts = split(buffer, 6)
    if parts[1] ~= WIRE_VERSION then
        return
    end

    local verb = parts[2]
    -- A clear leaves the bar alone. The kit items are gone from the inventory by
    -- then and the slot simply greys out, which is the same thing that happens
    -- to any item hotkey when the item runs out, and it means the player's
    -- arrangement survives the end of a run. All it does here is forget which
    -- slots this run claimed, so the next run looks at the bar fresh.
    if verb ~= 'bind' then
        taken = {}
        return
    end

    local key, kind, payload = parts[3], parts[4], parts[5]
    if not key or key == '' or not payload or payload == '' then
        return
    end

    local entry = { kind = kind, label = parts[6] or key }
    if kind == 'say' then
        entry.payload = payload
    elseif kind == 'item' then
        -- The use type is a name, not a number, so this reads to the comma and
        -- takes the rest as it stands rather than matching digits.
        local itemId, useType = payload:match('^(%d+),(%S+)$')
        entry.itemId = tonumber(itemId)
        entry.useType = useType
        if not entry.itemId or not entry.useType then
            return
        end
    else
        return
    end

    -- Wrapped, because the action bar is upstream code reached across a module
    -- boundary and a change there must not be able to break a run.
    pcall(placeOnBar, taken, entry)
end

function init()
    ProtocolGame.registerExtendedOpcode(OPCODE_KEYS, onArenaKeys)
    connect(g_game, {
        onGameStart = bind,
        onGameEnd = unbind,
    })
    if g_game.isOnline() then
        bind()
    end
end

function terminate()
    disconnect(g_game, {
        onGameStart = bind,
        onGameEnd = unbind,
    })
    ProtocolGame.unregisterExtendedOpcode(OPCODE_KEYS)
    unbind()
end
