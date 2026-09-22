-- Space attacks the next creature in the battle list, and the run's kit is put
-- on action bar 1 so the player can see it and bind it however they like.
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

-- **The bar is wiped and restored, and that is the third model this has had.**
-- It was F1 to F6 chosen by us, which is the player's keyboard and not ours. It
-- was then first-free-slot with an `arenaKit` mark on each mapping, which read
-- well and failed in practice: a mapping that lost the mark, or that predated
-- the mark, was invisible to the clear, the next run walked past it and placed
-- a second copy, and an evening of testing left the bar holding three kits.
--
-- So the arena no longer tries to recognise its own leftovers. At prep it
-- photographs bar 1, empties it, and writes the kit into slots 1..N in the
-- order the manifest arrives. At the end of the run it empties the bar again
-- and puts the photograph back. Nothing survives a wipe, so nothing can be
-- duplicated by the next one, and the kit is on the same slots every run,
-- which is the only version a player can learn.
--
-- **Hotkeys need no handling at all**, which is worth stating because the
-- opposite is the obvious assumption. An action bar key is not stored on the
-- mapping: it lives in the hotkey set as `TriggerActionButton_<n>` against a
-- key sequence (ApiJson.updateActionBarHotkey), so it is bound to the button
-- number and not to what the button holds. Wiping mappings leaves every
-- assignment intact, and a player whose F3 fires button 3 keeps firing button 3
-- through the kit and out the other side.

-- Opcode 176 is claimed in docs/opcodes.md, and the version token has to match
-- ArenaConfig.hud.version on the server and WIRE_VERSION in
-- modules/game_arenahud/arenahud.lua. A mismatch leaves the bar untouched,
-- which is the intended failure: a bar holding the wrong thing is worse than
-- one holding nothing.
local OPCODE_KEYS = 176
-- v6 with the session loop. The manifest itself did not change shape: the
-- version is shared by every arena opcode so that one token check covers the
-- whole HUD, and the bump is opcode 172's.
local WIRE_VERSION = 'v6'

local BINDING = 'Space'

-- The first bar, which is the row along the bottom of the screen.
local ACTION_BAR = 1

-- Every button the bar has, not just the visible ones. A wipe that stopped at
-- the visible width would leave the player's own buttons off the right edge in
-- place, and the restore would then double them.
local BAR_SLOTS = 50

-- The photograph of the player's own bar, on disk rather than in memory.
--
-- In memory it would be lost to a `docker kill`, an alt-F4 or a crash inside a
-- run, and with it the player's whole arrangement, permanently. On disk the
-- restore can also run at startup, which is where a client that died mid run
-- gets its bar back. Written as JSON rather than through g_settings because an
-- actionsetting holds booleans and numbers that an OTML round trip returns as
-- strings, and `sendAutomatically` coming back as the string "true" is a slot
-- that types the spell into the chat box instead of casting it.
local SNAPSHOT_FILE = '/settings/arena-actionbar-snapshot.json'

-- How many entries of the current manifest have been written. Doubles as the
-- slot counter, since the bar is empty when the first one arrives.
local placed = 0

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

local function api()
    return modules.game_actionbar and modules.game_actionbar.ApiJson
end

local function buttonAt(slot)
    local bars = modules.game_actionbar and modules.game_actionbar.actionBars
    local bar = bars and bars[ACTION_BAR]
    if not bar or not bar.tabBar then
        return nil
    end
    return bar.tabBar:getChildById(ACTION_BAR .. '.' .. slot)
end

local function refresh(slot)
    local update = modules.game_actionbar and modules.game_actionbar.updateButton
    local button = buttonAt(slot)
    if button and update then
        update(button)
    end
end

local function copy(value)
    if type(value) ~= 'table' then
        return value
    end
    local out = {}
    for key, entry in pairs(value) do
        out[key] = copy(entry)
    end
    return out
end

local function hasSnapshot()
    return g_resources.fileExists(SNAPSHOT_FILE)
end

local function dropSnapshot()
    if hasSnapshot() then
        g_resources.deleteFile(SNAPSHOT_FILE)
    end
end

