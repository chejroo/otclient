-- Space attacks the next creature in the battle list, and F1 to F6 are whatever
-- the server handed out for this run.
--
-- This lives in its own module rather than in the hotkeys manager's defaults,
-- for two reasons. loadDefautComboKeys only runs when a profile has NO saved
-- hotkeys, so a default added there never reaches anyone who has already used
-- the client. And hotkeys_manager.lua is upstream, so editing it would cost a
-- conflict on every merge from opentibiabr for one key.
--
-- Bound to the game root panel on purpose. A key bound there does not fire
-- while the chat console holds focus, which is what keeps Space typing a space
-- when the player is actually talking. With chat off, it attacks.

-- Opcode 176 is claimed in docs/opcodes.md, and the version token has to match
-- ArenaConfig.hud.version on the server and WIRE_VERSION in
-- modules/game_arenahud/arenahud.lua. A mismatch leaves the player with no
-- arena keys, which is the intended failure: keys that do the wrong thing are
-- worse than keys that do nothing.
local OPCODE_KEYS = 176
local WIRE_VERSION = 'v5'

local BINDING = 'Space'

-- Per key, not shared across the whole kit.
--
-- A shared gate looks right, since maxPacketsPerSecond is a property of the
-- connection, and is wrong in the case that matters: pressing attack and then
-- potion inside 50 ms is what a player does when something is killing them, and
-- a shared gate silently drops the second one. What the gate is actually for is
-- mashing one key, because these are bound with bindKeyDown, which fires once
-- per press and does not auto repeat. Two different keys is two packets, and 25
-- a second absorbs that.
local ACTION_MIN_GAP_MS = 50

local bound = false
-- The live manifest, keyed by the OTClient combo string. Each entry keeps the
-- closure it was bound with, because unbindKeyDown matches on the callback and
-- a fresh closure would not disconnect the old one.
local actions = {}

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

local function runAction(action)
    if not g_game.isOnline() then
        return
    end

    local now = g_clock.millis()
    if action.lastAt and now - action.lastAt < ACTION_MIN_GAP_MS then
        return
    end
    action.lastAt = now

    if action.kind == 'say' then
        g_game.talk(action.payload)
    elseif action.kind == 'item' then
        -- Guarded for the same reason as game_battle above, and called rather
        -- than reimplemented so the cursor position is resolved exactly the way
        -- the player's own hotkeys resolve it. When the cursor is off the map
        -- panel, executeHotkeyItem falls back to startUseWith, which arms the
        -- crosshair and waits for a click instead of firing.
        if modules.game_hotkeys and modules.game_hotkeys.executeHotkeyItem then
            modules.game_hotkeys.executeHotkeyItem(action.useType, action.itemId)
        end
    end
end

local function unbindAction(key)
    local action = actions[key]
    if not action then
        return
    end
    actions[key] = nil

    g_keyboard.unbindKeyDown(key, action.callback, rootWidget)
end

-- No hotkeys manager block is taken while these are live. The kit hands out
-- potions the player may already have bound themselves, and taking their own
-- bindings away for the length of a run would be a worse surprise than two keys
-- doing the same thing.
--
-- Bound on rootWidget rather than on the game root panel, unlike Space above,
-- and that is defensive rather than cosmetic. game_actionbar's unbindHotkey
-- calls g_keyboard.unbindKeyDown(hotkey, nil, gameRootPanel), and a nil callback
-- there disconnects EVERY listener for that combo on that widget. Its shipped
-- defaults include F1 and F2, so a player who touched their action bar mid run
-- would have silently lost the arena keys until the next run rebound them.
-- rootWidget is also where the hotkeys manager itself binds, so F keys behaving
-- the same way with chat focused is what a Tibia player already expects.
local function bindAction(key, action)
    -- A combo string the client does not know translates to nil, and connect()
    -- throws on a nil key rather than ignoring it, so a typo in the server's
    -- manifest would take the whole handler down with it.
    if not retranslateKeyComboDesc(key) then
        return
    end

    unbindAction(key)

    action.callback = function()
        runAction(action)
    end
    actions[key] = action
    g_keyboard.bindKeyDown(key, action.callback, rootWidget)

    g_logger.info(string.format('arena key %s: %s', key, action.label))
end

local function clearActions()
    for key in pairs(actions) do
        unbindAction(key)
    end
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

-- Opcode 176. The arena kit: which key does what for this run. The field count
-- varies by verb, a bind carrying four fields the clear does not, so this
-- splits rather than matching a fixed shape, the way opcode 173 is handled in
-- arenahud.lua.
local function onArenaKeys(protocol, opcode, buffer)
    local parts = split(buffer, 6)
    if parts[1] ~= WIRE_VERSION then
        return
    end

    local verb = parts[2]
    if verb == 'clear' then
        clearActions()
        return
    elseif verb ~= 'bind' then
        return
    end

    local key, kind, payload = parts[3], parts[4], parts[5]
    if not key or key == '' or not payload or payload == '' then
        return
    end

    local action = { kind = kind, label = parts[6] or key }
    if kind == 'say' then
        action.payload = payload
    elseif kind == 'item' then
        -- useType is the game_hotkeys USE constant the server picked: 4 uses the
        -- item at the cursor, which is the aim rune and the machete, 1 uses it
        -- on the player, which is the potions.
        local itemId, useType = payload:match('^(%d+),(%d+)$')
        action.itemId = tonumber(itemId)
        action.useType = tonumber(useType)
        if not action.itemId or not action.useType then
            return
        end
    else
        return
    end

    bindAction(key, action)
end

local function onGameEnd()
    unbind()
    clearActions()
end

function init()
    ProtocolGame.registerExtendedOpcode(OPCODE_KEYS, onArenaKeys)
    connect(g_game, {
        onGameStart = bind,
        onGameEnd = onGameEnd,
    })
    if g_game.isOnline() then
        bind()
    end
end

function terminate()
    disconnect(g_game, {
        onGameStart = bind,
        onGameEnd = onGameEnd,
    })
    ProtocolGame.unregisterExtendedOpcode(OPCODE_KEYS)
    unbind()
    clearActions()
end
