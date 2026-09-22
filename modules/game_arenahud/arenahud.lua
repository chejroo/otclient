-- Opcodes 170 to 175 are claimed in docs/opcodes.md. Changing one here without
-- changing that file and the server side is how a payload silently turns into
-- garbage at runtime.
local OPCODE_TICK = 170
local OPCODE_CONTROL = 171
local OPCODE_STATE = 172
-- The announcer: countdown, match start, phase change, ticker going dark,
-- result. One shot messages only, so nothing here is on a timer.
local OPCODE_MATCH = 173
-- Telegraph overlay: the tiles about to be hit, and a clear when they resolve.
local OPCODE_TELEGRAPH = 174
-- One scoring kill: where, what it was worth, and where the chain stands.
local OPCODE_KILL = 175
-- The session screen: prep, the ready rows, results and the close banner. JSON
-- rather than pipes, because it is nested and arrives a handful of times per
-- run rather than once a second.
local OPCODE_SESSION = 177
-- v5 added the cast's source to opcode 174, so a telegraph can be drawn in the
-- colour of whoever cast it, and claimed opcode 176 for the arena key manifest.
-- v4 added the opponent's score and combo to the tick. It is not the v3 that
-- docs/opcodes.md originally claimed for the race: v3 was already spent on the
-- privileged flag, and the tick pattern below ends in (.*) for the phase name,
-- so two extra fields under v3 would have printed 'Frenzy|4200|3' as the phase
-- instead of being ignored. That is exactly the mis-parse the token exists to
-- prevent, so the race got its own number.
--
-- v6 is the session loop. What spends it is opcode 172: its first field was a
-- 0 or 1 `running` flag and is now a phase name, so a v5 client reading a v6
-- server would compare 'prep' against '1', decide no run was live, and grey out
-- the panel on a run that is about to start.
local WIRE_VERSION = 'v6'

-- The server's view of where this player is in the loop: idle, prep, countdown,
-- run or results. `running` is kept as its own boolean because a dozen call
-- sites read it, and it is now exactly `phase == 'run'`.
local phaseNow = 'idle'

-- Leaving a run needs a second click on the main panel button inside this
-- window, because a misclick there is a forfeit with four minutes left on the
-- clock. The number lives here and not in `ArenaConfig.session`, because the
-- confirmation is a client side gesture: the server only ever sees the second
-- press, as a `leave` verb, so a copy on the server would be a number nothing
-- reads and it would go stale silently. `inputGuardMs` is the opposite case and
-- does travel, in the results payload, because the server decides when a result
-- may be dismissed.
--
-- Declared up here rather than beside the button, because `setIdle` clears it
-- and `setIdle` is defined several hundred lines earlier. A local declared
-- below its first use is not that local, it is a silent global.
local LEAVE_CONFIRM_MS = 3000
local leaveArmedUntil = 0

-- The session window and which screen it is showing, hoisted for the same
-- reason: `refresh` reads them to label the main panel button and is defined
-- long before the session block that owns them.
local sessionWindow
local sessionKind

-- What the one button says, by phase. Untranslated here and passed through tr()
-- at the point of use, because this table is built at file load and the
-- translation tables are not promised to be up yet.
local BUTTON_TEXT = {
    idle = 'Play',
    prep = 'Ready',
    countdown = 'Starting',
    run = 'Leave run',
    results = 'Play again',
}

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

-- Matches the 6px side margins the buttons use, so the last row does not sit
-- flush against the panel edge.
local BOTTOM_PADDING = 6

-- How long an announcer line stays on screen. A countdown tick is replaced by
-- the next one a second later, so this only really governs the last one and the
-- phase banners; a result is held until the run resets, because it is the one
-- message the player is owed a chance to read.
local BANNER_MS = 2000

local COLOR_BANNER = '#e0a33cff'
local COLOR_BANNER_WIN = '#5ac85aff'
local COLOR_BANNER_LOSS = '#e05a5aff'

-- Multiplied into the ground sprite, not painted over it, so the tile still
-- reads as forest floor while being unmistakably dangerous. A pure 'red' would
-- zero the green and blue channels and turn grass almost black, which reads as
-- a hole rather than as a warning.
-- Blue for the player's own cast, red for everything else. The two have to be
-- tellable apart at a glance: the aim rune lands where the player is looking,
-- which is often the same tile an elite is already aiming at, and a run of
-- friendly markers that reads as danger teaches the player to ignore danger.
local COLOR_TELEGRAPH_ENEMY = '#ff6464ff'
local COLOR_TELEGRAPH_SELF = '#64c8ffff'
local COLOR_TELEGRAPH_CLEAR = '#ffffffff'

-- How long after the warning window a marker clears itself if the server's own
-- clear never arrives. The server sends one on resolve, so this only fires on a
-- dropped packet or a disconnect mid-cast; without it a stuck red tile would
-- sit there until the client restarts.
local TELEGRAPH_GRACE_MS = 1000

-- How often the combo bar redraws while it drains. 50 ms is 20 fps of bar,
-- which is smooth enough that the eye reads it as continuous motion, and over a
-- 4 second window it is 80 redraws of one widget. The alternative, driving it
-- off the 1 Hz tick, would step the bar in visible quarters and start it up to
-- a second late.
local COMBO_BAR_STEP_MS = 50

-- Sound. One switch: false here and the arena is exactly as quiet as it was
-- before, with no other edit. The cues exist because in-game sound is dead in
-- this client: protocolgameparse.cpp reads the server's sound id off the wire
-- and throws it away, so a run makes no noise of its own. These are driven off
-- the arena's own opcodes instead, which know what happened rather than
-- guessing it from combat traffic.
local SOUND_ENABLED = true

