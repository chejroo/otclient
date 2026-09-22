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
-- v6 with the session loop. The manifest itself did not change shape: the
-- version is shared by every arena opcode so that one token check covers the
-- whole HUD, and the bump is opcode 172's.
local WIRE_VERSION = 'v6'

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

-- The flag written onto every mapping the arena creates, and the whole reason
-- the bar does not silently fill up over an evening. Without it the second run
-- would skip the six slots the first run wrote, because they are no longer free,
-- and take six more; five runs would eat the thirty slots searched and the sixth
-- would place nothing. It is written on the mapping entry rather than kept in
-- memory so it survives a client restart or a crash mid run, which is exactly
-- when leftovers would otherwise be stranded with nothing left that knows they
-- are ours.
local MARK = 'arenaKit'

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

-- Takes back every slot the arena wrote, and only those.
--
-- The test is the mark, not the contents, so a slot the player dragged their own
-- thing into is left alone even if it sits where a kit entry used to, and a kit
-- entry the player moved elsewhere is still recognised and removed. Idempotent
-- on purpose: it runs both when a run ends and again when the next one starts,
-- because the first of those does not happen if the client is closed mid run.
local function sweepPreviousKit()
    local api = modules.game_actionbar and modules.game_actionbar.ApiJson
    local update = modules.game_actionbar and modules.game_actionbar.updateButton
    if not api then
        return 0
    end

    local removed = 0
    for slot = 1, SLOT_SEARCH_LIMIT do
        local existing = api.getMapping(ACTION_BAR, slot)
        if existing and existing[MARK] then
            api.removeAction(ACTION_BAR, slot)
            local button = buttonAt(slot)
            if button and update then
                update(button)
            end
            removed = removed + 1
        end
    end

    if removed > 0 then
        if api.saveData then
            api.saveData()
        end
        g_logger.info(string.format('arena kit: %d slot(s) handed back', removed))
    end
    return removed
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

    -- Marked after the write, not before: createOrUpdateText and
    -- createOrUpdateAction both replace `actionsetting` wholesale but leave the
    -- rest of the entry alone, and the mark sits beside it rather than inside it
    -- so nothing upstream reads it as part of an action.
    -- `mapping`, not `entry`. It used to be called `entry` and shadowed this
    -- function's own argument, which is the kit entry off the wire and the only
    -- thing here that carries a label. So the log line below read the action
    -- bar's stored mapping instead and printed `nil` for every key of every
    -- run, and it would have thrown outright on the day getMapping returned
    -- nothing, two lines after the `if mapping then` that admits it can.
    local mapping = api.getMapping(ACTION_BAR, slot)
    if mapping then
        mapping[MARK] = true
    end

    local button = buttonAt(slot)
    if button then
        update(button)
    end
    if api.saveData then
        api.saveData()
    end

    g_logger.debug(string.format('arena kit slot %d: %s', slot, entry.label or entry.kind or '?'))
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
    -- A clear hands the slots back. The kit items are gone from the inventory by
    -- then, so leaving the entries would leave six greyed out buttons that do
    -- nothing, and would also make the next run start its search past them.
    -- Only slots the arena wrote are touched, so the player's own arrangement
    -- comes back exactly as it was.
    if verb ~= 'bind' then
        taken = {}
        pcall(sweepPreviousKit)
        return
    end

    -- First entry of a manifest, so this is a fresh run. Sweep again before
    -- placing anything, because the clear above only runs if the client was
    -- there to receive it: a crash or a quit mid run leaves the entries behind,
    -- and this is where they get collected.
    if next(taken) == nil then
        pcall(sweepPreviousKit)
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
