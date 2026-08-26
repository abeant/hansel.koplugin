local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local _ = require("gettext")
local T = require("ffi/util").template

local CacheMap = require("lib.cache_map")
local Covers = require("lib.covers")
local Library = require("lib.library")
local Theme = require("ui.theme")

local Tile = {}

local function host()
    for _, win in ipairs(UIManager._window_stack or {}) do
        local w = win.widget
        if w and w.name == "hansel_home" then return w end
    end
end

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

local function after_change()
    local home = host()
    if home and home.reload then home:reload() end
end

local function do_read(book)
    local home = host()
    local plugin = home and home.plugin
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
                after_change()
                return
            end
            path = err
        end
        if plugin and plugin.open_book then
            plugin:open_book(book, path)
        end
    end)
end

local function do_download(book)
    if book.state ~= "remote" then
        notify(_("Already on device"))
        return
    end
    Trapper:wrap(function()
        Trapper:setPausedText(_("Downloading…"), _("Cancel"), _("Continue"))
        Trapper:info(T(_("Downloading “%1”…"), book.title or _("book")))
        local ok, err = Library.download(book)
        Trapper:clear()
        if not ok then
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed: %1"), tostring(err)),
            })
        else
            book.local_path = err
            book.state = "cached"
            notify(_("Downloaded"))
        end
        after_change()
    end)
end

local function do_pin(book)
    if book.state == "remote" then
        notify(_("Download the book before pinning it."))
        return
    end
    local pin = book.state ~= "pinned"
    CacheMap.set_pinned(book.id, pin)
    book.state = pin and "pinned" or "cached"
    notify(pin and _("Pinned") or _("Unpinned"))
    after_change()
end

local function do_remove(book)
    if book.state == "remote" then return end
    UIManager:show(ConfirmBox:new{
        text = _("Remove the local copy? The Grimmory record stays."),
        ok_text = _("Remove"),
        ok_callback = function()
            CacheMap.remove(book.id, true)
            book.state = "remote"
            book.local_path = nil
            after_change()
        end,
    })
end

local function show_menu(book, on_details)
    local dlg
    local function close()
        UIManager:close(dlg)
    end
    local buttons = {
        {{ text = _("Read"), callback = function() close() do_read(book) end }},
        {{ text = _("Download"), callback = function() close() do_download(book) end }},
        {{
            text = book.state == "pinned" and _("Unpin") or _("Pin"),
            callback = function() close() do_pin(book) end,
        }},
        {{ text = _("Remove from device"), callback = function() close() do_remove(book) end }},
        {{
            text = _("Details"),
            callback = function()
                close()
                if on_details then on_details() end
            end,
        }},
    }
    dlg = ButtonDialog:new{
        title = book.title or _("Book"),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    UIManager:show(dlg)
end

local hold_ready
local function ensure_hold()
    if hold_ready then return end
    hold_ready = true
    local Base = require("ui.base")
    local Device = require("device")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local full = Geom:new{
        x = 0, y = 0,
        w = Device.screen:getWidth(),
        h = Device.screen:getHeight(),
    }
    function Base:onHold(_, ges)
        local hit = self._draw and self._draw:hit(ges and ges.pos)
        if hit and hit.hold then
            hit.hold()
            return true
        end
    end
    local orig = Base.init
    function Base:init(...)
        orig(self, ...)
        if self.ges_events and not self.ges_events.Hold then
            self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = full } }
        end
    end
    for _, win in ipairs(UIManager._window_stack or {}) do
        local w = win.widget
        if w and w.ges_events and not w.ges_events.Hold then
            w.ges_events.Hold = { GestureRange:new{ ges = "hold", range = full } }
            if not w.onHold then w.onHold = Base.onHold end
        end
    end
end

local function badge(draw, state, x, y, side)
    local inner = math.floor(side * 8 / 14)
    local ix = x + math.floor((side - inner) / 2)
    local iy = y + math.floor((side - inner) / 2)
    if state == "remote" then
        draw:fill(x, y, side, side, Theme.paper)
        draw:border(x, y, side, side, Theme.hair, Theme.ink)
        return
    end
    draw:fill(x, y, side, side, Theme.ink)
    draw:icon(state == "pinned" and "pin" or "dot", ix, iy, inner, Theme.paper,
        math.max(1, math.floor(Theme.hair)))
end

function Tile.draw(draw, opts)
    local book = opts.book or {}
    local x, y, w, h = opts.x, opts.y, opts.w, opts.h
    local margin = Theme.s(4)
    local max_w = math.max(1, w - margin * 2)
    local max_h = math.max(1, h - margin * 2)
    local box_x, box_y, box_w, box_h

    local art = Covers.cached(book.id)
    if art then
        box_x, box_y, box_w, box_h = draw:image(art, x + margin, y + margin, max_w, max_h)
    end
    if not box_x then
        box_w = max_w
        box_h = math.floor(box_w * 3 / 2)
        if box_h > max_h then
            box_h = max_h
            box_w = math.floor(box_h * 2 / 3)
        end
        box_x = x + math.floor((w - box_w) / 2)
        box_y = y + math.floor((h - box_h) / 2)
        draw:fill(box_x, box_y, box_w, box_h, Theme.paper)
        local pad = Theme.s(6)
        local face = Theme.mono(opts.dense and "tiny" or "small")
        local text_w = math.max(1, box_w - pad * 2)
        local text = draw:para_box(book.title or "", face, text_w, 4, Theme.ink)
        local ty = box_y + box_h - pad - text.h
        if ty < box_y + pad then ty = box_y + pad end
        draw:place(text.widget, box_x + pad, ty)
    end

    draw:border(box_x, box_y, box_w, box_h, Theme.hair, Theme.ink)
    local side = Theme.s(opts.dense and 14 or 16)
    badge(draw, book.state or "remote",
        box_x + box_w - side - Theme.s(3), box_y + Theme.s(3), side)

    if opts.on_tap then
        draw:tap(box_x, box_y, box_w, box_h, opts.on_tap)
        local hit = draw.hits[#draw.hits]
        if hit then
            ensure_hold()
            hit.hold = function()
                show_menu(book, opts.on_tap)
            end
        end
    end
end

return Tile