-- The bank names every file after a hash of its contents, so a filename says
-- nothing about what is inside it. These were picked by decoding
-- data/sounds/<version>/sounds-*.dat, the protobuf bank the client already
-- parses at login, and reading each numeric sound effect id against the
-- ESoundEffectType and ENumericSoundType enums in src/protobuf/sounds.proto.
-- The id and the type in each comment is where the file came from, so a cue
-- that sounds wrong is swapped by looking up another id rather than by opening
-- 815 hashes one at a time.
--
-- gap is the shortest time between two plays of the same cue. Kills arrive as
-- fast as the player lands them and one area kill lands several in a single
-- frame, so without a floor a Frenzy chain is a stutter rather than a rhythm.
-- announcer routes the cue through one shared channel, see playCue.
local SOUND_VERSION = 1525
local SOUNDS = {
    -- 2774, type UI, 0.15s. One sharp transient and nothing else, which is what
    -- makes it usable as the sync mark two recordings are cut against, and it
    -- is short enough to live in SoundManager's decode cache rather than be
    -- streamed, so it fires on the frame it is asked for.
    countdown = {
        file = 'sound-e3e1a76bce58857fbb12d6a3d5992ac8598de8eab331109f18b9634f0a9c7196.ogg',
        gain = 0.9, announcer = true,
    },
    -- 2776, RAID_ANNOUNCEMENT, 1.29s. The loudest one shot in the bank that is
    -- not a spell, and the start of a run is the moment worth being loud at.
    start = {
        file = 'sound-736ee6347dfa7d9842f634c3ab7396a3b0dcd20c62a920e8a51728689b515801.ogg',
        gain = 1.0, announcer = true,
    },
    -- 2777, SERVER_MESSAGE, 0.88s. Pitched per phase, see PHASE_PITCH.
    phase = {
        file = 'sound-34716e6c2af276297f44c84c7646ad311e53fb6deafb8243fccfb3823510447e.ogg',
        gain = 0.9, announcer = true,
    },
    -- 2855, UI, 0.49s, played low. The ticker going dark is a rule being
    -- applied and not a reward, and a cue that falls is how that reads.
    dark = {
        file = 'sound-eefd93cf62b4803eb13295c057ca55805f707e5992c234eaaf67a6c0f8f3a091.ogg',
        gain = 0.9, announcer = true,
    },
    -- 2770 and 2772, both EVENT, 5.2s and 4.2s. Long on purpose: the result
    -- banner is held until the next run resets the panel, so the sound is held
    -- with it rather than ending before the player has read the score.
    resultWin = {
        file = 'sound-04759ce073034b5d97f546a7783c98b1de2d8e5492971e55058abe3708939298.ogg',
        gain = 1.0, announcer = true,
    },
    resultLoss = {
        file = 'sound-b3680c4d3a83a483ffa89dabe36bde2b245496b30c91f89e7f10c63bdc902da0.ogg',
        gain = 1.0, announcer = true,
    },
    -- 2854, UI, 0.34s, pitched by the chain, see KILL_PITCH_STEP.
    kill = {
        file = 'sound-ffc4150fd6555f3034b512acd9aa917a561876174c25ca2068a0876018dede33.ogg',
        gain = 0.55, gap = 140,
    },
    -- 1022 SpellEnergyBeam and 1018 SpellExplosionRune: the player's own cast
    -- and its landing. Quiet, because standing in the aim rune costs the player
    -- nothing and the ear should not be told otherwise. Energy for the cast
    -- because the marker it goes with is drawn blue.
    castSelf = {
        file = 'sound-9e3d4afba9d90aa55468573a7f4500840473502e6c60e136794ef17dd79f9b7d.ogg',
        gain = 0.45, gap = 180,
    },
    hitSelf = {
        file = 'sound-fb9d2d867a43c8a0b69198c9b021d4e2977f316975df65d7ee2d1768ff5a2c7d.ogg',
        gain = 0.45, gap = 180,
    },
    -- 2032 MonsterSpellLargeAreaDeath at 1.17s and 1062 SpellAnnihilation at
    -- 0.87s. Both fit inside the 1500 ms warning window, which a longer sample
    -- would not: a warning still playing after the tile has gone off teaches
    -- the wrong timing. Loud, because this is the shot that costs health.
    castEnemy = {
        file = 'sound-5482fa51dabbb3387cfa711e75c02a5a4baeb775d06bd8629e1b7024b7148588.ogg',
        gain = 1.0, gap = 180,
    },
    hitEnemy = {
        file = 'sound-0a759c7c486d5bb4c495d6f2171bd9482c945c4c19c42b949b924725219b1e63.ogg',
        gain = 0.8, gap = 180,
    },
}

-- Frenzy is the same announcement played higher. Brief section 6 makes it the
-- phase where spawn rate and exp both double, and a cue that rises says so
-- without a second file. Keyed by the server's own phase names from
-- ArenaConfig.run.phases; a phase not listed here keeps the neutral pitch.
local PHASE_PITCH = { Elites = 1.0, Frenzy = 1.2 }

-- The kill cue climbs one step per chained kill and stops at 1.6, about eight
-- semitones over the opening kill. One sample the whole way up, because
-- SoundManager::play takes a pitch per call.
local KILL_PITCH_STEP = 0.05
local KILL_PITCH_MAX = 1.6

-- Every static text the arena drew this run carries this as its speaker name.
-- Map::addStaticText merges a new message into a live label only when the
-- position, the name and the mode all match, so a fixed name is what makes two
-- kills on one tile stack into two lines instead of drawing on top of each
-- other. A player's own name here would merge our labels with their chat.
local KILL_TEXT_NAME = 'arena'

-- StaticText::compose picks the colour from the mode and re-runs on every
-- message, so setColor is overwritten by the next kill that lands on the same
-- tile. Spell is the mode whose branch sets a readable orange and, unlike Say
-- or Yell, does not prefix the speaker's name. MessageModes.None falls through
-- to compose's final else and logs 'Unknown speak type' once per kill.
local KILL_TEXT_MODE = MessageModes.Spell

-- Imported at file scope, not in onInit: Controller:init() loads the UI before
-- it calls onInit, so a style registered there would arrive too late.
g_ui.importStyle('arenabutton')

arenaHudController = Controller:new()
arenaHudController:setUI('arenahud', modules.game_interface.getMainRightPanel())

local lastTickAt = nil
local running = false
local probing = false
local privileged = false
-- Set by a race result and cleared on the first tick of the next run. It exists
-- so the summary that follows every run end does not paint over the one message
-- that says who won. Declared up here with the other state rather than next to
-- the handler that sets it, because the tick handler clears it and runs first in
-- this file: a local declared below its use is a different variable, silently.
local resultHeld = false
local arenaButton = nil
local bannerEvent = nil

-- Live telegraph overlays, keyed by the server's telegraph id. Each entry holds
-- its source and the ground Things that were tinted, so the clear restores
-- exactly what was changed rather than recomputing tiles from positions that
-- may since have scrolled out of view.
local telegraphs = {}

-- Which live shots cover each tile: coverage[key][telegraphId] is the ground
-- Thing that shot tinted there. Keyed by an 'x,y,z' string and not by the
-- ground itself, because LuaInterface::pushObject hands out a fresh userdata on
-- every push, so two reads of the same ground are two different table keys.
local coverage = {}

-- Enemy outranks self when two live shots share a tile. A missed hostile
-- telegraph costs health and a missed friendly one costs nothing, so on a
-- contested tile the hostile colour is the one that has to survive.
local TELEGRAPH_SOURCES = {
    enemy = { color = COLOR_TELEGRAPH_ENEMY, rank = 2, cast = 'castEnemy', hit = 'hitEnemy' },
    self = { color = COLOR_TELEGRAPH_SELF, rank = 1, cast = 'castSelf', hit = 'hitSelf' },
}

-- Developer controls. An ordinary player has no business seeing a button that
-- spawns a 900 hp monster or rebuilds the map, so these are hidden unless the
-- server says the account is a gamemaster. Hiding is presentation only: the
-- server refuses these verbs on its own, because a client can always be
-- modified to draw a button it was told not to.
local DEV_ONLY = {
    -- Stop ends somebody's run and stayed gamemaster only when the player verbs
    -- were ungated, so for an ordinary account it was a button that is drawn and
    -- always refused. The player's own way out is the main panel button, which
    -- reads "Leave run" and asks for a second click. Start and Status are
    -- deliberately not in this list: both verbs are ungated now, so both work.
    stopButton = true,
    probeButton = true,
    simButton = true,
    telegraphButton = true,
    eliteButton = true,
    aimButton = true,
    mapCaption = true,
    mapcheckButton = true,
    mapscanButton = true,
    mapclearButton = true,
    gotoButton = true,
    backButton = true,
    homeButton = true,
}

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