-- Photographs bar 1. An empty bar is photographed too, and the empty file is
-- the point: without it a restore cannot tell "the player had nothing" from
-- "there is nothing to put back" and would leave the kit on the bar.
local function takeSnapshot()
    local a = api()
    if not a then
        return false
    end

    local rows = {}
    for slot = 1, BAR_SLOTS do
        local mapping = a.getMapping(ACTION_BAR, slot)
        if mapping and mapping.actionsetting then
            rows[#rows + 1] = { button = slot, actionsetting = copy(mapping.actionsetting) }
        end
    end

    local ok, encoded = pcall(json.encode, rows)
    if not ok then
        g_logger.error('arena kit: could not encode the action bar snapshot, bar left alone')
        return false
    end

    if not g_resources.directoryExists('/settings/') then
        g_resources.makeDir('/settings/')
    end
    g_resources.writeFileContents(SNAPSHOT_FILE, encoded)
    g_logger.info(string.format('arena kit: bar photographed, %d button(s)', #rows))
    return true
end

local function readSnapshot()
    if not hasSnapshot() then
        return nil
    end
    local ok, decoded = pcall(function()
        return json.decode(g_resources.readFileContents(SNAPSHOT_FILE))
    end)
    if not ok or type(decoded) ~= 'table' then
        return nil
    end
    return decoded
end

local function wipeBar()
    local a = api()
    if not a then
        return 0
    end

    local removed = 0
    for slot = 1, BAR_SLOTS do
        if a.getMapping(ACTION_BAR, slot) then
            a.removeAction(ACTION_BAR, slot)
            refresh(slot)
            removed = removed + 1
        end
    end

    if a.saveData then
        a.saveData()
    end
    return removed
end

-- Rows go straight into the mapping array rather than through
-- createOrUpdateAction, because an actionsetting can carry a passive ability, a
-- special action or three multiActions and there is no upstream call that puts
-- one back whole. findMappingEntry falls back to a linear scan whenever its
-- index misses, and a wipe clears the index for every slot it touches, so an
-- appended row is found by every reader and cached on first lookup.
local function restoreBar()
    local rows = readSnapshot()
    if not rows then
        return false
    end
    local a = api()
    if not a then
        return false
    end

    wipeBar()

    local mappings = a.getMappings()
    local count = 0
    for _, row in ipairs(rows) do
        local slot = tonumber(row.button)
        if slot and row.actionsetting then
            mappings[#mappings + 1] = {
                actionBar = ACTION_BAR,
                actionButton = slot,
                actionsetting = row.actionsetting,
            }
            count = count + 1
        end
    end

    if a.saveData then
        a.saveData()
    end
    for _, row in ipairs(rows) do
        local slot = tonumber(row.button)
        if slot then
            refresh(slot)
        end
    end

    dropSnapshot()
    g_logger.info(string.format('arena kit: bar restored, %d button(s)', count))
    return true
end

local function place(slot, entry)
    local a = api()
    if not a then
        g_logger.info('arena kit: no action bar to place ' .. entry.label .. ' on')
        return false
    end

    if entry.kind == 'say' then
        -- sendAutomatically, so the slot casts rather than typing the words into
        -- the chat box and waiting for a return.
        a.createOrUpdateText(ACTION_BAR, slot, entry.payload, true)
    elseif entry.kind == 'item' then
        -- useType is the action bar's own name for it, and it has to be the
        -- name: the consumer reads UseTypes[value] from a table with string keys
        -- only, so a number falls through to plain Use and fires the item at
        -- nothing. A rune or a machete used at nothing does nothing.
        a.createOrUpdateAction(ACTION_BAR, slot, entry.useType, entry.itemId, 0)
    else
        return false
    end

    refresh(slot)
    if a.saveData then
        a.saveData()
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
-- bind carrying four fields the clear and the restore do not, so this splits
-- rather than matching a fixed shape, the way opcode 173 is handled in
-- arenahud.lua.
--
-- The key field is still on the wire and is ignored entirely. It once named a
-- binding, then it named a slot, and neither survived contact. The order
-- entries arrive in is the order they go on the bar, and which key fires them
-- is the player's business.
local function onArenaKeys(protocol, opcode, buffer)
    local parts = split(buffer, 6)
    if parts[1] ~= WIRE_VERSION then
        return
    end

    local verb = parts[2]

    -- The bar is photographed once per session, not once per message. The
    -- server sends a clear before every manifest and a champion pick sends a
    -- second one, so overwriting the photograph here would save the wiped bar
    -- and the player's own arrangement would be gone for good.
    if verb == 'clear' then
        if not hasSnapshot() then
            pcall(takeSnapshot)
        end
        placed = 0
        pcall(wipeBar)
        return
    end

    if verb == 'restore' then
        placed = 0
        pcall(restoreBar)
        return
    end

    if verb ~= 'bind' then
        return
    end

    -- A manifest whose clear never arrived, which is a dropped packet or a
    -- server that predates the verb. Photograph and wipe here rather than
    -- writing the kit over the top of whatever is on the bar, because that is
    -- the one direction that loses the player's arrangement silently.
    if placed == 0 and not hasSnapshot() then
        pcall(takeSnapshot)
        pcall(wipeBar)
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

    placed = placed + 1
    -- Wrapped, because the action bar is upstream code reached across a module
    -- boundary and a change there must not be able to break a run.
    pcall(place, placed, entry)
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

    -- A photograph still on disk at startup means the client went down inside a
    -- run and nothing ever sent the restore. Deferred a second because module
    -- load order is not guaranteed and game_actionbar has to be up first; the
    -- cost of it failing anyway is nil, since the file stays and the next run's
    -- clear will not overwrite it.
    scheduleEvent(function()
        pcall(restoreBar)
    end, 1000)
end

function terminate()
    disconnect(g_game, {
        onGameStart = bind,
        onGameEnd = unbind,
    })
    ProtocolGame.unregisterExtendedOpcode(OPCODE_KEYS)
    unbind()
end
