--[[--
Book detail: cover and metadata up top, facts grid, blurb, tags, and the
READ / PIN action bar pinned to the bottom edge.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("ui.base")
local Books = require("lib.books")
local CacheMap = require("lib.cache_map")
local Covers = require("lib.covers")
local Fmt = require("lib.fmt")
local Library = require("lib.library")
local Parts = require("ui.parts")
local Theme = require("ui.theme")

local Screen = Device.screen
local S = Theme.s

local Detail = Base:extend{
    name = "hansel_detail",
    book = nil,
    plugin = nil,
    on_change = nil,
}

local STATUS_TEXT = {
    unread = _("Unread"),
    reading = _("Reading"),
    finished = _("Finished"),
}

local STATE_TEXT = {
    remote = _("On server"),
    cached = _("On device"),
    pinned = _("Pinned to device"),
}

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 2 })
end

function Detail:setup()
    self.book = Books.hydrate(self.book) or {}
end

function Detail:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    local book = self.book
    local state = book.state or "remote"
    draw:fill(0, 0, w, h, Theme.paper)

    local header_h = Parts.header(draw, {
        width = w,
        title = STATE_TEXT[state] or STATE_TEXT.remote,
        left = {
            icon = "left",
            callback = function() self:onClose() end,
        },
        right = {
            {
                icon = "pin",
                on = state == "pinned",
                callback = function() self:toggle_pin() end,
            },
            {
                icon = "more",
                callback = function() self:more() end,
            },
        },
    })

    local act_face = Theme.mono()
    local act_btn_h = draw:label_height(act_face) + S(10) * 2
    local acts_h = Theme.rule + S(10) * 2 + act_btn_h
    local acts_y = h - acts_h

    -- .detail
    local x = Theme.pad
    local body_w = w - Theme.pad * 2
    local y = header_h + Theme.pad

    local cover_w = math.floor(body_w * 0.38)
    local cover_h = math.floor(cover_w * 1.5)
    local art = Covers.cached(book.id)
    local drew = false
    if art then
        drew = draw:image(art, x + Theme.hair, y + Theme.hair,
            cover_w - Theme.hair * 2, cover_h - Theme.hair * 2)
    end
    draw:border(x, y, cover_w, cover_h, Theme.hair, Theme.ink)
    if not drew then
        local chip_face = Theme.mono("small")
        local chip_w = cover_w - S(10)
        local box = draw:para_box(book.title or "", chip_face, chip_w - S(6), 4)
        local chip_h = box.h + S(6)
        draw:fill(x + S(5), y + cover_h - S(5) - chip_h, chip_w, chip_h, Theme.paper)
        draw:border(x + S(5), y + cover_h - S(5) - chip_h, chip_w, chip_h, Theme.hair, Theme.ink)
        draw:place(box.widget, x + S(5) + S(3), y + cover_h - S(5) - chip_h + S(3))
    end

    local mx = x + cover_w + S(12)
    local mw = body_w - cover_w - S(12)
    local my = y
    local title_box = draw:para_box(book.title or "", Theme.text("title"), mw, 4)
    draw:place(title_box.widget, mx, my)
    my = my + title_box.h + S(5)
    local by_face = Theme.mono("small")
    draw:text(mx, my, Fmt.authors(book), by_face, Theme.graphite, mw)
    my = my + draw:label_height(by_face) + S(8)
    if book.series and book.series ~= "" then
        local ser = book.series
        if book.series_index then
            ser = T("%1 #%2", ser, tostring(book.series_index))
        end
        local ser_face = Theme.mono("tiny")
        local widget, tw, th = draw:label(string.upper(ser), ser_face, Theme.ink, mw - S(12))
        draw:border(mx, my, tw + S(12), th + S(4), Theme.hair, Theme.ink)
        draw:place(widget, mx + S(6), my + S(2))
        my = my + th + S(4)
    end

    y = math.max(y + cover_h, my) + Theme.pad

    -- .facts
    local fact_label = Theme.mono("tiny")
    local fact_value = Theme.mono()
    local facts = {
        { _("Format"), string.upper(tostring(book.file_type or "—")) },
        { _("Size"), book.file_size and Fmt.bytes(book.file_size) or "—" },
        { _("Status"), STATUS_TEXT[Books.read_status(book)] or STATUS_TEXT.unread },
        { _("Added"), Fmt.date(book.added_on) ~= "" and Fmt.date(book.added_on) or "—" },
    }
    draw:fill(x, y, body_w, Theme.hair, Theme.ash)
    y = y + Theme.hair
    local cell_w = math.floor(body_w / 2)
    local row_h = S(7) * 2 + draw:label_height(fact_label) + draw:label_height(fact_value)
    for i = 1, #facts, 2 do
        for c = 0, 1 do
            local fact = facts[i + c]
            if fact then
                local fx = x + c * cell_w
                draw:text(fx, y + S(7), fact[1], fact_label, Theme.graphite, cell_w - S(8))
                draw:text(fx, y + S(7) + draw:label_height(fact_label), fact[2], fact_value,
                    Theme.ink, cell_w - S(8))
            end
        end
        y = y + row_h
        draw:fill(x, y, body_w, Theme.hair, Theme.ash)
        y = y + Theme.hair
    end

    -- .blurb, clamped to whatever is left above the action bar.
    y = y + Theme.pad
    local tag_h = S(28)
    local room = acts_y - y - tag_h - Theme.pad
    if book.description and book.description ~= "" and room > S(30) then
        local blurb_face = Theme.text()
        local lines = math.max(1, math.floor(room / draw:line_height(blurb_face)))
        local box = draw:para_box(book.description, blurb_face, body_w, lines, Theme.ink)
        draw:place(box.widget, x, y)
        y = y + box.h + S(12)
    end

    local chips = {}
    for _, name in ipairs(book.categories or {}) do chips[#chips + 1] = name end
    for _, name in ipairs(book.tags or {}) do chips[#chips + 1] = name end
    if #chips > 0 and y + tag_h <= acts_y then
        local tx = x
        for _, name in ipairs(chips) do
            local label = tostring(name)
            local face = Theme.mono("tiny")
            local _, tw = draw:label(label, face, Theme.ink)
            local chip_w = tw + S(7) * 2
            if tx + chip_w > x + body_w then break end
            Parts.tag(draw, tx, y, label, function()
                self:open_facet(label)
            end)
            tx = tx + chip_w + S(5)
        end
    end

    draw:fill(0, acts_y, w, h - acts_y, Theme.paper)
    draw:rule(0, acts_y, w, Theme.rule)
    local gap = S(8)
    local avail = w - Theme.pad * 2
    if state == "remote" then
        Parts.button(draw, Theme.pad, acts_y + Theme.rule + S(10), avail,
            _("Download"), true, function()
                self:onDownload()
            end, act_btn_h)
    else
        local pin_w = math.floor((avail - gap) / 3)
        local read_w = avail - gap - pin_w
        Parts.button(draw, Theme.pad, acts_y + Theme.rule + S(10), read_w,
            _("Read"), true, function()
                self:onRead()
            end, act_btn_h)
        Parts.button(draw, Theme.pad + read_w + gap, acts_y + Theme.rule + S(10), pin_w,
            state == "pinned" and _("Unpin") or _("Pin"), false, function()
                self:toggle_pin()
            end, act_btn_h)
    end
end

function Detail:open_facet(name)
    local home = self.plugin and self.plugin._widget
    local Nav = require("lib.nav")
    local href = Nav.href(name, "categories") or Nav.href(name, "tags")
    self:onClose()
    if home and home.open_feed and href then
        home:open_feed(href, name)
    end
end

-- ---------- actions ----------

function Detail:toggle_pin()
    local book = self.book
    if book.state == "remote" then
        notify(_("Download the book before pinning it."))
        return
    end
    local pin = book.state ~= "pinned"
    CacheMap.set_pinned(book.id, pin)
    book.state = pin and "pinned" or "cached"
    notify(pin and _("Pinned") or _("Unpinned"))
    self:rebuild("ui")
    if self.on_change then self.on_change() end
end

local function download_center(plugin)
    if plugin and plugin.download_center then
        return plugin.download_center
    end
    for _, mod in ipairs({ "ui.downloads", "lib.downloader", "ui/downloadmgr" }) do
        local ok, center = pcall(require, mod)
        if ok and center and (center.enqueue or center.add or center.run) then
            return center
        end
    end
end

function Detail:enqueue_download(on_done)
    local book = self.book
    local center = download_center(self.plugin)
    if center then
        local opts = { on_done = on_done, on_fail = on_done }
        local ok
        if center.enqueue then
            ok = center:enqueue(book, opts)
        elseif center.add then
            ok = center:add(book, opts)
        elseif center.run then
            ok = center.run(book, opts)
        end
        if ok ~= false then
            return
        end
    end
    Trapper:wrap(function()
        Trapper:setPausedText(_("Downloading…"), _("Cancel"), _("Continue"))
        Trapper:info(T(_("Downloading “%1”…"), book.title or _("book")))
        local ok, err = Library.download(book)
        Trapper:clear()
        if on_done then on_done(ok, err) end
    end)
end

function Detail:more()
    local book = self.book
    local buttons = {}
    if book.state == "remote" then
        buttons[#buttons + 1] = {{
            text = _("Download"),
            callback = function()
                UIManager:close(self._more)
                self:onDownload()
            end,
        }}
    end
    if book.state ~= "remote" then
        buttons[#buttons + 1] = {{
            text = _("Remove from device"),
            callback = function()
                UIManager:close(self._more)
                UIManager:show(ConfirmBox:new{
                    text = _("Remove the local copy? The Grimmory record stays."),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        CacheMap.remove(book.id, true)
                        book.state = "remote"
                        book.local_path = nil
                        self:rebuild("ui")
                        if self.on_change then self.on_change() end
                    end,
                })
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = _("Close"),
        callback = function() UIManager:close(self._more) end,
    }}
    self._more = ButtonDialog:new{
        title = book.title or _("Book"),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    UIManager:show(self._more)
end

function Detail:onDownload()
    local book = self.book
    if book.state ~= "remote" then
        notify(_("Already on device"))
        return
    end
    local after = self.on_change
    self:enqueue_download(function(ok, err)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed: %1"), tostring(err)),
            })
            if after then after() end
            return
        end
        book.local_path = type(err) == "string" and err or book.local_path
        book.state = "cached"
        notify(_("Downloaded"))
        if not self._closed then
            self:rebuild("ui")
        end
        if after then after() end
    end)
end

function Detail:onRead()
    local book = self.book
    local plugin = self.plugin
    local after = self.on_change
    UIManager:close(self)
    self._closed = true
    Trapper:wrap(function()
        Trapper:setPausedText(_("Downloading…"), _("Cancel"), _("Continue"))
        local path = book.local_path
        if not path then
            Trapper:info(T(_("Downloading “%1”…"), book.title or _("book")))
            local ok, err = Library.download(book)
            Trapper:clear()
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = T(_("Download failed: %1"), tostring(err)),
                })
                if after then after() end
                return
            end
            path = err
        end
        if plugin and plugin.open_book then
            plugin:open_book(book, path)
        end
    end)
end

return Detail