-- Cue plumbing. Everything here degrades to silence: a client built without
-- sound, audio switched off in the options, a bank that was never installed,
-- all of it ends with the HUD behaving exactly as it does today, because a cue
-- is decoration on a panel whose numbers are the point.
local lastCueAt = {}
local announcerChannel = nil

-- Resolved once per cue and remembered on the entry. fileExists is a PHYSFS
-- stat and the kill cue runs several times a second, so checking on every play
-- would pay for the same answer all run. A file the client does not have is
-- marked dead and never looked at again.
local function soundPath(snd)
    if snd.path then
        return snd.path
    end
    if snd.missing then
        return nil
    end

    -- The version folder is the one game_things hands to loadClientFiles, so
    -- the cues follow the installed assets rather than being pinned to the 1525
    -- bank these ids were read out of.
    local version = g_game.getClientVersion()
    if not version or version < 1 then
        version = SOUND_VERSION
    end

    local path = string.format('/data/sounds/%d/%s', version, snd.file)
    local ok, exists = pcall(g_resources.fileExists, path)
    if not ok or not exists then
        -- Said out loud once, and only once, because the flag is permanent for
        -- the life of the process. A cue that resolves to nothing is silent
        -- with nothing to distinguish it from a cue that simply has no sound,
        -- and the whole reason this layer exists is that in-game sound was
        -- broken for weeks without anyone being told.
        g_logger.info(string.format(
            'arena hud: no sound at %s (%s), that cue is off for this session',
            path, ok and 'not present' or 'resources not ready'))
        snd.missing = true
        return nil
    end

    snd.path = path
    -- Decoded and held in memory when it fits SoundManager's 100 KB cache,
    -- which is every cue under about half a second of 44 kHz stereo. Anything
    -- larger is streamed and starts on the next 100 ms sound poll instead,
    -- which is late for a countdown two recordings are aligned against.
    pcall(g_sounds.preload, path)
    return path
end

-- On game start rather than on the first cue, so the decode happens while the
-- player is looking at a loading screen instead of inside the tick that starts
-- a run.
local function primeSounds()
    if not SOUND_ENABLED or not g_sounds then
        return
    end

    for _, snd in pairs(SOUNDS) do
        soundPath(snd)
    end
end

local function playCue(name, pitch)
    if not SOUND_ENABLED or not g_sounds then
        return
    end

    local snd = SOUNDS[name]
    if not snd then
        return
    end

    local now = g_clock.millis()
    if snd.gap and lastCueAt[name] and now - lastCueAt[name] < snd.gap then
        return
    end

    local path = soundPath(snd)
    if not path then
        return
    end

    lastCueAt[name] = now

    -- Announcer cues share SoundChannels.Effect, whose play() stops whatever it
    -- was playing first, so a result cuts off the phase banner still sounding
    -- under it. Kill and telegraph cues go straight to the mixer instead: they
    -- have to overlap, and on a channel every kill would silence the warning
    -- the player is standing in.
    if snd.announcer then
        if announcerChannel == nil then
            local ok, channel = pcall(g_sounds.getChannel, SoundChannels.Effect)
            announcerChannel = ok and channel or false
        end
        if announcerChannel then
            pcall(announcerChannel.play, announcerChannel, path, 0, snd.gain or 1, pitch or 1)
            return
        end
    end

    pcall(g_sounds.play, path, 0, snd.gain or 1, pitch or 1)
end

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

    for id in pairs(DEV_ONLY) do
        local widget = ui[id]
        if widget then
            widget:setVisible(privileged)
        end
    end

    for id, allowed in pairs(RULES) do
        local button = ui[id]
        if button then
            button:setEnabled(allowed())
        end
    end

    -- The panel is anchored top down, so hiding a widget leaves its row behind
    -- as empty space unless the height is recomputed. Measured from the children
    -- rather than written down as two constants: every previous attempt to size
    -- this panel by eye was wrong, and a measured height also stays correct when
    -- a button is added later.
    --
    -- Deferred by one frame because setVisible above does not re-run the anchor
    -- layout synchronously, so reading getY() here would return the positions
    -- from before the change.
    addEvent(function()
        local panel = arenaHudController.ui
        if not panel then
            return
        end

        local top = panel:getY()
        local bottom = top
        for _, child in ipairs(panel:getChildren()) do
            -- Children that fill the parent are skipped, and without this the
            -- measurement could only ever grow. PhantomMiniWindow's first child
            -- is a background widget with anchors.fill: parent, so its bottom
            -- edge IS the panel's bottom edge by definition: the loop always
            -- measured at least the current height, the twelve hidden dev rows
            -- never collapsed, and the panel crept a padding's worth taller on
            -- every refresh until game_mainpanel snapped it back.
            if child:isVisible() and child:getHeight() < panel:getHeight() then
                local edge = child:getY() + child:getHeight()
                if edge > bottom then
                    bottom = edge
                end
            end
        end

        if bottom > top then
            local height = bottom - top + BOTTOM_PADDING
            panel:setHeight(height)
            -- And the field the main panel actually reads, which setHeight does
            -- not touch. game_mainpanel's reloadMainPanelSizes walks every child
            -- of the right panel and does `panel:setHeight(panel.panelHeight)`,
            -- so leaving this at the OTUI's 382 meant every recalculation blew
            -- the panel straight back up and reserved 382 px of column for it.
            -- That happens on its own 50 ms after game start, which lands after
            -- the deferred measurement here, and again on any options toggle or
            -- mini window open. For a plain player the twelve hidden gamemaster
            -- rows are about 300 px of that, so the symptom was a panel that
            -- measured itself correctly once and then went back to mostly empty.
            panel.panelHeight = height
        end
    end)

    -- The label follows the phase, not `running`, so there is always exactly one
    -- obvious thing to press and it says what pressing it does. It read
    -- "Start run" through prep, countdown and results, while the click
    -- dispatched to lock in, to nothing, and to play again, which is three
    -- different lies from one label.
    --
    -- COUNTDOWN is the one state with nothing to press, so the button is
    -- disabled rather than left looking live.
    if arenaButton then
        local label = tr(BUTTON_TEXT[phaseNow] or 'Play')
        if sessionKind and sessionWindow and not sessionWindow:isVisible() then
            label = tr('Show arena')
        end
        arenaButton:setText(label)
        arenaButton:setOn(running)
        arenaButton:setEnabled(phaseNow ~= 'countdown')
    end
end

