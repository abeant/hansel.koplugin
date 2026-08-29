--[[--
Filter & sort.

Two things live here: the predicate/comparator pair the grid runs on, and the
bottom sheet that edits them. The sheet edits a copy - APPLY commits, closing
it discards, exactly like the wireframe.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Base = require("ui.base")
local Books = require("lib.books")
local Fmt = require("lib.fmt")
local Parts = require("ui.parts")
local Settings = require("lib.settings")
local Theme = require("ui.theme")
local Draw = require("ui.paint")

local Screen = Device.screen
local S = Theme.s

local Filter = {}

local DEVICE = {
    { id = "all",        text = _("All") },
    { id = "downloaded", text = _("Downloaded") },
    { id = "pinned",     text = _("Pinned") },
    { id = "remote",     text = _("Server only") },
}

local STATUS = {
    { id = "unread",   text = _("Unread") },
    { id = "reading",  text = _("Reading") },
    { id = "finished", text = _("Finished") },
}

local SORTS = {
    { id = "title",     text = _("Title"),           default_dir = "asc" },
    { id = "author",    text = _("Author"),          default_dir = "asc" },
    { id = "added",     text = _("Date added"),      default_dir = "desc" },
    { id = "published", text = _("Published"),       default_dir = "desc" },
    { id = "series",    text = _("Series position"), default_dir = "asc" },
    { id = "rating",    text = _("Rating"),          default_dir = "desc" },
    { id = "size",      text = _("File size"),       default_dir = "desc" },
    { id = "opened",    text = _("Last opened"),     default_dir = "desc" },
}

-- Formats actually present in the library. Never seed with PDF/CBZ/etc.
local _seen_formats = {}

local STATUS_IDS = { "unread", "reading", "finished" }

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

--- Empty = no filter. All-on is the same meaning, so store it as empty.
local function default_status()
    return {}
end

local function all_selected(map, keys)
    if type(map) ~= "table" or next(map) == nil then return false end
    for _, key in ipairs(keys) do
        if not map[key] then return false end
    end
    return true
end

--- True when the map actually restricts the set (not empty, not all-on).
local function is_restricted(map, keys)
    if type(map) ~= "table" or next(map) == nil then return false end
    if keys and all_selected(map, keys) then return false end
    return true
end

local function toggle_flag(map, key, keys)
    if next(map) == nil then
        map[key] = true
        return
    end
    if map[key] then
        map[key] = nil
    else
        map[key] = true
        if keys and all_selected(map, keys) then
            for k in pairs(map) do map[k] = nil end
        end
    end
end

local function dest_id(home)
    home = home or Filter._home
    if home then
        if home.feed_url then return "f:" .. tostring(home.feed_url) end
        if home.library_id then return "l:" .. tostring(home.library_id) end
        return "v:" .. tostring(home.view or Settings.get("last_view") or "all")
    end
    return "v:" .. tostring(Settings.get("last_view") or "all")
end

local function dest_bag()
    local bag = Settings.get("filter_by_dest")
    if type(bag) ~= "table" then bag = {} end
    return bag
end

local function defaults()
    return {
        device = "all",
        status = default_status(),
        formats = {},
        libraries = {},
        shelves = {},
        sort_key = "added",
        sort_dir = "desc",
    }
end

local function normalize_status(status)
    if type(status) ~= "table" then return {} end
    if next(status) == nil or all_selected(status, STATUS_IDS) then return {} end
    return copy(status)
end

local function normalize_libraries(libraries)
    if type(libraries) ~= "table" or next(libraries) == nil then return {} end
    local out = {}
    for key, on in pairs(libraries) do
        if on then out[tostring(key)] = true end
    end
    return out
end

local function normalize_shelves(shelves)
    return normalize_libraries(shelves)
end

local function normalize_formats(formats)
    if type(formats) ~= "table" or next(formats) == nil then return {} end
    local known = Filter.formats()
    local out = {}
    if #known > 0 then
        local allow = {}
        for i = 1, #known do allow[known[i]] = true end
        for ext, on in pairs(formats) do
            if on and allow[ext] then out[ext] = true end
        end
    else
        out = copy(formats)
    end
    if #known > 0 and all_selected(out, known) then return {} end
    return out
end

local function normalize(raw)
    if type(raw) ~= "table" then return defaults() end
    return {
        device = raw.device or "all",
        status = normalize_status(raw.status),
        formats = normalize_formats(raw.formats),
        libraries = normalize_libraries(raw.libraries),
        shelves = normalize_shelves(raw.shelves),
        sort_key = raw.sort_key or "added",
        sort_dir = raw.sort_dir or "desc",
    }
end

local function legacy_global()
    return {
        device = Settings.get("last_filter") or "all",
        status = normalize_status(Settings.get("filter_status")),
        formats = normalize_formats(Settings.get("filter_formats")),
        libraries = {},
        shelves = {},
        sort_key = Settings.get("sort_key") or "added",
        sort_dir = Settings.get("sort_dir") or "desc",
    }
end

--- Current committed state for this destination, normalised.
function Filter.state(home)
    local id = dest_id(home)
    local bag = dest_bag()
    local saved = bag[id]
    if type(saved) == "table" then return normalize(saved) end
    if id == "v:on_device" then
        local st = defaults()
        st.device = "downloaded"
        return st
    end
    if id == "v:all" then return legacy_global() end
    return defaults()
end

--- Downloaded ∪ pinned - the same set as today's Downloaded chip.
function Filter.on_device(state)
    local st = normalize(state or Filter.state())
    st.device = "downloaded"
    return st
end

--- Overlay downloaded ∪ pinned while Grimmory is unreachable and the setting
--- is on. Does not persist; the committed filter returns as soon as `unavailable`
--- is false.
function Filter.effective(state, unavailable)
    local st = normalize(state or Filter.state())
    if not unavailable or not Settings.hide_unavailable() then
        return st, false
    end
    if st.device == "downloaded" or st.device == "pinned" then
        return st, false
    end
    st.device = "downloaded"
    return st, true
end

function Filter.save(state, home)
    local id = dest_id(home)
    local bag = dest_bag()
    bag[id] = normalize(state)
    Settings.set("filter_by_dest", bag)
end

function Filter.reset(home)
    Filter.save(defaults(), home)
end

--- True when the grid is showing less than everything.
function Filter.active(state)
    local st = state or Filter.state()
    if st.device ~= "all" then return true end
    if is_restricted(st.status, STATUS_IDS) then return true end
    if type(st.libraries) == "table" and next(st.libraries) then return true end
    if type(st.shelves) == "table" and next(st.shelves) then return true end
    return is_restricted(st.formats, Filter.formats())
end

--- Grimmory libraries present in the catalog / nav cache.
function Filter.libraries()
    local ok_n, Nav = pcall(require, "lib.nav")
    if ok_n and Nav and Nav.get then
        local nav = Nav.get("libraries").items or {}
        if #nav > 0 then
            local list = {}
            for i = 1, #nav do
                local item = nav[i]
                list[i] = { id = tostring(item.id), name = item.title or item.id }
            end
            return list
        end
    end
    local seen, list = {}, {}
    local ok_c, Catalog = pcall(require, "lib.catalog")
    if ok_c and Catalog and Catalog.all_books then
        for _, book in ipairs(Catalog.all_books() or {}) do
            local id = book.library_id and tostring(book.library_id)
            if id and not seen[id] then
                seen[id] = true
                list[#list + 1] = { id = id, name = book.library_name or id }
            end
        end
    end
    table.sort(list, function(a, b)
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    return list
end

--- Grimmory shelves, Unshelved first.
function Filter.shelves()
    local list = {}
    local ok_n, Nav = pcall(require, "lib.nav")
    if ok_n and Nav and Nav.get then
        for _, item in ipairs((Nav.get("shelves").items or {})) do
            local id = item.id or item.special or item.title
            if id and item.title and item.title ~= "" then
                list[#list + 1] = { id = tostring(id), name = item.title }
            end
        end
    end
    return list
end

function Filter.format_label(ext)
    return string.upper(tostring(ext or ""))
end

function Filter.label(id)
    for _, opt in ipairs(DEVICE) do
        if opt.id == (id or "all") then return opt.text end
    end
    return _("All")
end

function Filter.note_formats(books)
    for i = 1, #(books or {}) do
        local ext = books[i].file_type
        if type(ext) == "string" and ext ~= "" then
            _seen_formats[string.lower(ext)] = true
        end
    end
end

local _format_cache

function Filter.formats()
    local rev = 0
    local ok, Catalog = pcall(require, "lib.catalog")
    if ok and Catalog and Catalog.book_count then
        rev = Catalog.book_count() or 0
    end
    local noted = 0
    for _ in pairs(_seen_formats) do noted = noted + 1 end
    local key = tostring(rev) .. ":" .. tostring(noted)
    if _format_cache and _format_cache.key == key then
        return _format_cache.list
    end
    local seen = {}
    for ext in pairs(_seen_formats) do seen[ext] = true end
    if ok and Catalog then
        if Catalog.format_counts then
            for ext in pairs(Catalog.format_counts() or {}) do
                if type(ext) == "string" and ext ~= "" then
                    seen[string.lower(ext)] = true
                end
            end
        elseif Catalog.all_books then
            local books = Catalog.all_books() or {}
            for i = 1, #books do
                local ext = books[i].file_type
                if type(ext) == "string" and ext ~= "" then
                    seen[string.lower(ext)] = true
                end
            end
        end
    end
    local list = {}
    for ext in pairs(seen) do list[#list + 1] = ext end
    table.sort(list)
    _format_cache = { key = key, list = list }
    return list
end

function Filter.sorts()
    return SORTS
end

-- ---------- predicate + comparator ----------

local function book_is_unshelved(book)
    local v = book and book.shelves
    if v == nil or v == "" then return true end
    if type(v) == "string" then return false end
    if type(v) ~= "table" then return true end
    for _, row in ipairs(v) do
        local name = type(row) == "table" and (row.name or row.title or row.id) or row
        if name and tostring(name) ~= "" then return false end
    end
    return true
end

local function book_matches_shelves(book, selected)
    if selected.unshelved and book_is_unshelved(book) then return true end
    local v = book and book.shelves
    if type(v) == "string" then v = { v } end
    for _, row in ipairs(type(v) == "table" and v or {}) do
        local name = type(row) == "table" and (row.name or row.title) or row
        local id = type(row) == "table" and (row.id or row.value) or name
        if name and selected[tostring(name)] then return true end
        if id and selected[tostring(id)] then return true end
    end
    return false
end

local function keeps(book, st)
    local state = book.state or "remote"
    if st.device == "downloaded" and state == "remote" then return false end
    if st.device == "pinned" and state ~= "pinned" then return false end
    if st.device == "remote" and state ~= "remote" then return false end

    if is_restricted(st.status, STATUS_IDS)
            and not st.status[Books.read_status(book)] then
        return false
    end

    if is_restricted(st.formats, Filter.formats()) then
        local ext = book.file_type and string.lower(book.file_type) or ""
        if not st.formats[ext] then return false end
    end

    if type(st.libraries) == "table" and next(st.libraries) then
        local id = book.library_id and tostring(book.library_id)
        if not id or not st.libraries[id] then return false end
    end

    if type(st.shelves) == "table" and next(st.shelves) then
        if not book_matches_shelves(book, st.shelves) then return false end
    end
    return true
end

local function cache_entry(book)
    if not book or not book.id then return nil end
    local ok, CacheMap = pcall(require, "lib.cache_map")
    if ok and CacheMap and CacheMap.get then return CacheMap.get(book.id) end
    return nil
end

local function book_size(book)
    local n = tonumber(book and book.file_size)
    if n and n > 0 then return n end
    local entry = cache_entry(book)
    return tonumber(entry and entry.bytes) or 0
end

local function book_opened(book)
    local entry = cache_entry(book)
    return tonumber(entry and (entry.last_opened or entry.last_access)) or 0
end

local function sort_key(book, key)
    if key == "title" then
        return string.lower(book.title or "")
    elseif key == "author" then
        return string.lower(Fmt.authors(book))
    elseif key == "added" then
        return tostring(book.added_on or "")
    elseif key == "published" then
        return tostring(book.published_date or "")
    elseif key == "series" then
        return string.format("%s %08.2f", string.lower(book.series or "~"),
            tonumber(book.series_index) or 0)
    elseif key == "rating" then
        return string.format("%08.3f", tonumber(book.rating) or 0)
    elseif key == "size" then
        return string.format("%016d", book_size(book))
    elseif key == "opened" then
        return string.format("%016d", book_opened(book))
    end
    return ""
end

--- Filter and sort a page of books. Order is stable for equal keys.
function Filter.apply(books, state)
    local st = state or Filter.state()
    local out = {}
    for i, book in ipairs(books or {}) do
        if keeps(book, st) then
            out[#out + 1] = { book = book, seq = i, key = sort_key(book, st.sort_key) }
        end
    end
    local desc = st.sort_dir == "desc"
    table.sort(out, function(a, b)
        if a.key ~= b.key then
            if desc then return a.key > b.key end
            return a.key < b.key
        end
        return a.seq < b.seq
    end)
    local books_out = {}
    for i, row in ipairs(out) do books_out[i] = row.book end
    return books_out
end

-- ---------- the sheet ----------

local Sheet = Base:extend{
    name = "hansel_filter_sheet",
    covers_fullscreen = false,
    wants_swipe = true,
    home = nil,
}

function Sheet:setup()
    Filter._home = self.home
    self.state = Filter.state(self.home)
    if self.home and self.home.library_id and not next(self.state.libraries) then
        self.state.libraries[tostring(self.home.library_id)] = true
    end
    self.scroll = 0
    local scratch = Draw.new()
    local height = self:_layout(scratch, 0)
    scratch:free()
    local screen_h = Screen:getHeight()
    local max_h = math.floor(screen_h * 0.76)
    self.top = math.max(S(16), screen_h - math.min(height, max_h))
    self.panel = Geom:new{
        x = 0, y = self.top,
        w = Screen:getWidth(), h = screen_h - self.top,
    }
end

function Sheet:build(draw)
    self:_layout(draw, self.top)
end

--- Draws the sheet with its top edge at `top`; returns the height it used.
function Sheet:_layout(draw, top)
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    local st = self.state

    -- The footer is pinned to the bottom edge; everything above it flows.
    local btn_face = Theme.mono()
    local btn_h = draw:label_height(btn_face) + S(10) * 2
    local foot_h = Theme.rule + S(10) * 2 + btn_h

    draw:fill(0, top, w, h - top, Theme.paper)

    local head_face = Theme.mono()
    local grab_y = top + Theme.rule + S(7)
    local head_row_y = grab_y + S(3) + S(8)
    local head_h = math.max(draw:label_height(head_face), Theme.icon) + S(8) * 2
    local header_bottom = head_row_y + head_h + Theme.rule

    local foot_top = math.max(top, h - foot_h)
    local body_top = header_bottom
    local y = body_top
    local scroll = self.scroll or 0
    local function show(iy, ih)
        return iy + ih > body_top and iy < foot_top
    end
    local function put(ih, fn)
        local iy = y - scroll
        if show(iy, ih) then fn(iy) end
        y = y + ih
    end

    local sec_h = Parts.section_height(draw, true)
    local opt_h = math.max(draw:label_height(Theme.mono()), S(15)) + S(9) * 2 + Theme.hair

    put(sec_h, function(iy) Parts.section(draw, 0, iy, w, _("On device")) end)
    do
        local chips = {}
        for _, opt in ipairs(DEVICE) do
            chips[#chips + 1] = {
                label = opt.text,
                on = st.device == opt.id,
                callback = function()
                    st.device = opt.id
                    self:rebuild("ui")
                end,
            }
        end
        local ch = S(10) * 2 + draw:label_height(Theme.mono("small")) + S(5) * 2
        put(ch, function(iy) Parts.chips(draw, 0, iy, w, chips) end)
    end

    local function put_chips(title, items, map)
        if #items == 0 then return end
        put(sec_h, function(iy) Parts.section(draw, 0, iy, w, title) end)
        local chips, keys = {}, {}
        for i = 1, #items do
            local it = items[i]
            keys[i] = it.id
            chips[i] = {
                label = it.name,
                on = map[it.id] == true,
                callback = function()
                    toggle_flag(map, it.id, keys)
                    self:rebuild("ui")
                end,
            }
        end
        local line = S(10) * 2 + draw:label_height(Theme.mono("small")) + S(5) * 2
        local rows = #chips > 4 and 2 or 1
        local ch = line + (rows - 1) * (line - S(14) + S(6))
        put(ch, function(iy) Parts.chips(draw, 0, iy, w, chips) end)
    end

    local libs = Filter.libraries()
    if #libs >= 2 then
        put_chips(_("Library"), libs, st.libraries)
    end
    put_chips(_("Shelf"), Filter.shelves(), st.shelves)

    put(sec_h, function(iy) Parts.section(draw, 0, iy, w, _("Status")) end)
    for _, opt in ipairs(STATUS) do
        put(opt_h, function(iy)
            Parts.option(draw, 0, iy, w, opt.text, "check", st.status[opt.id] == true, function()
                toggle_flag(st.status, opt.id, STATUS_IDS)
                self:rebuild("ui")
            end)
        end)
    end

    local format_keys = Filter.formats()
    if #format_keys >= 2 then
        put(sec_h, function(iy) Parts.section(draw, 0, iy, w, _("Format")) end)
        for i = 1, #format_keys do
            local ext = format_keys[i]
            put(opt_h, function(iy)
                Parts.option(draw, 0, iy, w, Filter.format_label(ext), "check",
                    st.formats[ext] == true, function()
                        toggle_flag(st.formats, ext, format_keys)
                        self:rebuild("ui")
                    end)
            end)
        end
    end

    put(sec_h, function(iy) Parts.section(draw, 0, iy, w, _("Sort by")) end)
    local sort_opts = Filter.sorts()
    for _, opt in ipairs(sort_opts) do
        put(opt_h, function(iy)
            local on = st.sort_key == opt.id
            local dir = on and (st.sort_dir == "desc" and "down" or "up")
                or (opt.default_dir == "desc" and "down" or "up")
            Parts.option(draw, 0, iy, w, opt.text, "radio", on, function()
                if on then
                    st.sort_dir = st.sort_dir == "desc" and "asc" or "desc"
                else
                    st.sort_key = opt.id
                    st.sort_dir = opt.default_dir
                end
                self:rebuild("ui")
            end, dir)
        end)
    end
    y = y + S(6)

    local content_h = y - body_top
    local view_h = foot_top - body_top
    self._max_scroll = math.max(0, content_h - view_h)
    if self.scroll > self._max_scroll then self.scroll = self._max_scroll end
    y = body_top + content_h

    -- .sheet-foot
    local content_end = y
    draw:fill(0, foot_top, w, h - foot_top, Theme.paper)
    draw:rule(0, foot_top, w, Theme.rule)
    local half = math.floor((w - Theme.pad * 2 - S(8)) / 2)
    Parts.button(draw, Theme.pad, foot_top + Theme.rule + S(10), half, _("Reset"), false, function()
        local reset = defaults()
        if self.home and self.home.view == "on_device" then
            reset.device = "downloaded"
        end
        self.state = reset
        self:rebuild("ui")
    end, btn_h)
    Parts.button(draw, Theme.pad + half + S(8), foot_top + Theme.rule + S(10), half,
        _("Apply"), true, function()
            Filter.save(self.state, self.home)
            local home = self.home
            self:onClose()
            if home then
                home.page = 1
                Settings.set("last_page", 1)
                home:reload()
            end
        end, btn_h)

    draw:fill(0, top, w, header_bottom - top, Theme.paper)
    draw:rule(0, top, w, Theme.rule)
    draw:fill(math.floor((w - S(40)) / 2), grab_y, S(40), S(3), Theme.ink)
    draw:text(Theme.pad, head_row_y + math.floor((head_h - draw:label_height(head_face)) / 2),
        _("Filter & sort"), head_face, Theme.ink)
    Parts.icon_button(draw, w - Theme.pad - Theme.icon,
        head_row_y + math.floor((head_h - Theme.icon) / 2), "close", function()
            self:onClose()
        end)
    draw:rule(0, header_bottom - Theme.rule, w, Theme.rule)

    return (content_end - top) + foot_h
end

function Sheet:onSwipe(_, ges)
    if not ges then return false end
    local step = math.max(S(80), math.floor((self.panel and self.panel.h or 200) * 0.45))
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

function Sheet:onTapOutside(ges)
    if ges and ges.pos and ges.pos.y < self.top then
        self:onClose()
    end
    return true
end

function Filter.show(home)
    Filter._home = home
    local ok_n, Nav = pcall(require, "lib.nav")
    if ok_n and Nav and Nav.harvest then Nav.harvest() end
    local sheet = Sheet:new{ home = home }
    UIManager:show(sheet)
    if not (ok_n and Nav and Nav.fetch) then return end
    local function pull(kind, nxt)
        return function()
            if sheet._closed then return end
            Nav.fetch(kind, { rest_only = true, force_rest = true })
            if sheet._closed then return end
            sheet:rebuild("ui")
            if nxt then UIManager:scheduleIn(0.05, nxt) end
        end
    end
    UIManager:scheduleIn(0.05, pull("libraries", pull("shelves")))
end

return Filter
