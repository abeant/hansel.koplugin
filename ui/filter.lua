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
    { id = "title",  text = _("Title"),           default_dir = "asc" },
    { id = "author", text = _("Author"),          default_dir = "asc" },
    { id = "added",  text = _("Date added"),      default_dir = "desc" },
    { id = "series", text = _("Series position"), default_dir = "asc" },
    { id = "rating", text = _("Rating"),          default_dir = "desc" },
}

-- Formats seen in the catalog so far, so the sheet lists what you actually own.
local _seen_formats = { epub = true, pdf = true }

local function copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function default_status()
    return { unread = true, reading = true, finished = true }
end

local function dest_id(home)
    home = home or Filter._home
    if home then
        if home.feed_url then return "f:" .. tostring(home.feed_url) end
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
        sort_key = "added",
        sort_dir = "desc",
    }
end

local function normalize(raw)
    if type(raw) ~= "table" then return defaults() end
    local status = raw.status
    if type(status) ~= "table" or next(status) == nil then
        status = default_status()
    end
    local formats = raw.formats
    if type(formats) ~= "table" then formats = {} end
    return {
        device = raw.device or "all",
        status = copy(status),
        formats = copy(formats),
        sort_key = raw.sort_key or "added",
        sort_dir = raw.sort_dir or "desc",
    }
end

local function legacy_global()
    local status = Settings.get("filter_status")
    if type(status) ~= "table" or next(status) == nil then
        status = default_status()
    end
    local formats = Settings.get("filter_formats")
    if type(formats) ~= "table" then formats = {} end
    return {
        device = Settings.get("last_filter") or "all",
        status = copy(status),
        formats = copy(formats),
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
    for _, opt in ipairs(STATUS) do
        if not st.status[opt.id] then return true end
    end
    return next(st.formats) ~= nil
end

function Filter.label(id)
    for _, opt in ipairs(DEVICE) do
        if opt.id == (id or "all") then return opt.text end
    end
    return _("All")
end

function Filter.note_formats(books)
    for _, book in ipairs(books or {}) do
        local ext = book.file_type
        if type(ext) == "string" and ext ~= "" then
            _seen_formats[string.lower(ext)] = true
        end
    end
end

function Filter.formats()
    local list = {}
    for ext in pairs(_seen_formats) do list[#list + 1] = ext end
    table.sort(list)
    return list
end

-- ---------- predicate + comparator ----------

local function keeps(book, st)
    local state = book.state or "remote"
    if st.device == "downloaded" and state == "remote" then return false end
    if st.device == "pinned" and state ~= "pinned" then return false end
    if st.device == "remote" and state ~= "remote" then return false end

    local all_status = true
    for _, opt in ipairs(STATUS) do
        if not st.status[opt.id] then all_status = false break end
    end
    if not all_status and not st.status[Books.read_status(book)] then
        return false
    end

    if next(st.formats) ~= nil then
        local ext = book.file_type and string.lower(book.file_type) or ""
        if not st.formats[ext] then return false end
    end
    return true
end

local function sort_key(book, key)
    if key == "title" then
        return string.lower(book.title or "")
    elseif key == "author" then
        return string.lower(Fmt.authors(book))
    elseif key == "added" then
        return tostring(book.added_on or "")
    elseif key == "series" then
        return string.format("%s %08.2f", string.lower(book.series or "~"),
            tonumber(book.series_index) or 0)
    elseif key == "rating" then
        return string.format("%08.3f", tonumber(book.rating) or 0)
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

    put(sec_h, function(iy) Parts.section(draw, 0, iy, w, _("Status")) end)
    for _, opt in ipairs(STATUS) do
        put(opt_h, function(iy)
            Parts.option(draw, 0, iy, w, opt.text, "check", st.status[opt.id], function()
                st.status[opt.id] = not st.status[opt.id] or nil
                self:rebuild("ui")
            end)
        end)
    end

    put(sec_h, function(iy) Parts.section(draw, 0, iy, w, _("Format")) end)
    for _, ext in ipairs(Filter.formats()) do
        put(opt_h, function(iy)
            local on = next(st.formats) == nil or st.formats[ext]
            Parts.option(draw, 0, iy, w, ext, "check", on, function()
                if next(st.formats) == nil then
                    for _, e in ipairs(Filter.formats()) do st.formats[e] = true end
                end
                st.formats[ext] = not st.formats[ext] or nil
                local any = false
                for _ in pairs(st.formats) do any = true break end
                if not any then st.formats = {} end
                self:rebuild("ui")
            end)
        end)
    end

    put(sec_h, function(iy) Parts.section(draw, 0, iy, w, _("Sort by")) end)
    for _, opt in ipairs(SORTS) do
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
        self.state = {
            device = "all",
            status = default_status(),
            formats = {},
            sort_key = "added",
            sort_dir = "desc",
        }
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
    UIManager:show(Sheet:new{ home = home })
end

return Filter