-- Paints one tile the colour of the highest ranked shot still covering it, and
-- only blanks it when none is left. g_map.colorizeThing sets a single scalar
-- colour on the ground with no stack and no refcount, so a clear that blanked
-- unconditionally would white out a tile a second live shot still has armed:
-- the player would read a tile that is about to hit them as safe.
--
-- `fallback` is the ground handle to restore when nothing covers the tile any
-- more, which is the handle of the shot that just went away.
local function repaintTile(key, fallback)
    local at = coverage[key]
    local winner, winnerGround

    if at then
        for id, ground in pairs(at) do
            local shot = telegraphs[id]
            local source = shot and TELEGRAPH_SOURCES[shot.source]
            if source and (not winner or source.rank > winner.rank) then
                winner = source
                winnerGround = ground
            end
        end
        if not next(at) then
            coverage[key] = nil
        end
    end

    if winner then
        g_map.colorizeThing(winnerGround, winner.color)
    elseif fallback then
        -- Restored to white rather than through g_map.removeThingColor, which
        -- sets Color::alpha and then fails the client's own canDraw test, so the
        -- ground stops being drawn at all. A red tile is a bug; a hole in the
        -- floor where the tile used to be is a much better looking bug and a
        -- much worse one.
        g_map.colorizeThing(fallback, COLOR_TELEGRAPH_CLEAR)
    end
end

-- Restores every tile one telegraph tinted. Safe to call twice: the entry is
-- dropped first, so the server's clear and the grace timer cannot fight.
local function clearTelegraph(id)
    local shot = telegraphs[id]
    if not shot then
        return
    end
    telegraphs[id] = nil

    if shot.timer then
        removeEvent(shot.timer)
    end

    for _, marked in ipairs(shot.tiles) do
        local at = coverage[marked.key]
        if at then
            at[id] = nil
        end
        repaintTile(marked.key, marked.ground)
    end
end

local function clearAllTelegraphs()
    for id in pairs(telegraphs) do
        clearTelegraph(id)
    end
end

-- The live combo window. `endsAt` is a client clock reading rather than a
-- countdown, so a dropped or delayed frame costs nothing: every step recomputes
-- from the clock instead of subtracting its own interval.
local comboBar = { event = nil, endsAt = nil, window = 0 }

local function stopComboBar()
    if comboBar.event then
        removeEvent(comboBar.event)
        comboBar.event = nil
    end
    comboBar.endsAt = nil

    local ui = arenaHudController.ui
    if ui and ui.comboBar then
        -- Hidden, not emptied. updateBackground floors the fill at one pixel,
        -- so an empty bar still draws a sliver and reads as a chain with a
        -- moment left on it.
        ui.comboBar:setVisible(false)
    end
end

local function stepComboBar()
    comboBar.event = nil

    local ui = arenaHudController.ui
    if not ui or not ui.comboBar or not comboBar.endsAt then
        return
    end

    local left = comboBar.endsAt - g_clock.millis()
    if left <= 0 then
        stopComboBar()
        return
    end

    ui.comboBar:setPercent(left / comboBar.window * 100)
    comboBar.event = scheduleEvent(stepComboBar, COMBO_BAR_STEP_MS)
end

-- Restarts the window on every kill, which is what the server does: run.lua
-- compares against lastGainAt, so a kill inside the window extends the chain and
-- resets the clock rather than spending what is left of it.
local function kickComboBar(windowMs)
    local ui = arenaHudController.ui
    if not ui or not ui.comboBar or windowMs <= 0 then
        return
    end

    comboBar.window = windowMs
    comboBar.endsAt = g_clock.millis() + windowMs
    ui.comboBar:setPercent(100)
    ui.comboBar:setVisible(true)

    if not comboBar.event then
        comboBar.event = scheduleEvent(stepComboBar, COMBO_BAR_STEP_MS)
    end
end

-- The multiplier is shown only once it is above 1.00x, the same rule the
-- server's fallback status message uses. A chain of one is worth exactly 1.00x
-- by ArenaScore.multiplier, so printing `x1.0` on every opening kill would put
-- the number on screen most often at the one moment it means nothing.
local function floatKillText(position, points, mult)
    local label
    if mult > 100 then
        label = string.format('+%d  x%.1f', points, mult / 100)
    else
        label = string.format('+%d', points)
    end

    local text = StaticText.create()
    -- addMessage rather than setText: expiry is scheduled inside addMessage,
    -- and g_map.removeStaticText is not bound to Lua, so a label built with
    -- setText alone would sit on the floor until the client restarts. Sixty
    -- kills a run makes that sixty permanent labels.
    if text:addMessage(KILL_TEXT_NAME, KILL_TEXT_MODE, label) then
        g_map.addStaticText(text, position)
    end
end

-- Opcode 175. One scoring kill, sent only to the player who earned it.
local function onArenaKill(protocol, opcode, buffer)
    local version, x, y, z, points, mult, combo, windowMs =
        buffer:match('^([^|]*)|(%-?%d+),(%-?%d+),(%-?%d+)|([^|]*)|([^|]*)|([^|]*)|(.*)$')

    if version ~= WIRE_VERSION then
        return
    end

    points = tonumber(points)
    mult = tonumber(mult)
    combo = tonumber(combo)
    windowMs = tonumber(windowMs)
    if not points or not mult or not combo or not windowMs then
        return
    end

    floatKillText({ x = tonumber(x), y = tonumber(y), z = tonumber(z) }, points, mult)
    kickComboBar(windowMs)

    -- The chain is the skill axis brief section 4 is built around, so it is the
    -- one number the ear should be able to follow without looking at the panel.
    playCue('kill', math.min(1 + (math.max(combo, 1) - 1) * KILL_PITCH_STEP, KILL_PITCH_MAX))

    -- The same two fields the tick carries, written here as well so the number
    -- and the bar under it agree. Left to the tick alone the label would sit up
    -- to a second behind a bar that restarted on the kill, which reads as the
    -- bar being wrong rather than as the label being slow.
    local ui = arenaHudController.ui
    if ui then
        ui.combo:setText(string.format('x%d = %.2fx', combo, mult / 100))
        ui.combo:setColor(mult > 100 and COLOR_COMBO_HOT or COLOR_COMBO_IDLE)
    end
end

