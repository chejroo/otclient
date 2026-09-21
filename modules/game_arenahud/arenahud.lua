-- Opcodes 170, 171 and 172 are claimed in docs/opcodes.md. Changing one here
-- without changing that file and the server side is how a payload silently
-- turns into garbage at runtime.
local OPCODE_TICK = 170
local OPCODE_CONTROL = 171
local OPCODE_STATE = 172
local WIRE_VERSION = 'v2'

-- No tick for this long means the run is over, or the server stopped talking.
-- The ticks only exist during a run, so they already carry that fact; the server
-- also pushes state on every transition, and this is the belt to that braces.
local IDLE_AFTER_MS = 3000

local COLOR_IDLE = '#808080ff'
local COLOR_RUNNING = '#5ac85aff'
local COLOR_PROBING = '#e0a33cff'
local COLOR_CLOCK = '#ffffffff'
local COLOR_CLOCK_URGENT = '#e05a5aff'
local COLOR_COMBO_IDLE = '#e0e0e0ff'
local COLOR_COMBO_HOT = '#5ac85aff'

-- Brief section 6 hides the score ticker for the final 60 seconds, so the run
-- ends on a guess. The clock going red is what tells the player that moment has
-- arrived: without it the score just turns into ??? and reads as a bug rather
-- than as the rules.
local URGENT_BELOW = 60

-- Imported at file scope, not in onInit: Controller:init() loads the UI before
-- it calls onInit, so a style registered there would arrive too late.
g_ui.importStyle('arenabutton')

arenaHudController = Controller:new()
arenaHudController:setUI('arenahud', modules.game_interface.getMainRightPanel())

local lastTickAt = nil
local running = false
local probing = false
local arenaButton = nil

-- Which buttons make sense in which state. Anything absent is always allowed.
-- Encoded here rather than as ifs scattered through the code so that adding a
-- button means adding one row.
local RULES = {
    startButton = function() return not running and not probing end,
    stopButton = function() return running end,
    statusButton = function() return running end,
    probeButton = function() return not running and not probing end,
    mapcheckButton = function() return not running and not probing end,
    mapscanButton = function() return not running end,
    -- Pure arithmetic and safe at any time, but it answers in five lines of
    -- text, which is five lines over the arena during a run.
    simButton = function() return not running end,
    mapclearButton = function() return not running end,
    gotoButton = function() return not running end,
    backButton = function() return not running end,
    homeButton = function() return not running end,
    -- Deliberately not gated. A telegraph is exactly the thing you want to fire
    -- while a run is live, to see it against real spawns.
}

local VERBS = {
    startButton = 'start',
    stopButton = 'stop',
    statusButton = 'status',
    probeButton = 'probe',
    mapcheckButton = 'mapcheck',
    mapscanButton = 'mapscan',
    mapclearButton = 'mapclear',
    gotoButton = 'goto',
    backButton = 'back',
    homeButton = 'home',
    simButton = 'sim',
    telegraphButton = 'telegraph',
    eliteButton = 'elite',
    aimButton = 'aim',
}

local function formatClock(seconds)
    return string.format('%d:%02d', math.floor(seconds / 60), seconds % 60)
end

-- Thousands separators, because a five or six digit score is the number the
-- player is actually reading and 18450 is harder to scan than 18,450.
local function groupDigits(n)
    local s = tostring(n)
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

local function refresh()
    local ui = arenaHudController.ui
    if not ui then
        return
    end

    if probing then
        ui.state:setText(tr('PROBING'))
        ui.state:setColor(COLOR_PROBING)
    elseif running then
        ui.state:setText(tr('RUNNING'))
        ui.state:setColor(COLOR_RUNNING)
    else
        ui.state:setText(tr('IDLE'))
        ui.state:setColor(COLOR_IDLE)
    end

    for id, allowed in pairs(RULES) do
        local button = ui[id]
        if button then
            button:setEnabled(allowed())
        end
    end

    if arenaButton then
        arenaButton:setText(running and tr('Stop run') or tr('Start run'))
        arenaButton:setOn(running)
    end
end

local function setIdle()
    lastTickAt = nil
    running = false

    local ui = arenaHudController.ui
    if ui then
        ui.clock:setText('0:00')
        ui.clock:setColor(COLOR_CLOCK)
        ui.phase:setText('-')
        ui.score:setText('0')
        ui.combo:setText('x0 = 1.00x')
        ui.combo:setColor(COLOR_COMBO_IDLE)
        ui.link:setText(tr('no run'))
    end
    refresh()
end

