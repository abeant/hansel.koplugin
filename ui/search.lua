local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local _ = require("gettext")

local Base = require("ui.base")
local Parts = require("ui.parts")
local Search = require("lib.search")
local Theme = require("ui.theme")

local Screen = Device.screen
local S = Theme.s

local KINDS = {
    { id = "books", text = _("Books") },
    { id = "authors", text = _("Authors") },
    { id = "tags", text = _("Tags") },
    { id = "categories", text = _("Categories") },
}

local TITLES = {
    books = _("Search books"),
    authors = _("Search authors"),
    tags = _("Search tags"),
    categories = _("Search categories"),
}

local SearchUI = {}

local Results = Base:extend{
    name = "hansel_search_results",
    covers_fullscreen = false,
    wants_swipe = true,
    home = nil,
    query = "",
    kind = "books",
    hits = nil,
}

function Results:setup()
    local h = Screen:getHeight()
    local top = math.max(S(16), math.floor(h * 0.24))
    self.panel = Geom:new{ x = 0, y = top, w = Screen:getWidth(), h = h - top }
    self.top = top
    self.scroll = 0
    self.kind = self.kind or "books"
    self.hits = self.hits or {}
end

function Results:_open(hit)
    local home = self.home
    self:onClose()
    if not home then return end
    if hit.kind == "book" and hit.book and home.open_detail then
        home:open_detail(hit.book)
    elseif hit.href and home.open_feed then
        home:open_feed(hit.href, hit.title)
    elseif home.set_view and self.kind ~= "books" then
        home:set_view(self.kind)
    end
end