-- Opcode 174. The server marks these tiles with a pulsed effect as well, which
-- is what a player on the official client or without this module sees. The
-- pulse is an animation that has to be redrawn six times across the window and
-- is briefly absent between redraws; brief section 4 makes reading the ground
-- the top skill axis, so a marker that blinks is not a cosmetic problem.
--
-- The ground sprite is tinted rather than the tile filled. Tile:setFill draws a
-- solid rect and returns before the tile's own contents are drawn, so it would
-- hide the ground, the items and every creature standing there, including the
-- player being asked to step off. Tinting multiplies into the ground sprite and
-- leaves everyone visible.
local function onArenaTelegraph(protocol, opcode, buffer)
    local version, id, warnMs, source, tiles =
        buffer:match('^([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$')

    if version ~= WIRE_VERSION then
        return
    end

    id = tonumber(id)
    warnMs = tonumber(warnMs)
    if not id or not warnMs then
        return
    end

    -- Anything the server did not name is hostile. The failure worth guarding
    -- against is a monster's cast drawn in the player's own colour, not the
    -- other way round.
    if not TELEGRAPH_SOURCES[source] then
        source = 'enemy'
    end

    -- A zero window is the resolve message, not a telegraph with no warning.
    if warnMs == 0 then
        -- Read before the clear, because the live entry is what says whose shot
        -- this was. A shot whose tiles were all off screen never got an entry
        -- and deliberately lands silently: it is not on the player's floor.
        local shot = telegraphs[id]
        local cues = shot and TELEGRAPH_SOURCES[shot.source]
        if cues then
            playCue(cues.hit)
        end
        clearTelegraph(id)
        return
    end

    clearTelegraph(id)

    local marked = {}
    for x, y, z in tiles:gmatch('(%-?%d+),(%-?%d+),(%-?%d+)') do
        local tile = g_map.getTile({ x = tonumber(x), y = tonumber(y), z = tonumber(z) })
        -- nil for a tile outside the viewport, which is normal rather than an
        -- error: the server sends the whole shape and the client draws the part
        -- of it that is on screen.
        local ground = tile and tile:getGround()
        if ground then
            local key = x .. ',' .. y .. ',' .. z
            marked[#marked + 1] = { key = key, ground = ground }

            local at = coverage[key]
            if not at then
                at = {}
                coverage[key] = at
            end
            at[id] = ground
        end
    end

    if #marked == 0 then
        return
    end

    telegraphs[id] = { tiles = marked, source = source }

    -- Painted after the entry exists, because repaintTile decides a shared
    -- tile's colour by reading the live shots that cover it, and this one has
    -- to be among them.
    for _, tile in ipairs(marked) do
        repaintTile(tile.key)
    end

    -- After the early return above, so a shape drawn nowhere makes no sound,
    -- which keeps the warning and its impact paired.
    playCue(TELEGRAPH_SOURCES[source].cast)

    -- The server clears on resolve. This only fires if that message never
    -- arrives, which is a dropped packet or a disconnect mid-cast. Without it a
    -- red tile stays red until the client restarts.
    telegraphs[id].timer = scheduleEvent(function()
        local shot = telegraphs[id]
        if shot then
            shot.timer = nil
            clearTelegraph(id)
        end
    end, warnMs + TELEGRAPH_GRACE_MS)
end

-- `hold` nil means the line stays until something replaces it, which is what a
-- result wants. Everything else clears itself, so a phase banner does not sit
-- over the rest of the run.
local function banner(text, color, hold)
    if bannerEvent then
        removeEvent(bannerEvent)
        bannerEvent = nil
    end

    local ui = arenaHudController.ui
    if not ui then
        return
    end

    ui.banner:setText(text or '')
    ui.banner:setColor(color or COLOR_BANNER)

    if text and text ~= '' and hold then
        bannerEvent = scheduleEvent(function()
            bannerEvent = nil
            local panel = arenaHudController.ui
            if panel then
                panel.banner:setText('')
            end
        end, hold)
    end
end

-- Everything a finished run leaves running, taken down. Split out from setIdle
-- because the two ways a run ends want different halves of it.
--
-- A run that ends between a telegraph's cast and its resolve would otherwise
-- leave that shape tinted on the floor, and the clear for it is never coming,
-- because the run it belonged to is over. Same for a combo bar draining towards
-- a window whose kills can no longer be extended.
local function stopRunEffects()
    lastTickAt = nil
    clearAllTelegraphs()
    stopComboBar()
end

local function setIdle()
    running = false
    -- **The phase goes with it.** setIdle is also the belt to opcode 172's
    -- braces: the 1 Hz check calls it when ticks stop, which is precisely the
    -- case where the 172 push was lost. Leaving phaseNow at 'run' there left the
    -- panel reading IDLE while the main button still dispatched into the leave
    -- branch, so pressing it asked the player to confirm a forfeit of a run that
    -- had already ended, and the second press sent a `leave` the server refused.
    -- The button could then never send `start` again until some later 172
    -- arrived.
    phaseNow = 'idle'
    -- And the arm goes with it, or a confirmation from the run that just ended
    -- is still live three seconds into the next state.
    leaveArmedUntil = 0
    stopRunEffects()

    local ui = arenaHudController.ui
    if ui then
        ui.clock:setText('0:00')
        ui.clock:setColor(COLOR_CLOCK)
        ui.phase:setText('-')
        ui.score:setText('0')
        ui.combo:setText('x0 = 1.00x')
        ui.combo:setColor(COLOR_COMBO_IDLE)
        ui.opp:setText('-')
        ui.link:setText(tr('no run'))
    end
    refresh()
end

-- The tick payload is pipe delimited rather than JSON because Canary has no Lua
-- JSON encoder. See "Payload convention" in docs/opcodes.md.
local function onArenaTick(protocol, opcode, buffer)
    local version, seq, timeLeft, exp, combo, mult, phase, oppExp, oppCombo =
        buffer:match('^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$')

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
    -- -1 for both when there is no opponent, and -1 for the score again during
    -- the dark last minute. A solo run and a race carry the same nine fields, so
    -- there is one parser and one panel rather than two of each.
    oppExp = tonumber(oppExp)
    oppCombo = tonumber(oppCombo)
    if not seq or not timeLeft or not exp or not combo or not mult or not oppExp or not oppCombo then
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
    -- A probe is not a run, and this is the only place that decides. ArenaHud.push
    -- sends opcode 170 for probe ticks too, so an unguarded `running = true`
    -- here made the Stop button live for the whole of a 200 second probe, where
    -- pressing it answers "You are not in a run." It also wiped a result banner
    -- the player might still have been reading, because a probe's second tick
    -- ran the reset below.
    if not running and not probing then
        running = true
        -- Clears the previous match's result, which is deliberately held with no
        -- timeout. Cleared here rather than on run start because this is the
        -- first moment the client knows a new run exists.
        banner('')
        -- And the flag that held it. It used to be cleared only by the
        -- countdown verb, which only a race sends, so after one race every
        -- solo run that followed was silently denied its summary banner
        -- forever. Every run sends ticks; not every run sends a countdown.
        resultHeld = false
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
        -- The rival row is the whole reason the race exists: a number you are
        -- behind is what makes the last two minutes worth playing hard. It says
        -- so in points rather than as a gap, because a gap of 300 reads the same
        -- at 400 to 700 as at 4400 to 4700 and those are different races.
        if oppCombo < 0 then
            ui.opp:setText('-')
            ui.opp:setColor(COLOR_COMBO_IDLE)
        else
            ui.opp:setText(string.format('%s  x%d', oppExp < 0 and '???' or groupDigits(oppExp), oppCombo))
            ui.opp:setColor(exp >= 0 and oppExp >= 0 and exp >= oppExp and COLOR_COMBO_HOT or COLOR_COMBO_IDLE)
        end
        -- tr is string.format (corelib/util.lua), so the arguments go to tr
        -- itself. Wrapping it in another string.format leaves tr with format
        -- specifiers and no values, which throws.
        ui.link:setText(tr('tick %d, gap %dms', seq, gap))
    end

end

-- The announcer channel. Fields after the verb differ per verb, so this splits
-- rather than matching a fixed shape: a countdown carries one number and a
-- result carries three, and forcing them into one pattern would mean padding
-- every message to the longest one.
local function onArenaMatch(protocol, opcode, buffer)
    -- Split on the delimiter keeping empty fields. `gmatch('[^|]+')` needs at
    -- least one character per field, so an empty one is not captured: it
    -- vanishes and every field after it moves up an index, silently. Nothing
    -- the server sends today can be empty, because ArenaHud.event tostrings its
    -- arguments and Tibia names are never blank, so this was one nil argument
    -- away from a result banner reading a plausible wrong score rather than an
    -- obviously broken one. The other four handlers already use anchored
    -- `([^|]*)` patterns and were never exposed to it.
    local parts = {}
    local from = 1
    while true do
        local at = buffer:find('|', from, true)
        if not at then
            parts[#parts + 1] = buffer:sub(from)
            break
        end
        parts[#parts + 1] = buffer:sub(from, at - 1)
        from = at + 1
    end

    if parts[1] ~= WIRE_VERSION then
        return
    end

    local verb = parts[2]
    if verb == 'countdown' then
        -- Cleared here rather than at run end, because it has to survive the
        -- summary that lands straight after a result. Every race opens with a
        -- countdown, so this is the one point that is always before the next
        -- result and always after the last one.
        resultHeld = false
        banner(tr('%s...', parts[3] or ''), COLOR_BANNER, BANNER_MS)
        playCue('countdown')
    elseif verb == 'start' then
        -- Timed out like the rest, not held. The comment here used to claim it
        -- was held because this is the sync mark every recording is cut
        -- against, which was never what the code did. Two seconds at 60 fps is
        -- 120 frames of it, so the sync mark is in no danger; holding it would
        -- instead mean HUNT sitting over the first minute of the run.
        banner(tr('HUNT  vs %s', parts[3] or '?'), COLOR_BANNER_WIN, BANNER_MS)
        playCue('start')
    elseif verb == 'phase' then
        banner(string.upper(parts[3] or ''), COLOR_BANNER, BANNER_MS)
        playCue('phase', PHASE_PITCH[parts[3] or ''])
    elseif verb == 'dark' then
        banner(tr('SCORE HIDDEN'), COLOR_BANNER, BANNER_MS)
        playCue('dark')
    elseif verb == 'result' then
        local outcome = parts[3] or 'draw'
        local mine = tonumber(parts[4]) or 0
        local theirs = tonumber(parts[5]) or 0
        local word = outcome == 'win' and tr('YOU WIN')
            or outcome == 'loss' and tr('YOU LOSE')
            or outcome == 'forfeit' and tr('FORFEIT')
            or tr('DRAW')
        -- No hold: the result stays until the next run resets the panel. It is
        -- the one line the player is owed a chance to read, and a run that ends
        -- while they are reading their own score would otherwise blank it.
        banner(string.format('%s  %s - %s', word, groupDigits(mine), groupDigits(theirs)),
            outcome == 'win' and COLOR_BANNER_WIN or outcome == 'loss' and COLOR_BANNER_LOSS or COLOR_BANNER)
        -- A draw and a forfeit take the same cue as a loss. All three are the
        -- run ending as something other than the thing it was played for.
        playCue(outcome == 'win' and 'resultWin' or 'resultLoss')
        resultHeld = true
    elseif verb == 'summary' then
        local score = tonumber(parts[3]) or 0
        local kills = tonumber(parts[4]) or 0
        local avgCombo = (tonumber(parts[5]) or 0) / 100
        local dodged = tonumber(parts[6]) or 0
        local warned = tonumber(parts[7]) or 0

        -- The score row first, because that is where the player is already
        -- looking and it has been showing ??? since the ticker went dark.
        --
        -- tr IS string.format, so its arguments go to tr itself. Wrapping it in
        -- another string.format leaves tr holding specifiers with no values and
        -- it throws, which is documented twenty lines above this and was written
        -- wrong here three times anyway.
        local ui = arenaHudController.ui
        if ui then
            ui.score:setText(groupDigits(score))
            ui.combo:setText(tr('avg x%.2f', avgCombo))
            ui.combo:setColor(COLOR_COMBO_IDLE)
            ui.link:setText(tr('%d kills, %d of %d dodged', kills, dodged, warned))
        end

        -- In a race the result banner has already landed and says who won,
        -- which matters more than a personal total, so the summary does not
        -- overwrite it. Solo, there is no result, and this is the only banner
        -- the run ever gets.
        if not resultHeld then
            banner(tr('%s  %d kills', groupDigits(score), kills), COLOR_BANNER_WIN)
            playCue('resultWin')
        end
    end
end

local function onArenaState(protocol, opcode, buffer)
    local version, phase, isProbing, isPrivileged =
        buffer:match('^([^|]*)|([^|]*)|([^|]*)|([^|]*)$')
    if version ~= WIRE_VERSION then
        return
    end

    local wasRunning = running
    if phase ~= phaseNow then
        -- A leave confirmation belongs to the state it was armed in. Left
        -- standing across a transition, a stray first click at the bell would
        -- still be armed three seconds into the results screen.
        leaveArmedUntil = 0
    end
    phaseNow = phase
    running = phase == 'run'
    probing = isProbing == '1'
    privileged = isPrivileged == '1'

    -- The server's state push is the normal end of a run, and it used to be the
    -- one way out that took none of the run's effects down with it: a telegraph
    -- armed at the bell stayed tinted on the floor until its own grace timer
    -- expired, and the combo bar kept draining for another window. setIdle does
    -- this too, but setIdle is not on this path and must not be, because it
    -- resets the score row and the summary that arrives one message earlier is
    -- what puts the final score there. So only the effects come down here; the
    -- labels keep the run's last values, which for a finished run is what they
    -- should read anyway.
    if wasRunning and not running then
        stopRunEffects()
    elseif not running then
        lastTickAt = nil
    end

    -- `idle` is the one phase that resets the labels, and it is new in v6. The
    -- panel used to say IDLE while the clock, the phase and the rival's score
    -- kept whatever the last tick of the previous run left behind, which reads
    -- as a run that is still going and is not.
    --
    -- Safe to do here and it was not before, because a results screen now
    -- carries the final score, so clearing the score row no longer throws away
    -- the one place it existed.
    if phase == 'idle' then
        setIdle()
    else
        refresh()
    end
end

local function send(verb)
    arenaHudController:sendExtendedOpcode(OPCODE_CONTROL, WIRE_VERSION .. '|' .. verb)
end

-- The session window, opcode 177. One window for prep and for results, because
-- they are the same shape and the difference is wording. `sessionWindow` and
-- `sessionKind` are declared at the top of the file, because `refresh` reads
-- them.
local sessionDeadline
local sessionGuardUntil = 0

local function sessionRow(style, text, color, playerName)
    if not sessionWindow then
        return
    end
    local row = g_ui.createWidget(style, sessionWindow.body)
    row:setText(text)
    if color then
        row:setColor(color)
    end
    -- Stamped on the widget, because the ready rows are updated in place and
    -- matching them back by their own text is a trap. The body also holds the
    -- rules strip, which is free server text, and the key legend, whose labels
    -- are champion names: a rules line that happens to start with a player's
    -- character name would be rewritten into a ready row. Worse, one name being
    -- a prefix of another ("Arena Red" against "Arena Red II") rewrites the
    -- longer player's row under the shorter player's name, after which the text
    -- no longer matches anything and the row can never be recovered.
    row.arenaPlayer = playerName
    return row
end

local function clearSessionBody()
    if sessionWindow then
        sessionWindow.body:destroyChildren()
    end
end

local function ensureSessionWindow()
    if sessionWindow then
        return sessionWindow
    end
    sessionWindow = g_ui.displayUI('arenasession')
    sessionWindow:hide()
    return sessionWindow
end

local function hideSession()
    sessionKind = nil
    sessionDeadline = nil
    if sessionWindow then
        clearSessionBody()
        sessionWindow:hide()
    end
end

local function refreshSessionDeadline()
    if not sessionWindow or not sessionDeadline then
        return
    end
    local left = math.max(0, math.floor((sessionDeadline - g_clock.millis()) / 1000))
    if sessionKind == 'prep' then
        sessionWindow.deadline:setText(tr('Starting in %d s unless everyone is ready', left))
    else
        sessionWindow.deadline:setText(tr('Leaving in %d s', left))
    end

    -- The results buttons are inert for a moment after the bell, so a player
    -- mashing a key cannot skip their own result. The score has been dark for
    -- the last sixty seconds, so this window is the reveal.
    local guarded = g_clock.millis() < sessionGuardUntil
    sessionWindow.primary:setEnabled(not guarded)
    sessionWindow.secondary:setEnabled(not guarded)
end

local function showPrep(data)
    local window = ensureSessionWindow()
    sessionKind = 'prep'
    sessionGuardUntil = 0
    clearSessionBody()

    window.headline:setText(data.again and tr('Another run') or tr('Get ready'))
    sessionDeadline = g_clock.millis() + (data.deadline or 0) * 1000

    -- The picker, above the rules, because choosing is the thing this window
    -- asks the player to do and reading is what they do while deciding. Drawn
    -- only when there is a choice: with one champion in the roster a card is a
    -- button that confirms what is already true.
    local roster = data.roster or {}
    local mineId
    for _, who in ipairs(data.players or {}) do
        if who.you then
            mineId = who.champion
        end
    end
    if #roster > 1 then
        sessionRow('SessionHeading', tr('Champion'))
        for _, entry in ipairs(roster) do
            local card = sessionRow('SessionPick', entry.name)
            if card then
                card:setOn(entry.id == mineId)
                card.onClick = function()
                    -- Sent even when it is already selected. The server drops a
                    -- pick that changes nothing, and one rule on the server is
                    -- better than the same rule in two places.
                    send('pick|' .. entry.id)
                end
            end
        end
    end

    sessionRow('SessionHeading', tr('The rules'))
    for _, line in ipairs(data.conditions or {}) do
        sessionRow('SessionRow', line)
    end

    -- The key legend, which nothing on screen has ever shown: arenakeys.lua
    -- sends the labels to the log only. A novice finding their keys in the
    -- first twenty seconds of Warmup is time lost for a reason that has nothing
    -- to do with skill, and it inflates the expert to novice ratio the exit
    -- test reads.
    local mine = roster[1]
    for _, entry in ipairs(roster) do
        if entry.id == mineId then
            mine = entry
        end
    end
    if mine then
        sessionRow('SessionHeading', tr('%s, on your action bar', mine.name))
        for _, key in ipairs(mine.keys or {}) do
            sessionRow('SessionRow', string.format('%s   %s', key.key, key.label))
        end
    end

    if #(data.players or {}) > 1 then
        sessionRow('SessionHeading', tr('Racing'))
        for _, who in ipairs(data.players) do
            sessionRow('SessionRow',
                string.format('%s   %s', who.name, who.ready and tr('ready') or tr('choosing')),
                who.ready and COLOR_RUNNING or COLOR_IDLE,
                who.name)
        end
    end

    window.primary:setText(tr('Ready'))
    window.secondary:setText(tr('Leave'))
    refreshSessionDeadline()
    -- Shown and raised, never focused. The window carries auto-focus: none for
    -- the reason spelled out in the .otui: focusing it takes focus off the game
    -- panel, which is where the walk keys are bound, and prep is exactly when
    -- the player wants to walk to the gate.
    window:show()
    window:raise()
end

-- Only the ready marks and the clock change, so the body is left alone rather
-- than rebuilt: rebuilding it would scroll a player who is reading the rules
-- back to the top every time the other one picks a champion.
local function updatePlayers(data)
    if sessionKind ~= 'prep' or not sessionWindow then
        return
    end
    sessionDeadline = g_clock.millis() + (data.deadline or 0) * 1000
    for _, child in ipairs(sessionWindow.body:getChildren()) do
        if child.arenaPlayer then
            for _, who in ipairs(data.players or {}) do
                if who.name == child.arenaPlayer then
                    child:setText(string.format('%s   %s', who.name, who.ready and tr('ready') or tr('choosing')))
                    child:setColor(who.ready and COLOR_RUNNING or COLOR_IDLE)
                    break
                end
            end
        end
    end
    refreshSessionDeadline()
end

local OUTCOME_TEXT = {
    solo = 'Run over',
    win = 'You win',
    loss = 'You lose',
    draw = 'Draw',
    forfeit = 'Forfeit',
}

local function showResults(data)
    local window = ensureSessionWindow()
    sessionKind = 'results'
    clearSessionBody()

    window.headline:setText(tr(OUTCOME_TEXT[data.outcome] or 'Run over'))
    sessionDeadline = g_clock.millis() + (data.hold or 0) * 1000
    sessionGuardUntil = g_clock.millis() + (data.guardMs or 0)

    for _, who in ipairs(data.players or {}) do
        sessionRow('SessionHeading', who.you and tr('You') or who.name)
        sessionRow('SessionRow', tr('Score   %s', groupDigits(who.score or 0)),
            who.you and COLOR_RUNNING or COLOR_IDLE)
        sessionRow('SessionRow', tr('Kills   %d', who.kills or 0))
        sessionRow('SessionRow', tr('Best chain   %d, average %.2f', who.bestCombo or 0, (who.avgCombo100 or 0) / 100))
        -- The telegraph line is the one brief section 4 makes the top skill
        -- axis, so it is spelled out as a rate rather than as two counts a
        -- player has to divide in their head.
        local warned = who.warned or 0
        if warned > 0 then
            sessionRow('SessionRow', tr('Dodged   %d of %d, %d%%', who.dodged or 0, warned,
                math.floor((who.dodged or 0) / warned * 100)))
        end
        sessionRow('SessionRow', tr('Went down   %d times', who.deaths or 0))
        sessionRow('SessionRow', tr('Potions left   %d', who.potionsLeft or 0))
        if who.personalBest then
            sessionRow('SessionRow', tr('Your best run yet'), COLOR_BANNER_WIN)
        end
        if (who.boardRank or 0) > 0 then
            sessionRow('SessionRow', tr('Number %d on the board', who.boardRank), COLOR_BANNER_WIN)
        end
        -- `still playing` is the opponent of a forfeiter and `none` is a side
        -- that reached results with no reason set. Neither is a run that ended
        -- early, and printing them as one would tell a racer who is winning
        -- that they quit.
        if who.reason and who.reason ~= 'finished'
            and who.reason ~= 'still playing' and who.reason ~= 'none' then
            sessionRow('SessionRow', tr('Ended early: %s', who.reason), COLOR_IDLE)
        end
    end

    window.primary:setText(tr('Play again'))
    window.secondary:setText(tr('Leave'))
    refreshSessionDeadline()
    window:show()
    window:raise()
end

local function onArenaSession(protocol, opcode, data)
    if type(data) ~= 'table' or tonumber(data.v) ~= tonumber(WIRE_VERSION:match('%d+')) then
        return
    end

    if data.kind == 'prep' then
        showPrep(data)
    elseif data.kind == 'players' then
        updatePlayers(data)
    elseif data.kind == 'results' then
        showResults(data)
    elseif data.kind == 'close' then
        hideSession()
        if data.text and data.text ~= '' then
            banner(data.text, COLOR_BANNER_WIN)
        end
    end
end

-- Called from the .otui. They are on the module table rather than local because
-- an @onClick in a style is resolved against the module, not against this file's
-- upvalues.
function onSessionPrimary()
    if sessionKind == 'prep' then
        send('lockin')
    elseif sessionKind == 'results' then
        send('again')
    end
end

function onSessionSecondary()
    -- Gated on there being a screen. A window stranded by a module reload still
    -- has live @onClick hooks pointing at the new chunk, and an ungated Leave
    -- there forfeits whatever the player happens to be doing when they click it
    -- to get rid of the thing.
    if not sessionKind then
        if sessionWindow then
            sessionWindow:hide()
        end
        return
    end
    send('leave')
end

function onSessionEscape()
    -- Escape hides the window and does not leave the session. Leaving is a
    -- forfeit in a run and a cancellation in prep, and neither is something a
    -- player should be able to do by reaching for the key that closes windows.
    if sessionWindow then
        sessionWindow:hide()
    end
end

-- The main panel button has one job per state, so there is always exactly one
-- obvious thing to press. LEAVE_CONFIRM_MS and leaveArmedUntil are declared at
-- the top of the file, because setIdle clears them.
local function onArenaButton()
    -- A window that was dismissed with Escape comes back first. Escape closing
    -- the window is the right behaviour for a key that closes windows, but
    -- without this it is a one way door: nothing else re-shows the screen, and
    -- the server only re-pushes it on the `ready` handshake at login, so a
    -- player who pressed it during prep was blind until the countdown.
    if sessionKind and sessionWindow and not sessionWindow:isVisible() then
        sessionWindow:show()
        sessionWindow:raise()
        return
    end

    if phaseNow == 'run' then
        if g_clock.millis() < leaveArmedUntil then
            leaveArmedUntil = 0
            send('leave')
        else
            leaveArmedUntil = g_clock.millis() + LEAVE_CONFIRM_MS
            modules.game_textmessage.displayGameMessage(tr('Click again to leave the run. It counts as a forfeit.'))
        end
        return
    end
    if phaseNow == 'countdown' then
        return
    end
    if phaseNow == 'results' then
        send('again')
        return
    end
    if phaseNow == 'prep' then
        send('lockin')
        return
    end
    send('start')
end

-- Registered in onInit, not in onGameStart: Controller only unregisters extended
-- opcodes in terminate(), so registering per game start would throw
-- "Opcode is already taken." on the first relog.
function arenaHudController:onInit()
    self:registerExtendedOpcode(OPCODE_TICK, onArenaTick)
    self:registerExtendedOpcode(OPCODE_STATE, onArenaState)
    self:registerExtendedOpcode(OPCODE_MATCH, onArenaMatch)
    self:registerExtendedOpcode(OPCODE_TELEGRAPH, onArenaTelegraph)
    self:registerExtendedOpcode(OPCODE_KILL, onArenaKill)

    -- Registered by hand, because Controller only tracks plain extended
    -- opcodes and unregisters those in terminate(). Without the unregister
    -- first, reloading this module throws "Opcode is already taken." and every
    -- handler above it is lost with it.
    pcall(ProtocolGame.unregisterExtendedJSONOpcode, OPCODE_SESSION)
    ProtocolGame.registerExtendedJSONOpcode(OPCODE_SESSION, onArenaSession)

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
        -- Qualified, not the bare global. game_mainpanel is sandboxed, and a
        -- sandbox env only inherits reads through __index, so a function
        -- defined there is never in ours: `if reloadMainPanelSizes then` was
        -- always false and the resize above never happened.
        if modules.game_mainpanel.reloadMainPanelSizes then
            modules.game_mainpanel.reloadMainPanelSizes()
        end
    end

    primeSounds()
    setIdle()
    self:sendExtendedOpcode(OPCODE_CONTROL, WIRE_VERSION .. '|ready')

    -- The server pushes state on every transition, but a dropped message would
    -- leave the panel claiming a run that ended. Ticks stopping is the
    -- independent signal.
    self:cycleEvent(function()
        if running and lastTickAt and g_clock.millis() - lastTickAt > IDLE_AFTER_MS then
            setIdle()
        end
        -- The prep cap and the results hold count down locally rather than
        -- being pushed once a second. The server owns both deadlines and acts
        -- on them; this is the number on screen, and one packet a second per
        -- player to redraw a label is not worth the inbound budget.
        refreshSessionDeadline()
    end, 1000, 'arenaHudIdleCheck')
end

-- Controller:terminate destroys self.ui, which is the mini panel, and
-- unregisters the plain extended opcodes it tracked. It knows nothing about the
-- session window, which is parented to the root widget, nor about opcode 177,
-- which was registered by hand. Both have to be taken down here.
--
-- Without the destroy, reloading this module strands a visible window on the
-- root widget that the new chunk has no reference to: Escape calls
-- onSessionEscape, which hides the *new* chunk's nil window and does nothing,
-- and the next prep draws a second window on top of it.
--
-- Without the unregister, unloading the module without reloading it leaves the
-- JSON callback holding the dead chunk and still handling packets. The pcall in
-- onInit covers the reload case and not this one.
function arenaHudController:onTerminate()
    if sessionWindow then
        sessionWindow:destroy()
        sessionWindow = nil
    end
    sessionKind = nil
    pcall(ProtocolGame.unregisterExtendedJSONOpcode, OPCODE_SESSION)
end

function arenaHudController:onGameEnd()
    probing = false
    privileged = false
    phaseNow = 'idle'
    leaveArmedUntil = 0
    -- Every session table on the server dies with the connection, so a window
    -- left open across a relog would offer Play again on a session that no
    -- longer exists.
    hideSession()
    -- The banner and its flag, which setIdle does not touch. A result line is
    -- deliberately held with no timeout, and the panel is never destroyed on
    -- game end: Controller:setUI runs at file scope, so dataUI.onGameStart is
    -- false and destroyUI never fires. Without this, finishing a race, logging
    -- out and logging back in left YOU WIN 4,200 - 3,900 sitting on the panel
    -- for the whole of the next session, until the next run's first tick
    -- happened to clear it. It also cancels a banner timer that would otherwise
    -- outlive the game.
    banner('')
    resultHeld = false
    setIdle()
    if arenaButton then
        arenaButton:destroy()
        arenaButton = nil
    end
end
