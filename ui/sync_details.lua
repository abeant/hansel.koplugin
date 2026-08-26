local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("ui.base")
local Catalog = require("lib.catalog")
local Parts = require("ui.parts")
local ProgressSync = require("lib.progress_sync")
local Queue = require("lib.sync_queue")
local Settings = require("lib.settings")
local Theme = require("ui.theme")

local Screen = Device.screen

local SyncDetails = {}

local Panel = Base:extend{
    name = "hansel_sync_details",
}

local function when(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return _("Never") end
    return os.date("%d %b %Y %H:%M", ts)
end

local function book_label(item)
    local book = Catalog.get_book and Catalog.get_book(item.book_id)
    if book and book.title and book.title ~= "" then return book.title end
    return T(_("Book %1"), tostring(item.book_id or "?"))
end

local function conflict_value(item)
    local remote = item.remote or {}
    local pct = tonumber(remote.percentage)
    if pct then
        return T(_("%1%% on Grimmory"), math.floor(pct * 1000 + 0.5) / 10)
    end
    return _("Waiting for a choice")
end

function Panel:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)

    local y = Parts.header(draw, {
        width = w,
        title = _("Auto sync"),
        left = {
            icon = "left",
            callback = function() self:onClose() end,
        },
    })
    draw:fill(0, y, w, Theme.hair, Theme.ash)
    y = y + Theme.hair

    local sync = ProgressSync.status()
    local pending = tonumber(sync.waiting) or Queue.count(Settings.account_key())
    local last_ok = sync.last_success or Settings.get("sync_last_success")
    local last_err = sync.last_error or Settings.get("sync_last_error")

    y = y + Parts.row(draw, 0, y, w, _("Pending"), {
        value = tostring(pending),
    })
    y = y + Parts.row(draw, 0, y, w, _("Last success"), {
        value = when(last_ok),
    })
    y = y + Parts.row(draw, 0, y, w, _("Last error"), {
        value = last_err and tostring(last_err) or _("None"),
    })
    y = y + Parts.row(draw, 0, y, w, _("Current sync service"), {
        value = sync.owner or _("Hansel"),
    })

    local conflicts = {}
    for _, item in ipairs(Queue.entries(Settings.account_key())) do
        if item.blocked then conflicts[#conflicts + 1] = item end
    end

    y = y + Parts.menu_separator(draw, 0, y, w)
    if #conflicts == 0 then
        Parts.row(draw, 0, y, w, _("Conflicts"), {
            value = _("None"),
        })
        return
    end

    y = y + Parts.row(draw, 0, y, w, _("Conflicts"), {
        value = tostring(#conflicts),
    })
    for _, item in ipairs(conflicts) do
        y = y + Parts.row(draw, 0, y, w, book_label(item), {
            value = conflict_value(item),
        })
        if y > h - Theme.row then break end
    end
end

function SyncDetails.show()
    UIManager:show(Panel:new{})
end

return SyncDetails
