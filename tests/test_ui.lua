--[[--
Drives every hansel screen against the KOReader stubs: builds each layout, then
taps every registered target and rebuilds. Catches the class of bug that took
the filter sheet down — a layout that only explodes when you touch it.
]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
local env = Stub.install()
local UIManager = env.UIManager

-- ---------- fixtures ----------

local BOOKS = {}
local STATES = { "remote", "cached", "pinned" }
for i = 1, 20 do
    BOOKS[i] = {
        id = tostring(i),
        title = ("Book number %d with a title long enough to wrap twice over"):format(i),
        authors = { "Author " .. i, "Second Author" },
        state = STATES[(i % 3) + 1],
        file_type = (i % 2 == 0) and "epub" or "pdf",
        file_size = 1024 * 1024 * i,
        added_on = ("2026-0%d-1%dT10:00:00Z"):format((i % 9) + 1, i % 10),
        description = ("A summary that runs on for a while. "):rep(12),
        series = (i % 4 == 0) and "A Series" or nil,
        series_index = (i % 4 == 0) and i or nil,
        categories = { "theory", "editing", "craft" },
    }
end

package.loaded["lib.library"] = {
    page = function(_, page, size)
        local out = {}
        for i = 1, size do out[i] = BOOKS[((page - 1) * size + i - 1) % #BOOKS + 1] end
        return { books = out, total = 1284, offline = false }
    end,
    fetch_page = function(v, p, s) return package.loaded["lib.library"].page(v, p, s) end,
    query = function(_, page, size)
        return package.loaded["lib.library"].page("all", page, size)
    end,
    download = function() return true, "/tmp/hansel-test/book.epub" end,
    book = function(id) return BOOKS[tonumber(id)] end,
}
package.loaded["lib.covers"] = {
    cached = function() return nil end,
    fetch_visible = function() end,
    cancel = function() end,
    usage_bytes = function() return 12345 end,
}
package.loaded["lib.catalog"] = {
    get_book = function(id) return BOOKS[tonumber(id)] end,
    put = function() end,
}
package.loaded["lib.cache_map"] = {
    load = function() return { books = { ["1"] = { path = "/x", pinned = true } } } end,
    get = function() return nil end,
    local_path = function() return nil end,
    state = function(id) return BOOKS[tonumber(id)] and BOOKS[tonumber(id)].state or "remote" end,
    set_pinned = function() end,
    remove = function() end,
    continue_ids = function() return { "1", "2" } end,
    usage_bytes = function() return 800 * 1024 * 1024 end,
    free_unpinned = function() end,
    mark_opened = function() end,
    rebuild_from_disk = function() end,
}
local sync_stub_enabled = false
package.loaded["lib.progress_sync"] = {
    status = function()
        return { label = sync_stub_enabled and "On · up to date" or "Off",
            configured = sync_stub_enabled, enabled = sync_stub_enabled,
            active = sync_stub_enabled,
            actionable = true }
    end,
    set_enabled = function(enabled)
        sync_stub_enabled = enabled and true or false
        return true
    end,
}
package.loaded["ui.setup"] = {
    show = function(cb) if cb then cb() end end,
    manual = function(cb) if cb then cb() end end,
    prompt_tier2 = function(cb) if cb then cb() end end,
    account = function() end,
    test_now = function() end,
    confirm_if_needed = function() end,
}

local Settings = require("lib.settings")
Settings.load()
Settings.set("server_url", "http://grimmory.local:6060")
Settings.set("t1_username", "device")

-- ---------- helpers ----------

local checks = 0
local function ok(cond, msg)
    checks = checks + 1
    if not cond then error("FAIL: " .. tostring(msg), 2) end
end

local function collected_text(widget)
    local seen = {}
    for _, child in ipairs((widget._draw and widget._draw.owned) or {}) do
        if child.text then seen[tostring(child.text)] = true end
    end
    return seen
end

local function paint(widget, label)
    local before = env.bb.calls
    env.bb.out_of_bounds = 0
    widget:paintTo(env.bb, 0, 0)
    ok(env.bb.calls > before, label .. " painted nothing")
    ok(env.bb.out_of_bounds == 0,
        label .. " painted outside the screen: " .. tostring(env.bb.last_overflow))
end

--- Every tap target has to be on screen and big enough for a finger.
local function check_targets(widget, label)
    for i, hit in ipairs(widget._draw.hits) do
        ok(hit.x >= 0 and hit.y >= 0, label .. " target " .. i .. " starts off screen")
        ok(hit.x + hit.w <= env.Screen.getWidth(), label .. " target " .. i .. " runs off the right")
        ok(hit.y + hit.h <= env.Screen.getHeight(), label .. " target " .. i .. " runs off the bottom")
        ok(hit.w >= 40 and hit.h >= 40, label .. " target " .. i .. " is too small to tap: "
            .. hit.w .. "x" .. hit.h)
    end
end

--- Tap every registered target once. A fresh widget per tap, because plenty of
--- targets close the surface they live on.
local function tap_everything(make, label, skip)
    local probe = make()
    local count = #(probe._draw and probe._draw.hits or {})
    ok(count > 0, label .. " has no tap targets")
    check_targets(probe, label)
    UIManager:close(probe)
    for i = 1, count do
        if not (skip and skip[i]) then
            local widget = make()
            local target = widget._draw.hits[i]
            local x = target.x + math.floor(target.w / 2)
            local y = target.y + math.floor(target.h / 2)
            ok(widget._draw:hit({ x = x, y = y }) ~= nil,
                label .. " target " .. i .. " is not hit-testable")
            local done, err = pcall(target.callback)
            ok(done, label .. " target " .. i .. " raised: " .. tostring(err))
            UIManager:drain()
            if not widget._closed then
                paint(widget, label .. " after tap " .. i)
            end
            UIManager:close(widget)
        end
    end
    return count
end

-- ---------- library ----------

local Home = require("ui.home")
local home = Home:new{ plugin = { open_book = function() end } }
UIManager:drain()
paint(home, "home")
ok(#home.books > 0, "home loaded no books")
ok(home._draw ~= nil, "home has no draw list")

for _, density in ipairs({ "3x3", "4x4", "5x4" }) do
    home:set_density(density)
    UIManager:drain()
    paint(home, "home at " .. density)
    local grid = Settings.grid()
    ok(#home.books <= grid.cols * grid.rows, "page overflows the grid at " .. density)
end

-- Empty state must render too.
local saved = home.books
home.books = {}
home.total = 0
home:rebuild()
paint(home, "home empty")
home.books = saved
home:rebuild()

-- ---------- drawer ----------

local Drawer = require("ui.drawer")
local drawer = Drawer:new{ home = home }
paint(drawer, "drawer")
ok(drawer.panel and drawer.panel.w < env.Screen.getWidth(), "drawer is not a panel")
UIManager:close(drawer)
tap_everything(function() return Drawer:new{ home = home } end, "drawer")

-- ---------- filter sheet ----------

local Filter = require("ui.filter")
Filter.note_formats(BOOKS)
UIManager.stack = {}
Filter.show(home)
local sheet = UIManager.stack[#UIManager.stack]
ok(sheet ~= nil, "filter sheet did not open")
paint(sheet, "filter sheet")
ok(sheet.panel and sheet.panel.y > 0, "filter sheet is not anchored to the bottom")
ok(sheet.panel.y + sheet.panel.h == env.Screen.getHeight(), "filter sheet misses the bottom edge")
UIManager:close(sheet)
tap_everything(function()
    UIManager.stack = {}
    Filter.show(home)
    return UIManager.stack[#UIManager.stack]
end, "filter sheet")
UIManager:drain()

-- Filtering and sorting actually do something.
local Books = require("lib.books")
ok(Books.read_status(BOOKS[1]) == "unread", "read status default")
local pinned_only = Filter.apply(BOOKS, {
    device = "pinned", status = { unread = true, reading = true, finished = true },
    formats = {}, sort_key = "title", sort_dir = "asc",
})
for _, b in ipairs(pinned_only) do ok(b.state == "pinned", "device filter leaked a book") end
ok(#pinned_only > 0 and #pinned_only < #BOOKS, "device filter kept everything")

local by_title = Filter.apply(BOOKS, {
    device = "all", status = { unread = true, reading = true, finished = true },
    formats = {}, sort_key = "title", sort_dir = "asc",
})
ok(#by_title == #BOOKS, "sort dropped books")
for i = 2, #by_title do
    ok(by_title[i - 1].title:lower() <= by_title[i].title:lower(), "titles out of order")
end

local epub_only = Filter.apply(BOOKS, {
    device = "all", status = { unread = true, reading = true, finished = true },
    formats = { epub = true }, sort_key = "added", sort_dir = "desc",
})
for _, b in ipairs(epub_only) do ok(b.file_type == "epub", "format filter leaked a book") end

-- ---------- detail ----------

local Detail = require("ui.detail")
for _, state in ipairs({ "remote", "cached", "pinned" }) do
    local book = {}
    for k, v in pairs(BOOKS[4]) do book[k] = v end
    book.state = state
    local make = function()
        return Detail:new{ book = book, plugin = { open_book = function() end } }
    end
    local detail = make()
    paint(detail, "detail " .. state)
    -- Skip the action bar: READ would run the download path.
    local skip = {}
    for i, hit in ipairs(detail._draw.hits) do
        if hit.y > env.Screen.getHeight() * 0.9 then skip[i] = true end
    end
    UIManager:close(detail)
    tap_everything(make, "detail " .. state, skip)
end

-- ---------- settings ----------

UIManager.stack = {}
require("ui.settings").show(home)
local panel = UIManager.stack[#UIManager.stack]
ok(panel ~= nil, "settings did not open")
paint(panel, "settings")
    local settings_text = collected_text(panel)
    for _, row in ipairs({ "Server", "Connection", "Auto sync", "Grimmory account",
                           "Library", "On this device" }) do
        ok(settings_text[row], "settings missing row " .. row)
    end
    ok(not settings_text["3×3"], "settings index leaks Library implementation detail")
    sync_stub_enabled = false
    panel._draw.hits[2].callback()
    ok(sync_stub_enabled, "main Settings Auto sync switch follows the saved preference")
    UIManager:close(panel)
tap_everything(function()
    UIManager.stack = {}
    require("ui.settings").show(home)
    return UIManager.stack[#UIManager.stack]
end, "settings")
UIManager:drain()

UIManager.stack = {}
require("ui.library_settings").show(home)
local library_panel = UIManager.stack[#UIManager.stack]
ok(library_panel ~= nil, "library settings did not open")
paint(library_panel, "library settings")
local library_text = collected_text(library_panel)
ok(library_text["Comfortable"], "library settings missing Comfortable grid label")
ok(library_text["Compact"], "library settings missing Compact grid label")
ok(library_text["Dense"], "library settings missing Dense grid label")
ok(not library_text["3x3"] and not library_text["4x4"] and not library_text["5x4"],
    "library settings still shows raw grid keys")
UIManager:close(library_panel)
tap_everything(function()
    UIManager.stack = {}
    require("ui.library_settings").show(home)
    return UIManager.stack[#UIManager.stack]
end, "library settings")
UIManager:drain()

UIManager.stack = {}
local cache_mod = package.loaded["lib.cache_map"]
local prev_load = cache_mod.load
cache_mod.load = function() return { books = {} } end
require("ui.device_storage").show()
local storage = UIManager.stack[#UIManager.stack]
ok(storage ~= nil, "device storage did not open")
paint(storage, "device storage")
cache_mod.load = prev_load
check_targets(storage, "device storage")
UIManager:close(storage)

-- ---------- connected account ----------

Settings.set_t2_credentials("reader", "secret")
require("lib.session").adopt({
    accessToken = "test-access", refreshToken = "test-refresh", expires = 3600,
}, Settings.server_url(), "reader")
local Account = require("ui.account")
sync_stub_enabled = true
local account_changes = 0
local account = Account:new{
    home = home,
    on_changed = function() account_changes = account_changes + 1 end,
}
paint(account, "connected account")
check_targets(account, "connected account")
ok(#account._draw.hits >= 3, "connected account is missing status/sync actions")
account._draw.hits[3].callback()
ok(not sync_stub_enabled, "account switch turns off the stored Auto sync preference")
ok(account_changes == 1, "account switch notifies the underlying Settings screen")
UIManager:close(account)
UIManager:drain()

sync_stub_enabled = false
UIManager.stack = {}
require("ui.settings").show(home)
local settings_again = UIManager.stack[#UIManager.stack]
settings_again._draw.hits[2].callback()
ok(sync_stub_enabled, "settings switch enables shared auto sync")
UIManager:close(settings_again)
local account_again = Account:new{ home = home, on_changed = function() end }
ok(sync_stub_enabled, "account sees auto sync enabled from settings")
account_again._draw.hits[3].callback()
ok(not sync_stub_enabled, "account switch clears the same auto sync flag")
UIManager:close(account_again)
UIManager:drain()
Settings.clear_t2()

-- Search / download screens: only if those modules exist.
for _, name in ipairs({ "ui.search", "ui.downloads", "ui.download" }) do
    local found = io.open((name:gsub("%.", "/")) .. ".lua", "r")
    if found then
        found:close()
        local ScreenMod = require(name)
        UIManager.stack = {}
        if ScreenMod.show then
            ScreenMod.show(home)
            local screen = UIManager.stack[#UIManager.stack]
            ok(screen ~= nil, name .. " did not open")
            paint(screen, name)
            check_targets(screen, name)
            UIManager:close(screen)
        elseif ScreenMod.new then
            local screen = ScreenMod:new{ home = home }
            paint(screen, name)
            check_targets(screen, name)
            UIManager:close(screen)
        end
        UIManager:drain()
    end
end

-- ---------- icons ----------

local Icon = require("ui.icon")
local names = { "menu", "filter", "grid", "left", "right", "up", "down", "close", "check",
                "dot", "pin", "more", "book", "layers", "person", "home", "star", "tray",
                "spark", "gear", "hash", "folder", "tag", "sliders" }
for _, name in ipairs(names) do
    ok(Icon.has(name), "missing icon " .. name)
    local before = env.bb.calls
    Icon.paint(env.bb, name, 10, 10, 30, "black")
    ok(env.bb.calls > before, "icon " .. name .. " drew nothing")
end

print("ui: " .. checks .. " ok")
