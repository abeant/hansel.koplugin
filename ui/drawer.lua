local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("ui.base")
local CacheMap = require("lib.cache_map")
local Nav = require("lib.nav")
local Parts = require("ui.parts")
local Paths = require("lib.paths")
local Settings = require("lib.settings")
local Session = require("lib.session")
local Theme = require("ui.theme")

local Screen = Device.screen
local S = Theme.s

local Drawer = Base:extend{
    name = "hansel_drawer",
    covers_fullscreen = false,
    wants_swipe = true,
    home = nil,
}

local function host_label()
    local origin = Settings.server_url()
    if not origin or origin == "" then return _("NOT CONNECTED") end
    local host = tostring(origin):gsub("^https?://", ""):gsub("/+$", "")
    return string.upper(host)
end

local function connection_suffix()
    local kind = Session.status().kind
    if kind == "connected" then return _("CONNECTED") end
    if kind == "auth_required" or kind == "forbidden" then return _("SIGN-IN REQUIRED") end
    if kind == "server_error" then return _("SERVER UNAVAILABLE") end
    if kind == "offline" then return _("OFFLINE") end
    if kind == "checking" then return _("CHECKING") end
    return _("NOT CHECKED")
end

function Drawer:setup()
    self.width = math.floor(Screen:getWidth() * 0.74)
    self.panel = Geom:new{ x = 0, y = 0, w = self.width, h = Screen:getHeight() }
    self._closed_groups = {}
    self.scroll = 0
end

function Drawer:_toggle(group)
    self._closed_groups[group] = not self._closed_groups[group]
    self:rebuild("ui")
end

local function logo_path()
    local root = Paths.plugin_dir() or "."
    local lfs = require("libs/libkoreader-lfs")
    local png = root .. "/assets/hansel.png"
    if lfs.attributes(png, "mode") == "file" then return png end
    local svg = root .. "/hansel.svg"
    if lfs.attributes(svg, "mode") == "file" then return svg end
    return nil
end

function Drawer:_brand(draw)
    local w = self.width
    local pad_x = Theme.pad * 2
    local pad_y = S(16)
    local logo_h = S(32)
    local logo_w = w - pad_x * 2
    local y = pad_y
    local path = logo_path()
    if path and draw:image(path, pad_x, y, logo_w, logo_h, "left") then
        y = y + logo_h + S(10)
    else
        draw:text(pad_x, y, "Hansel", Theme.text("title"), Theme.ink, logo_w)
        y = y + draw:label_height(Theme.text("title")) + S(8)
    end
    local known_total = self.home and (self.home.library_total or self.home.total) or 0
    local sub_face = Theme.mono("tiny")
    draw:text(pad_x, y,
        T(_("%1 · %2 / %3 books"), host_label(), connection_suffix(),
            known_total),
        sub_face, Theme.graphite, logo_w)
    y = y + draw:label_height(sub_face) + S(12)
    draw:rule(0, y, w, Theme.rule)
    return y + Theme.rule
end

