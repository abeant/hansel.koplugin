local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Base = require("ui.base")
local Center = require("lib.download_center")
local Parts = require("ui.parts")
local Theme = require("ui.theme")

local Screen = Device.screen

local Downloads = {}

local Panel = Base:extend{
    name = "hansel_downloads",
}

function Panel:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)
    local y = Parts.header(draw, {
        width = w,
        title = _("Downloads"),
        left = { icon = "close", callback = function() UIManager:close(self) end },
    })
    local items = Center.list()
    if #items == 0 then
        Parts.row(draw, 0, y, w, _("Nothing queued"))
        return
    end
    for _, item in ipairs(items) do
        local book = item.book or {}
        y = y + Parts.row(draw, 0, y, w, book.title or _("Untitled"), {
            value = item.status or "",
            callback = item.status == "failed" and function()
                Center.retry(book.id)
                self:rebuild("ui")
            end or nil,
        })
        if y > h - Theme.row then break end
    end
end

function Downloads.show()
    UIManager:show(Panel:new{})
end

Downloads.enqueue = function(_, book, opts)
    return Center.enqueue(book, opts)
end

return Downloads
