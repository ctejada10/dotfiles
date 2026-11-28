-- amethyst-hud: gives each Space its Amethyst layout and shows the layout HUD.
--
-- Amethyst has no way to say which layout is on. Every layout here is a
-- custom one that writes each arrangement to Amethyst's log as
-- `amethyst-hud {"layout":…,"x":…,"y":…,"w":…,"h":…}`, and Amethyst runs from
-- the LaunchAgent com.carlosetejada.amethyst with that log in
-- ~/Library/Logs/amethyst.log. This reads it as it grows.
--
-- Each Space has a default layout per screen: the laptop's own, or any other
-- (the Sony, always in clamshell). The first time Hammerspoon ever sees a
-- Space it sets that default, once, and records it in hs.settings; after that
-- it never presses a key for that Space again. Amethyst remembers each
-- Space's layout itself, across switches and restarts, so a layout changed by
-- hand stays. A change within a Space shows the HUD. For a moment after a
-- Space switch the log is ignored: Amethyst's lines for the old Space can
-- land after macOS already reports the new one. ⌥⌃I shows the HUD on request
-- and ⌥⌃/ restarts Amethyst with its log on.

local M = {}

-- Layouts by Space number, in Mission Control order (full-screen apps not
-- counted). Spaces past the list are left alone.
M.defaults = {
    laptop = { "center", "grid", "tall-left", "tall-left", "float" },
    external = { "center", "bsp-left", "tall-left", "tall-left", "float" },
}

-- Each layout's select key in ~/.amethyst.yml, with ⌥⌃.
local MODS = { "ctrl", "alt" }
local KEYS = { center = "d", grid = "v", ["bsp-left"] = "b", ["tall-left"] = "t", float = "f" }

local LOG = os.getenv("HOME") .. "/Library/Logs/amethyst.log"
local LOG_LIMIT = 20 * 1024 * 1024
local AGENT = "com.carlosetejada.amethyst"
local HUD_NOTE = "com.carlosetejada.layout-hud.show"
local SEEDED = "amethystHud.seeded"
-- Seconds the log is ignored after a Space switch.
local SETTLE = 0.6

local log = hs.logger.new("amethystHud", "info")
local seeded = hs.settings.get(SEEDED) or {} -- "laptop:2" -> true once set
local current = {} -- space id -> the layout Amethyst last reported there
local pending = {} -- space id -> the layout just asked of Amethyst
local settleUntil = 0

local function uid()
    return hs.execute("/usr/bin/id -u"):gsub("%s+", "")
end

local function showHud(layout)
    if layout then hs.distributednotifications.post(HUD_NOTE, layout) end
end

local function profile(screen)
    return (screen:name() or ""):match("Built%-in") and "laptop" or "external"
end

local function spaceNumber(screen, spaceID)
    local number = 0
    for _, id in ipairs(hs.spaces.spacesForScreen(screen) or {}) do
        if hs.spaces.spaceType(id) == "user" then
            number = number + 1
            if id == spaceID then return number end
        end
    end
end

-- The active Space on a screen, its key in the seeded table, and its default.
local function slot(screen)
    local id = hs.spaces.activeSpaceOnScreen(screen)
    local number = id and spaceNumber(screen, id)
    if not number then return id end
    local key = profile(screen) .. ":" .. number
    return id, key, (M.defaults[profile(screen)] or {})[number]
end

local function seed(key)
    seeded[key] = true
    hs.settings.set(SEEDED, seeded)
end

-- The first version kept every layout changed by hand here. Those Spaces
-- already have Carlos's layout, so they count as set.
local OLD_STORE = "amethystHud.spaceLayouts"
local old = hs.settings.get(OLD_STORE)
if type(old) == "table" then
    for key in pairs(old) do seeded[key] = true end
    hs.settings.set(SEEDED, seeded)
    hs.settings.clear(OLD_STORE)
end

-- The screen a reported frame is on.
local function screenFor(frame)
    local cx, cy = frame.x + frame.w / 2, frame.y + frame.h / 2
    for _, screen in ipairs(hs.screen.allScreens()) do
        local f = screen:fullFrame()
        if cx >= f.x and cx < f.x + f.w and cy >= f.y and cy < f.y + f.h then return screen end
    end
    return hs.screen.mainScreen()