function Results:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    local top = self.top or self.panel.y
    draw:fill(0, top, w, h - top, Theme.paper)
    draw:rule(0, top, w, Theme.rule)

    local head_y = top + Theme.rule
    local header_h = Parts.header(draw, {
        y = head_y,
        width = w,
        title = TITLES[self.kind] or _("Search"),
        right = {{
            icon = "close",
            callback = function() self:onClose() end,
        }},
    })
    local body_top = head_y + header_h
    local hits = self.hits or {}
    local face_h = draw:label_height(Theme.mono())
    local row_h = face_h + S(11) * 2
    local untitled = _("Untitled")
    if #hits == 0 then
        draw:text(Theme.pad, body_top + S(16), _("No matches"),
            Theme.mono(), Theme.ink, w - Theme.pad * 2)
    else
        local max_scroll = math.max(0, #hits * row_h - (h - body_top))
        if (self.scroll or 0) > max_scroll then self.scroll = max_scroll end
        self._max_scroll = max_scroll
        local scroll = self.scroll or 0
        for i = 1, #hits do
            local hit = hits[i]
            local iy = body_top + (i - 1) * row_h - scroll
            if iy + row_h > body_top and iy < h then
                local value = hit.why or ""
                if hit.kind == "book" and hit.book then
                    local authors = hit.book.authors
                    if type(authors) == "table" then
                        value = (hit.why or "") .. " · " .. table.concat(authors, ", ")
                    elseif authors then
                        value = (hit.why or "") .. " · " .. tostring(authors)
                    end
                elseif hit.count then
                    value = tostring(hit.count)
                end
                local item = hit
                Parts.row(draw, 0, iy, w, item.title or untitled, {
                    value = value,
                    callback = function() self:_open(item) end,
                })
            end
        end
    end

    draw:fill(0, top, w, body_top - top, Theme.paper)
    draw:rule(0, top, w, Theme.rule)
    Parts.header(draw, {
        y = head_y,
        width = w,
        title = TITLES[self.kind] or _("Search"),
        right = {{
            icon = "close",
            callback = function() self:onClose() end,
        }},
    })
    draw:rule(0, body_top - Theme.hair, w, Theme.hair)
end

function Results:onSwipe(_, ges)
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

function Results:onTapOutside(ges)
    if ges and ges.pos and ges.pos.y < (self.top or 0) then
        self:onClose()
    end
    return true
end

local function require_ok(name)
    local ok, mod = pcall(require, name)
    if ok then return mod end
    return nil
end

function SearchUI.show_results(home, query, kind, hits)
    kind = kind or "books"
    UIManager:show(Results:new{
        home = home,
        query = query or "",
        kind = kind,
        hits = hits or Search.find(query or "", kind),
    })
end

function SearchUI.show(home)
    local kind = "books"
    local dialog
    dialog = InputDialog:new{
        title = _("Search"),
        input = "",
        input_hint = TITLES[kind],
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    SearchUI.show_results(home, q, kind)
                end,
            },
        }},
    }

    local Button = require_ok("ui/widget/button")
    local HorizontalGroup = require_ok("ui/widget/horizontalgroup")
    local VerticalGroup = require_ok("ui/widget/verticalgroup")
    local VerticalSpan = require_ok("ui/widget/verticalspan")
    local HorizontalSpan = require_ok("ui/widget/horizontalspan")
    local LineWidget = require_ok("ui/widget/linewidget")
    local CenterContainer = require_ok("ui/widget/container/centercontainer")
    local Size = require_ok("ui/size")
    local Blitbuffer = require_ok("ffi/blitbuffer")
    if dialog.vgroup and Button and HorizontalGroup and VerticalGroup
            and VerticalSpan and CenterContainer then
        local width = dialog.width or math.floor(Screen:getWidth() * 0.8)
        local gap = (Size and Size.padding and Size.padding.small) or 6
        local pad = (Size and Size.padding and Size.padding.default) or 10
        local cell = math.floor((width - pad * 2 - gap * (#KINDS - 1)) / #KINDS)
        local rule_h = Screen:scaleBySize(2)
        local rule_inset = Screen:scaleBySize(6)
        local chip_btns = {}
        local chip_rules = {}
        local row = HorizontalGroup:new{ align = "bottom" }
        local function mark_selected()
            for i = 1, #KINDS do
                local opt = KINDS[i]
                local on = kind == opt.id
                local btn = chip_btns[opt.id]
                local rule = chip_rules[opt.id]
                if btn and btn.setFontBold then
                    btn:setFontBold(on)
                end
                if rule then
                    rule.background = on
                        and (Blitbuffer and Blitbuffer.COLOR_BLACK or "black")
                        or (Blitbuffer and Blitbuffer.COLOR_WHITE or "white")
                    if rule.update then rule:update() end
                end
            end
            if dialog.refreshButtons then dialog:refreshButtons() end
        end
        for i = 1, #KINDS do
            local opt = KINDS[i]
            if i > 1 then
                row[#row + 1] = (HorizontalSpan or VerticalSpan):new{ width = gap }
            end
            local id = opt.id
            local btn = Button:new{
                text = opt.text,
                width = cell,
                bordersize = 0,
                radius = 0,
                margin = 0,
                padding = 6,
                text_font_bold = id == kind,
                callback = function()
                    kind = id
                    if dialog._input_widget then
                        dialog._input_widget.hint = TITLES[kind]
                    end
                    mark_selected()
                end,
            }
            chip_btns[id] = btn
            local rule
            if LineWidget and Blitbuffer then
                rule = LineWidget:new{
                    background = id == kind and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    dimen = Geom:new{ w = math.max(rule_h, cell - rule_inset * 2), h = rule_h },
                }
            else
                rule = VerticalSpan:new{ width = rule_h }
            end
            chip_rules[id] = rule
            row[#row + 1] = VerticalGroup:new{
                align = "center",
                btn,
                VerticalSpan:new{ width = 2 },
                rule,
            }
        end
        local chips = CenterContainer:new{
            dimen = Geom:new{ w = width, h = row:getSize().h + pad * 2 },
            VerticalGroup:new{
                align = "center",
                VerticalSpan:new{ width = pad },
                row,
                VerticalSpan:new{ width = pad },
            },
        }
        local at
        local input = dialog._input_widget
        for i, child in ipairs(dialog.vgroup) do
            if child == input or (child[1] == input) then
                at = i
                break
            end
        end
        table.insert(dialog.vgroup, at or 2, chips)
        if dialog.vgroup.resetLayout then
            dialog.vgroup:resetLayout()
        end
        if dialog.dialog_frame then
            dialog.dialog_frame.dimen = nil
        end
    end

    local orig_tap = dialog.onTap
    function dialog:onTap(arg, ges)
        if ges and ges.pos and self.dialog_frame and self.dialog_frame.dimen
                and ges.pos.notIntersectWith
                and ges.pos:notIntersectWith(self.dialog_frame.dimen) then
            local kb = self._input_widget and self._input_widget.keyboard
            if kb and kb.dimen and ges.pos.notIntersectWith
                    and not ges.pos:notIntersectWith(kb.dimen) then
                if orig_tap then return orig_tap(self, arg, ges) end
                return
            end
            UIManager:close(self)
            return true
        end
        if orig_tap then return orig_tap(self, arg, ges) end
    end

    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        dialog:onShowKeyboard()
    end
end

return SearchUI
