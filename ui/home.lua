--[[--
The library screen: header, cover grid, pager. Matches the wireframe —
menu on the left, funnel and density on the right, page turns flash.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("ui.base")
local Books = require("lib.books")
local CacheMap = require("lib.cache_map")
local Catalog = require("lib.catalog")
local Covers = require("lib.covers")
local Filter = require("ui.filter")
local Library = require("lib.library")
local Parts = require("ui.parts")
local Settings = require("lib.settings")
local Theme = require("ui.theme")
local Tile = require("ui.tile")

local Screen = Device.screen
local S = Theme.s

local Home = Base:extend{
    name = "hansel_home",
    is_always_active = false,
    wants_swipe = true,
    wants_paging = true,
    plugin = nil,
}

local VIEW_TITLE = {
    all = _("All Books"),
    dashboard = _("Dashboard"),
    on_device = _("On this device"),
    categories = _("Categories"),
    tags = _("Tags"),
    series = _("Series"),
    authors = _("Authors"),
}

local DENSITY_ORDER = { "3x3", "4x4", "5x4" }

function Home:setup()
    self.page = tonumber(Settings.get("last_page")) or 1
    self.view = Settings.get("last_view") or "all"
    self.view_title = VIEW_TITLE[self.view]
    self.books = {}
    self.total = 0
    self.library_total = Settings.library_total()
    self.trail = { { title = VIEW_TITLE[self.view] or _("All Books"), view = self.view } }
    self.offline = false
    self.unavailable = false
    self.hide_unavailable_active = false
    self.error_kind = nil
    self._tile_rects = {}
    UIManager:nextTick(function()
        if not self._closed then
            self:reload()
        end
    end)
end

function Home:_nav_row_h()
    return math.max(Theme.s(22), Theme.s(16)) + S(9) * 2 + Theme.hair
end

function Home:_nav_page_size(area_h)
    local row = self:_nav_row_h()
    if row < 1 then row = 1 end
    local h = area_h
    if not h then
        local header = Theme.s(10) * 2 + Theme.icon + Theme.rule
        local footer = Theme.rule + S(8) * 2 + Theme.icon
        h = Screen:getHeight() - header - footer - Theme.pad
    end
    return math.max(1, math.floor(h / row))
end

function Home:_page_count()
    if self.nav_items then
        local n = #self.nav_items
        local size = self:_nav_page_size()
        return math.max(1, math.ceil(math.max(n, 1) / size))
    end
    local size = Settings.page_size()
    local total = tonumber(self.total) or #self.books
    if size < 1 then size = 1 end
    return math.max(1, math.ceil(total / size))
end

function Home:_subtitle()
    if self.nav_items then
        local n = #self.nav_items
        local noun = VIEW_TITLE[self.view] or _("items")
        return T(_("%1 %2"), n, string.lower(noun))
    end
    local on_device = 0
    for _, book in ipairs(self.books or {}) do
        if book.state and book.state ~= "remote" then
            on_device = on_device + 1
        end
    end
    local line = T(_("%1 books / %2 on device"), self.total or 0, on_device)
    if self.unavailable then
        if self.error_kind == "auth_required" or self.error_kind == "forbidden" then
            line = line .. _(" / sign-in required")
        elseif self.error_kind == "server_error" then
            line = line .. _(" / server unavailable")
        else
            line = line .. _(" / offline")
        end
    end
    return line
end

-- ---------- layout ----------

function Home:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)

    local trail = self.trail or {}
    local crumbs
    if #trail > 1 then
        crumbs = {}
        for i, crumb in ipairs(trail) do
            local idx = i
            crumbs[#crumbs + 1] = {
                label = crumb.title or "",
                callback = i < #trail and function()
                    self:go_crumb(idx)
                end or nil,
            }
        end
    end
    local header_h = Parts.header(draw, {
        width = w,
        title = self.view_title or VIEW_TITLE[self.view] or _("Hansel"),
        crumbs = crumbs,
        left = {
            icon = "menu",
            callback = function()
                require("ui.drawer").show(self)
            end,
        },
        right = {
            {
                icon = "filter",
                on = Filter.active(),
                callback = function()
                    Filter.show(self)
                end,
            },
            {
                icon = "grid",
                callback = function()
                    self:cycle_density()
                end,
            },
            {
                icon = "search",
                callback = function()
                    local ok, SearchUI = pcall(require, "ui.search")
                    if ok and SearchUI and SearchUI.show then
                        SearchUI.show(self)
                    end
                end,
            },
        },
    })

    local content_top = header_h
    if self.hide_unavailable_active and #(self.books or {}) > 0 then
        local face = Theme.mono("tiny")
        local message = _("Showing books on this device")
        local banner_h = draw:label_height(face) + S(8) * 2 + Theme.hair
        draw:fill(0, content_top, w, banner_h, Theme.paper)
        draw:text(Theme.pad, content_top + S(8), message, face, Theme.graphite,
            w - Theme.pad * 2)
        draw:fill(0, content_top + banner_h - Theme.hair, w, Theme.hair, Theme.ash)
        content_top = content_top + banner_h
    end

    local pages = self:_page_count()
    local footer_h = Theme.rule + S(8) * 2 + Theme.icon
    local footer_y = h - footer_h
    if self.nav_items then
        self:_build_nav(draw, content_top, footer_y)
    else
        self:_build_grid(draw, content_top, footer_y)
    end
    draw:fill(0, footer_y, w, h - footer_y, Theme.paper)
    draw:rule(0, footer_y, w, Theme.rule)
    local btn_y = footer_y + Theme.rule + S(8)
    local corner = math.max(Theme.icon + Theme.pad * 2, math.floor(w * 0.2))
    local foot_h = h - footer_y
    Parts.icon_button(draw, Theme.pad, btn_y, "left", function()
        self:onPrevPage()
    end, {
        disabled = self.page <= 1,
        hit = { x = 0, y = footer_y, w = corner, h = foot_h },
    })
    Parts.icon_button(draw, w - Theme.pad - Theme.icon, btn_y, "right", function()
        self:onNextPage()
    end, {
        disabled = self.page >= pages,
        hit = { x = w - corner, y = footer_y, w = corner, h = foot_h },
    })
    local mid_w = w - corner * 2
    local meta_face = Theme.mono("tiny")
    local meta_h = draw:label_height(meta_face)
    draw:text_center(math.floor(w / 2),
        btn_y + math.floor((Theme.icon - meta_h) / 2),
        T(_("%1 / %2"), self.page, pages), meta_face, Theme.ink, mid_w)
end

function Home:_build_nav(draw, top, bottom)
    local y = top
    local w = Screen:getWidth()
    self._tile_rects = {}
    local items = self.nav_items or {}
    if #items == 0 then
        self:_build_empty(draw, Theme.pad, top + Theme.pad, w - Theme.pad * 2, bottom - top - Theme.pad * 2)
        return
    end
    local area_h = bottom - top
    local size = self:_nav_page_size(area_h)
    local start = (self.page - 1) * size + 1
    local stop = math.min(#items, start + size - 1)
    for i = start, stop do
        if y + self:_nav_row_h() > bottom then break end
        local item = items[i]
        y = y + Parts.nav_row(draw, 0, y, w, nil, item.title, item.count and tostring(item.count), false,
            function()
                self:open_feed(item.href, item.title)
            end)
    end
end

function Home:_build_grid(draw, top, bottom)
    local w = Screen:getWidth()
    local pad = S(2)
    local area_x = pad
    local area_y = top + S(2)
    local area_w = w - pad * 2
    local area_h = bottom - area_y - S(2)
    self._tile_rects = {}

    local books = self.books or {}
    if #books == 0 then
        self:_build_empty(draw, area_x, area_y, area_w, area_h)
        return
    end

    local grid = Settings.grid()
    local cols, rows = grid.cols, grid.rows
    local dense = cols >= 4
    local gap_x = S(dense and 2 or 3)
    local gap_y = S(dense and 2 or 3)
    local cell_w = math.floor((area_w - gap_x * (cols - 1)) / cols)
    local cell_h = math.floor((area_h - gap_y * (rows - 1)) / rows)
    if cell_w < 1 or cell_h < 1 then return end

    local idx = 1
    for r = 1, rows do
        for c = 1, cols do
            local book = books[idx]
            if book then
                local x = area_x + (c - 1) * (cell_w + gap_x)
                local y = area_y + (r - 1) * (cell_h + gap_y)
                Tile.draw(draw, {
                    book = book,
                    x = x, y = y, w = cell_w, h = cell_h,
                    dense = dense,
                    on_tap = function()
                        self:open_detail(book)
                    end,
                })
                if book.id then
                    self._tile_rects[tostring(book.id)] =
                        Geom:new{ x = x, y = y, w = cell_w, h = cell_h }
                end
            end
            idx = idx + 1
        end
    end
end

function Home:_build_empty(draw, x, y, w, h)
    local title, body
    if not Settings.can_browse() then
        title = _("Not signed in")
        body = _("Sign in to Grimmory in Settings.")
    elseif self.unavailable then
        local device = Filter.state().device
        if self.error_kind == "auth_required" or self.error_kind == "forbidden" then
            title = _("Sign-in required")
            body = _("Reconnect your Grimmory account.")
        elseif device == "remote" then
            title = _("Server books unavailable")
            body = _("Server-only books need a connection.")
        elseif self.hide_unavailable_active then
            title = _("Nothing on this device")
            body = _("Nothing downloaded or pinned yet.")
        else
            title = _("Grimmory unreachable")
            body = _("Can't reach Grimmory right now.")
        end
    elseif Filter.active() then
        title = _("Nothing matches")
        body = _("Widen the filters or pick another shelf.")
    else
        title = _("Nothing here yet")
        body = _("This shelf is empty.")
    end

    local mark = S(46)
    local title_face = Theme.text("title")
    local body_face = Theme.mono("small")
    local body_w = math.min(w - S(24) * 2, S(300))
    local body_box = draw:para_box(body, body_face, body_w, nil, Theme.graphite, "center")
    local title_h = draw:label_height(title_face)
    local gap = S(10)
    local block_h = mark + gap + title_h + gap + body_box.h
    local cy = y + math.floor((h - block_h) / 2)
    local cx = x + math.floor(w / 2)

    draw:dotted(cx - math.floor(mark / 2), cy, mark, mark, Theme.rule, Theme.ink)
    draw:icon("filter", cx - S(10), cy + math.floor((mark - S(20)) / 2), S(20), Theme.ink)
    draw:text_center(cx, cy + mark + gap, title, title_face, Theme.ink, w)
    draw:place(body_box.widget, cx - math.floor(body_w / 2), cy + mark + gap + title_h + gap)
end

-- ---------- data ----------

function Home:open_detail(book)
    local Detail = require("ui.detail")
    UIManager:show(Detail:new{
        book = book,
        plugin = self.plugin,
        on_change = function()
            self:reload()
        end,
    })
end

function Home:set_view(view)
    self.view = view
    self.view_title = VIEW_TITLE[view]
    self.feed_url = nil
    self.nav_items = nil
    self.page = 1
    self.trail = { { title = VIEW_TITLE[view] or view, view = view } }
    Settings.set("last_view", view)
    Settings.set("last_page", 1)
    self:reload()
end

function Home:open_feed(url, title, from_book)
    self.trail = self.trail or {}
    if #self.trail == 0 then
        self.trail[1] = { title = VIEW_TITLE[self.view] or self.view, view = self.view }
    end
    if from_book then
        self.trail[#self.trail + 1] = { title = from_book.title or _("Book"), book = from_book }
    end
    self.trail[#self.trail + 1] = { title = title, href = url }
    self.feed_url = url
    self.view_title = title
    self.nav_items = nil
    self.page = 1
    self:reload()
end

function Home:go_crumb(index)
    local trail = self.trail or {}
    local crumb = trail[index]
    if not crumb then return end
    for i = #trail, index + 1, -1 do
        trail[i] = nil
    end
    self.trail = trail
    if crumb.book then
        self:open_detail(crumb.book)
        return
    end
    self.page = 1
    if crumb.href then
        self.feed_url = crumb.href
        self.view_title = crumb.title
        self.nav_items = nil
        self:reload()
        return
    end
    self.view = crumb.view or "all"
    self.view_title = crumb.title or VIEW_TITLE[self.view]
    self.feed_url = nil
    self.nav_items = nil
    self:reload()
end

function Home:set_filter(id)
    Settings.set("last_filter", id or "all")
    self.page = 1
    Settings.set("last_page", 1)
    self:reload()
end

function Home:cycle_density()
    local current = Settings.get("grid_density") or "3x3"
    local idx = 1
    for i, key in ipairs(DENSITY_ORDER) do
        if key == current then idx = i break end
    end
    self:set_density(DENSITY_ORDER[(idx % #DENSITY_ORDER) + 1])
end

function Home:set_density(key)
    Settings.set("grid_density", key)
    self.page = 1
    Settings.set("last_page", 1)
    self:reload()
end

function Home:reload(force_network)
    if force_network then
        local NetworkMgr = require("ui/network/manager")
        if NetworkMgr.willRerunWhenOnline
                and NetworkMgr:willRerunWhenOnline(function() self:reload(true) end) then
            return
        end
    end
    local function work()
        local have_local = Catalog.book_count and Catalog.book_count() > 0
        if not have_local then
            Trapper:info(_("Loading library…"))
        end
        local size = Settings.page_size()
        local result
        local st = Filter.state()
        if self.view == "on_device" then
            st = Filter.on_device(st)
        end
        if self.feed_url then
            result = Library.fetch_feed(self.feed_url, self.page, size)
        elseif self.view == "categories" or self.view == "tags"
                or self.view == "series" or self.view == "authors" then
            local Nav = require("lib.nav")
            local nav = Nav.fetch(self.view)
            self.nav_items = nav.items or {}
            result = { books = {}, total = #self.nav_items, offline = false }
        elseif self.view == "dashboard" then
            result = self:_dashboard(size)
        else
            result = Library.query(st, self.page, size, force_network)
        end
        result = result or { books = {}, total = 0, offline = true }
        if result.page then self.page = result.page end
        local hydrated = Books.hydrate_list(result.books or {})
        Filter.note_formats(hydrated)
        local applied = Filter.effective(st, result.unavailable)
        local grid_view = (self.view == "all" or self.view == "on_device") and not self.feed_url
        if grid_view then
            self.books = hydrated
        else
            self.books = Filter.apply(hydrated, applied)
        end
        self.total = result.total or #self.books
        if self.view == "all" and not self.feed_url and not Filter.active() then
            if tonumber(self.total) and self.total > 0 then
                if not result.unavailable or not self.library_total or self.library_total == 0 then
                    self.library_total = self.total
                    Settings.set_library_total(self.library_total)
                end
            end
        elseif (not self.library_total or self.library_total == 0) and Settings.can_browse() then
            local peek = Library.page("all", 1, Settings.page_size())
            local n = peek and tonumber(peek.total)
            if n and n > 0 then
                self.library_total = n
                Settings.set_library_total(n)
            end
        end
        if Filter.active(applied) and not grid_view then
            self.total = #self.books
        end
        self.offline = result.offline and true or false
        self.unavailable = result.unavailable and true or false
        self.hide_unavailable_active = (result.unavailable and Settings.hide_unavailable()) and true or false
        self.error_kind = result.error_kind
        self.source = result.source
        self.counts = result.counts
        Settings.set("last_page", self.page)
        Trapper:clear()
        if self._closed then return end
        UIManager:nextTick(function()
            if self._closed then return end
            self:rebuild("full")
            self:_kick_covers()
            pcall(function() require("lib.manifest").ensure() end)
        end)
    end
    -- Trapper inhibits input. Don't wrap a cached catalog reload — that is
    -- what made tapping a Home row look like a freeze.
    if force_network or not (Catalog.book_count and Catalog.book_count() > 0) then
        Trapper:wrap(work)
    else
        work()
    end
end

function Home:_kick_covers()
    if not Covers.fetch_visible then return end
    Covers.fetch_visible(self.books or {}, function(id, path)
        if self._closed or not path then return end
        local rect = self._tile_rects and self._tile_rects[tostring(id)]
        if self.coverArrived then
            self:coverArrived(id, path, rect)
        else
            self:rebuild()
            if rect then
                UIManager:setDirty(self, "ui", rect)
            else
                UIManager:setDirty(self, "ui")
            end
        end
    end)
    if Settings.get("prefetch_next_page_covers") and Covers.prefetch_next and self.page then
        local state = self.filter_state or { view = self.view or "all" }
        local next_page = Library.query(state, self.page + 1, Settings.page_size(), false)
        if next_page and next_page.books then
            Covers.prefetch_next(next_page.books)
        end
    end
end

function Home:_dashboard(size)
    local ids = {}
    local seen = {}
    for _, id in ipairs(CacheMap.continue_ids(size)) do
        if not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    local recent = Library.page("all", 1, size)
    local n = recent and tonumber(recent.total)
    if n and n > 0 then
        self.library_total = n
        Settings.set_library_total(n)
    end
    for _, book in ipairs((recent and recent.books) or {}) do
        if book.id and not seen[book.id] then
            seen[book.id] = true
            ids[#ids + 1] = book.id
        end
        if #ids >= size then break end
    end
    local books = {}
    for _, id in ipairs(ids) do
        local book = Catalog.get_book(id)
        if book then books[#books + 1] = book end
    end
    return {
        books = books,
        total = #books,
        offline = recent and recent.offline,
        unavailable = recent and recent.unavailable,
        error_kind = recent and recent.error_kind,
        page = 1,
        size = size,
    }
end

-- ---------- paging ----------

function Home:onNextPage()
    if self.page >= self:_page_count() then return true end
    self.page = self.page + 1
    Covers.cancel()
    self:reload()
    return true
end

function Home:onPrevPage()
    if self.page <= 1 then return true end
    self.page = self.page - 1
    Covers.cancel()
    self:reload()
    return true
end

function Home:onSwipe(_, ges)
    if not ges then return false end
    if ges.direction == "west" then
        return self:onNextPage()
    elseif ges.direction == "east" then
        return self:onPrevPage()
    end
    return false
end

function Home:onClose()
    if self._closed then return true end
    self._closed = true
    Covers.cancel()
    pcall(function() require("lib.manifest").cancel() end)
    UIManager:close(self)
    if self._on_close then
        self._on_close()
    end
    return true
end

function Home:onCloseWidget()
    self._closed = true
    Covers.cancel()
    pcall(function() require("lib.manifest").cancel() end)
    Base.onCloseWidget(self)
end

return Home