end

local function focusedOn(screen)
    local window = hs.window.focusedWindow()
    local on = window and window:screen()
    return on ~= nil and on:getUUID() == screen:getUUID()
end

local function onReport(report)
    if not KEYS[report.layout] then return end
    if hs.timer.secondsSinceEpoch() < settleUntil then return end
    local screen = screenFor(report)
    local id, key, want = slot(screen)
    if not id then return end
    local before = current[id]
    current[id] = report.layout

    if pending[id] then
        if report.layout == pending[id] then pending[id] = nil end
        return
    end

    if key and not seeded[key] then
        if not want or report.layout == want then
            seed(key)
        elseif focusedOn(screen) then
            -- A select key toggles back when its layout is already on, so it
            -- is pressed only when Amethyst reports another one.
            pending[id] = want
            seed(key)
            log.i(string.format("%s: %s -> %s, once", key, report.layout, want))
            hs.eventtap.keyStroke(MODS, KEYS[want], 20000)
            hs.timer.doAfter(2, function()
                if pending[id] == want then pending[id] = nil end
            end)
        end
        return
    end

    if before and report.layout ~= before then showHud(report.layout) end
end

-- Lines come in chunks that can end mid-line.
local buffer = ""
local function onOutput(_, out)
    buffer = buffer .. (out or "")
    while true do
        local line, rest = buffer:match("^(.-)\n(.*)$")
        if not line then break end
        buffer = rest
        -- Only the layouts' own lines: decoding anything else makes
        -- Hammerspoon log a JSON error for every other line of the log.
        local json = line:match("amethyst%-hud (%b{})")
        if json then
            local ok, report = pcall(hs.json.decode, json)
            if ok and type(report) == "table" then onReport(report) end
        end
    end
    return true
end

local function follow()
    if M.tail and M.tail:isRunning() then return end
    if not hs.fs.attributes(LOG) then io.open(LOG, "a"):close() end
    M.tail = hs.task.new("/usr/bin/tail", function() hs.timer.doAfter(2, follow) end, onOutput, { "-n", "0", "-F", LOG })
    M.tail:start()
end

-- Amethyst started any other way (Sparkle's relaunch, its own menu, a login
-- item) has no log, so it goes and the LaunchAgent starts it again.
local function restartAmethyst()
    hs.execute(string.format("/bin/launchctl kickstart -k gui/%s/%s", uid(), AGENT))
end

local function checkAmethyst(app)
    app = app or hs.application.get("com.amethyst.Amethyst")
    if not app then return end
    local args = hs.execute("/bin/ps -o args= -p " .. app:pid())
    if not args:find("%-%-log") then
        log.i("Amethyst is running without its log; restarting it from its LaunchAgent")
        app:kill()
        hs.timer.doAfter(1, restartAmethyst)
    end
end

M.appWatcher = hs.application.watcher.new(function(_, event, app)
    if event == hs.application.watcher.launched and app and app:bundleID() == "com.amethyst.Amethyst" then
        hs.timer.doAfter(1, function() checkAmethyst(app) end)
    end
end):start()

M.spaceWatcher = hs.spaces.watcher.new(function()
    settleUntil = hs.timer.secondsSinceEpoch() + SETTLE
end):start()

-- A screen plugged in or out: its Spaces are other Spaces.
M.screenWatcher = hs.screen.watcher.new(function()
    pending, current = {}, {}
    settleUntil = hs.timer.secondsSinceEpoch() + SETTLE
end):start()

M.trim = hs.timer.doEvery(600, function()
    local size = hs.fs.attributes(LOG, "size")
    if size and size > LOG_LIMIT then io.open(LOG, "w"):close() end
end)

M.showKey = hs.hotkey.bind(MODS, "i", function()
    local id, _, want = slot(hs.screen.mainScreen())
    showHud(id and current[id] or want)
end)
M.restartKey = hs.hotkey.bind(MODS, "/", function()
    pending, current = {}, {}
    restartAmethyst()
end)

follow()
checkAmethyst()

return M
