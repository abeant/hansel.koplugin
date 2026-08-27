local Device = require("device")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local _ = require("gettext")

local Base = require("ui.base")
local Parts = require("ui.parts")
local Search = require("lib.search")
local Theme = require("ui.theme")

local Screen = Device.screen

local SearchUI = {}

local Panel = Base:extend{
    name = "hansel_search",
    query = "",
    hits = nil,
}

function Panel:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)
    local y = Parts.header(draw, {
        width = w,
        title = _("Search"),
        left = { icon = "close", callback = function() UIManager:close(self) end },
        right = {{
            icon = "filter",
            callback = function() self:ask() end,
        }},
    })
    local q = self.query or ""
    y = y + Parts.row(draw, 0, y, w, q ~= "" and q or _("Tap to search"), {
        callback = function() self:ask() end,
    })
    local untitled = _("Untitled")
    local hits = self.hits or {}
    for i = 1, #hits do
        local book = hits[i]
        y = y + Parts.row(draw, 0, y, w, book.title or untitled, {
            value = type(book.authors) == "table" and table.concat(book.authors, ", ") or tostring(book.authors or ""),
            callback = function()
                local home = self.home
                if home and home.open_book then home:open_book(book) end
            end,
        })
        if y > h - Theme.row then break end
    end
end

function Panel:ask()
    local dialog
    dialog = InputDialog:new{
        title = _("Search library"),
        input = self.query or "",
        buttons = {{
            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                self.query = dialog:getInputText() or ""
                self.hits = Search.query(self.query)
                UIManager:close(dialog)
                self:rebuild("ui")
            end },
        }},
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then dialog:onShowKeyboard() end
end

function SearchUI.show(home)
    UIManager:show(Panel:new{ home = home, hits = {} })
end

return SearchUI