-- The tick payload is pipe delimited rather than JSON because Canary has no Lua
-- JSON encoder. See "Payload convention" in docs/opcodes.md.
local function onArenaTick(protocol, opcode, buffer)
    local version, seq, timeLeft, exp, combo, mult, phase =
        buffer:match('^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$')

    if version ~= WIRE_VERSION then
        -- An older or newer server. Ignoring the message is the whole point of
        -- the version token: a mis-parse would show the player a plausible but
        -- wrong score instead of nothing.
        return
    end

    seq = tonumber(seq)
    timeLeft = tonumber(timeLeft)
    exp = tonumber(exp)
    combo = tonumber(combo)
    -- Hundredths of a unit, so 250 means 2.50x. The wire has no float
    -- convention and an integer cannot pick up a locale's decimal comma.
    mult = tonumber(mult)
    if not seq or not timeLeft or not exp or not combo or not mult then
        return
    end

    -- Pong before touching the UI, not after. It was after, and a formatting
    -- bug in the label code aborted the handler before the pong every tick,
    -- which silently killed the round trip measurement while leaving the clock
    -- updating. Sending first means the wire keeps working whatever the panel
    -- does.
    arenaHudController:sendExtendedOpcode(OPCODE_CONTROL, WIRE_VERSION .. '|pong|' .. seq)

    local now = g_clock.millis()
    local gap = lastTickAt and (now - lastTickAt) or 0
    lastTickAt = now
    if not running then
        running = true
        refresh()
    end

    local ui = arenaHudController.ui
    if ui then
        ui.clock:setText(formatClock(timeLeft))
        ui.clock:setColor(timeLeft <= URGENT_BELOW and COLOR_CLOCK_URGENT or COLOR_CLOCK)
        ui.phase:setText(phase)
        -- Brief section 6: the server sends -1 for the last 60 seconds, when the
        -- score ticker is deliberately dark. Blank it rather than printing the
        -- sentinel.
        ui.score:setText(exp < 0 and '???' or groupDigits(exp))
        -- Count and multiplier in one label rather than two rows. They are the
        -- same fact and the panel is narrow, and the count on its own does not
        -- tell the player what chaining is actually paying them.
        ui.combo:setText(string.format('x%d = %.2fx', combo, mult / 100))
        ui.combo:setColor(mult > 100 and COLOR_COMBO_HOT or COLOR_COMBO_IDLE)
        -- tr is string.format (corelib/util.lua), so the arguments go to tr
        -- itself. Wrapping it in another string.format leaves tr with format
        -- specifiers and no values, which throws.
        ui.link:setText(tr('tick %d, gap %dms', seq, gap))
    end

end

local function onArenaState(protocol, opcode, buffer)
    local version, isRunning, isProbing = buffer:match('^([^|]*)|([^|]*)|([^|]*)$')
    if version ~= WIRE_VERSION then
        return
    end

    running = isRunning == '1'
    probing = isProbing == '1'
    if not running then
        lastTickAt = nil
    end
    refresh()
end

local function send(verb)
    arenaHudController:sendExtendedOpcode(OPCODE_CONTROL, WIRE_VERSION .. '|' .. verb)
end

local function onArenaButton()
    send(running and 'stop' or 'start')
end

-- Registered in onInit, not in onGameStart: Controller only unregisters extended
-- opcodes in terminate(), so registering per game start would throw
-- "Opcode is already taken." on the first relog.
function arenaHudController:onInit()
    self:registerExtendedOpcode(OPCODE_TICK, onArenaTick)
    self:registerExtendedOpcode(OPCODE_STATE, onArenaState)

    local ui = self.ui
    if ui then
        for id, verb in pairs(VERBS) do
            local button = ui[id]
            if button then
                button.onClick = function()
                    send(verb)
                end
            end
        end
    end

    setIdle()
end

function arenaHudController:onGameStart()
    -- Same helper the Store button used, so the arena button sits in that panel
    -- and picks up the same styling. green_large is the blank large button; the
    -- label is drawn over it by UIButton.
    -- blue_large is the blank version of the image the Store button used, so
    -- this sits in the same panel looking like it belongs rather than like a
    -- bolted-on green thing.
    --
    -- reloadMainPanelSizes is called by hand because createButton_large does
    -- not resize its panel, unlike createButton. That never mattered upstream:
    -- the Store button was created from mainpanel's own onInit, before the
    -- panel was laid out. Ours is added on game start, after, so without this
    -- the panel keeps its old height and clips the button.
    if modules.game_mainpanel and modules.game_mainpanel.addStoreButton then
        arenaButton = modules.game_mainpanel.addStoreButton('arenaRun', tr('Start or stop an arena run'),
            '/images/options/blue_large', onArenaButton, true)
        if reloadMainPanelSizes then
            reloadMainPanelSizes()
        end
    end

    setIdle()
    self:sendExtendedOpcode(OPCODE_CONTROL, WIRE_VERSION .. '|ready')

    -- The server pushes state on every transition, but a dropped message would
    -- leave the panel claiming a run that ended. Ticks stopping is the
    -- independent signal.
    self:cycleEvent(function()
        if running and lastTickAt and g_clock.millis() - lastTickAt > IDLE_AFTER_MS then
            setIdle()
        end
    end, 1000, 'arenaHudIdleCheck')
end

function arenaHudController:onGameEnd()
    probing = false
    setIdle()
    if arenaButton then
        arenaButton:destroy()
        arenaButton = nil
    end
end