function Drawer:_add_group(rows, name, items)
    rows[#rows + 1] = {
        group = name,
        action = function() self:_toggle(name) end,
    }
    if self._closed_groups[name] then return end
    for _, item in ipairs(items or {}) do
        rows[#rows + 1] = item
    end
end

function Drawer:_rows()
    local home = self.home
    local total = home and (home.library_total or home.total) or 0
    local view = home and home.view
    local title = home and home.view_title
    local function ncount(kind)
        local items = Nav.get(kind).items or {}
        if #items == 0 then return nil end
        return tostring(#items)
    end

    local home_items = {
        {
            icon = "home", label = _("Dashboard"), on = view == "dashboard",
            action = function() if home then home:set_view("dashboard") end end,
        },
        {
            icon = "search", label = _("Search"),
            on = view == "search",
            action = function()
                local ok, Search = pcall(require, "ui.search")
                if ok and Search and Search.show then
                    Search.show(home)
                end
            end,
        },
        {
            icon = "book", label = _("All Books"), count = tostring(total),
            on = view == "all" and not (home and home.feed_url) and not (home and home.library_id),
            action = function() if home then home:set_view("all") end end,
        },
        {
            icon = "tray", label = _("On this device"),
            count = tostring(#(CacheMap.on_device_ids and CacheMap.on_device_ids() or {})),
            on = view == "on_device" and not (home and home.feed_url),
            action = function() if home then home:set_view("on_device") end end,
        },
        {
            icon = "folder", label = _("Genres"), count = ncount("categories"),
            on = view == "categories" and not (home and home.feed_url),
            action = function() if home then home:set_view("categories") end end,
        },
        {
            icon = "tag", label = _("Tags"), count = ncount("tags"),
            on = view == "tags" and not (home and home.feed_url),
            action = function() if home then home:set_view("tags") end end,
        },
        {
            icon = "layers", label = _("Series"), count = ncount("series"),
            on = view == "series" and not (home and home.feed_url),
            action = function() if home then home:set_view("series") end end,
        },
        {
            icon = "person", label = _("Authors"), count = ncount("authors"),
            on = view == "authors" and not (home and home.feed_url),
            action = function() if home then home:set_view("authors") end end,
        },
    }

    local library_items = {}
    for _, item in ipairs(Nav.get("libraries").items or {}) do
        library_items[#library_items + 1] = {
            icon = "library", label = item.title,
            count = item.count and tostring(item.count),
            on = home and home.library_id == tostring(item.id),
            action = function()
                if home and home.open_library then
                    home:open_library(item.id, item.title)
                end
            end,
        }
    end

    local shelf_items = {}
    for _, item in ipairs(Nav.get("shelves").items or {}) do
        shelf_items[#shelf_items + 1] = {
            icon = "book", label = item.title,
            count = item.count and tostring(item.count),
            on = title == item.title,
            action = function()
                if home then home:open_feed(item.href, item.title) end
            end,
        }
    end

    local magic_items = {}
    for _, item in ipairs(Nav.get("magic").items or {}) do
        magic_items[#magic_items + 1] = {
            icon = "spark", label = item.title,
            count = item.count and tostring(item.count),
            on = title == item.title,
            action = function()
                if home then home:open_feed(item.href, item.title) end
            end,
        }
    end

    local rows = {}
    self:_add_group(rows, _("Home"), home_items)
    if #library_items > 0 then
        self:_add_group(rows, _("Libraries"), library_items)
    end
    if #shelf_items > 0 then
        self:_add_group(rows, _("Shelves"), shelf_items)
    end
    if #magic_items > 0 then
        self:_add_group(rows, _("Magic Shelves"), magic_items)
    end
    rows[#rows + 1] = { group = "" }
    rows[#rows + 1] = {
        icon = "person",
        label = Settings.has_tier2()
            and (Settings.get("t2_username") or _("Account"))
            or _("Sign in to Grimmory"),
        action = function()
            require("ui.account").show(home)
        end,
    }
    rows[#rows + 1] = {
        icon = "sliders", label = _("Settings"),
        action = function() require("ui.settings").show(home) end,
    }
    rows[#rows + 1] = {
        icon = "more", label = _("KOReader menu"),
        action = function() require("ui.komenu").show(home) end,
    }
    rows[#rows + 1] = {
        icon = "close", label = _("Close Hansel"),
        action = function() if home then home:onClose() end end,
    }
    return rows
end

function Drawer:build(draw)
    local w = self.width
    local h = Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)

    local header_bottom = self:_brand(draw)

    local rows = self:_rows()
    local face_h = draw:label_height(Theme.mono())
    local row_h = math.max(face_h, Theme.s(16)) + S(9) * 2 + Theme.hair
    local sec_h = Parts.section_height(draw, true)
    local scroll = self.scroll or 0
    local cursor = header_bottom
    local function put(ih, fn)
        local iy = cursor - scroll
        if iy + ih > header_bottom and iy < h then
            fn(iy)
        end
        cursor = cursor + ih
    end
    for _, row in ipairs(rows) do
        if row.group ~= nil then
            if row.group ~= "" then
                local open = not self._closed_groups[row.group]
                put(sec_h, function(iy)
                    Parts.section(draw, 0, iy, w, row.group, true, open and "chev_down" or "chev_right")
                    if row.action then
                        draw:tap(0, iy, w, sec_h, row.action)
                    end
                end)
            else
                put(S(11) + Theme.hair, function(iy)
                    draw:fill(0, iy + S(11), w, Theme.hair, Theme.ash)
                end)
            end
        else
            put(row_h, function(iy)
                Parts.nav_row(draw, 0, iy, w, row.icon, row.label, row.count, row.on,
                    function()
                        self:onClose()
                        row.action()
                    end)
            end)
        end
    end
    self._max_scroll = math.max(0, cursor - header_bottom - (h - header_bottom))

    draw:fill(0, 0, w, header_bottom, Theme.paper)
    self:_brand(draw)
    draw:fill(w - Theme.rule, 0, Theme.rule, h, Theme.ink)
    draw:tap(0, 0, w, header_bottom, function() end, false)
end

function Drawer:onSwipe(_, ges)
    if not ges then return false end
    local step = math.max(S(80), math.floor(Screen:getHeight() * 0.35))
    local maxs = self._max_scroll or 0
    if ges.direction == "north" then
        self.scroll = math.min(maxs, (self.scroll or 0) + step)
        self:rebuild("ui")
        return true
    elseif ges.direction == "south" then
        self.scroll = math.max(0, (self.scroll or 0) - step)
        self:rebuild("ui")
        return true
    end
    return false
end

function Drawer:onTapOutside(ges)
    if ges and ges.pos and ges.pos.x >= self.width then
        self:onClose()
    end
    return true
end

function Drawer.show(home)
    Nav.harvest()
    local drawer = Drawer:new{ home = home }
    UIManager:show(drawer)
    Nav.refresh()
    local function more()
        if drawer._closed then return end
        if Nav.step_rest() and not drawer._closed then
            drawer:rebuild("ui")
            UIManager:scheduleIn(0.05, more)
        elseif not drawer._closed then
            drawer:rebuild("ui")
        end
    end
    UIManager:scheduleIn(0.05, more)
end

return Drawer
