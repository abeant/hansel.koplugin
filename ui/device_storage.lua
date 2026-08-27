local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("ui.base")
local CacheMap = require("lib.cache_map")
local Covers = require("lib.covers")
local Fmt = require("lib.fmt")
local Parts = require("ui.parts")
local Theme = require("ui.theme")

local Screen = Device.screen

local DeviceStorage = {}

local Panel = Base:extend{
    name = "hansel_device_storage",
}

local function toast(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

local function book_bytes(entry)
    if not entry then return 0 end
    return tonumber(entry.bytes) or tonumber(entry.file_size) or 0
end

local function snapshot()
    local map = CacheMap.load and CacheMap.load() or nil
    local books = (map and map.books) or {}
    local cached, pinned, unpinned_bytes = 0, 0, 0
    local rows = {}
    for id, entry in pairs(books) do
        if entry.path then
            cached = cached + 1
            local bytes = book_bytes(entry)
            if entry.pinned then
                pinned = pinned + 1
            else
                unpinned_bytes = unpinned_bytes + bytes
            end
            local title
            if CacheMap.get then
                local live = CacheMap.get(id)
                title = live and live.title
            end
            rows[#rows + 1] = {
                id = tostring(id),
                title = title or (entry.path:match("([^/]+)$") or tostring(id)),
                bytes = bytes,
                pinned = entry.pinned and true or false,
            }
        end
    end
    if CacheMap.local_books then
        local ok, listed = pcall(CacheMap.local_books)
        if ok and type(listed) == "table" then
            local by_id = {}
            for _, row in ipairs(rows) do by_id[row.id] = row end
            for _, book in ipairs(listed) do
                local id = tostring(book.id or "")
                local row = by_id[id]
                if row then
                    row.title = book.title or row.title
                    if (not row.bytes or row.bytes == 0) and book.file_size then
                        row.bytes = tonumber(book.file_size) or row.bytes
                    end
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        return (a.title or "") < (b.title or "")
    end)
    local covers = 0
    if Covers.usage_bytes then covers = tonumber(Covers.usage_bytes()) or 0 end
    local files = 0
    if CacheMap.usage_bytes then files = tonumber(CacheMap.usage_bytes()) or 0 end
    return {
        cached = cached,
        pinned = pinned,
        files = files,
        covers = covers,
        reclaimable = unpinned_bytes + covers,
        rows = rows,
    }
end

function Panel:clear_covers()
    UIManager:show(ConfirmBox:new{
        text = _("Clear cached covers? They will download again when needed."),
        ok_text = _("Clear"),
        ok_callback = function()
            if type(Covers.clear) == "function" then
                Covers.clear()
                toast(_("Cover cache cleared."))
            else
                toast(_("Cover cache clear is not available yet."))
            end
            if not self._closed then self:rebuild("ui") end
        end,
    })
end

function Panel:remove_unpinned()
    UIManager:show(ConfirmBox:new{
        text = _("Remove unpinned downloads? Pinned books stay on this device."),
        ok_text = _("Remove"),
        ok_callback = function()
            if type(CacheMap.free_unpinned) == "function" then
                CacheMap.free_unpinned()
            elseif type(CacheMap.remove) == "function" then
                local map = CacheMap.load and CacheMap.load() or nil
                for id, entry in pairs((map and map.books) or {}) do
                    if entry.path and not entry.pinned then
                        CacheMap.remove(id, true)
                    end
                end
            end
            toast(_("Unpinned downloads removed."))
            if not self._closed then self:rebuild("ui") end
        end,
    })
end

function Panel:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)

    local y = Parts.header(draw, {
        width = w,
        title = _("On this device"),
        left = {
            icon = "left",
            callback = function() self:onClose() end,
        },
    })
    draw:fill(0, y, w, Theme.hair, Theme.ash)
    y = y + Theme.hair

    local snap = snapshot()
    y = y + Parts.row(draw, 0, y, w, _("Downloaded books"), {
        value = tostring(snap.cached),
    })
    y = y + Parts.row(draw, 0, y, w, _("Book files"), {
        value = Fmt.bytes(snap.files),
    })
    y = y + Parts.row(draw, 0, y, w, _("Cover cache"), {
        value = Fmt.bytes(snap.covers),
    })
    y = y + Parts.row(draw, 0, y, w, _("Pinned books"), {
        value = tostring(snap.pinned),
    })
    y = y + Parts.row(draw, 0, y, w, _("Reclaimable"), {
        value = Fmt.bytes(snap.reclaimable),
    })

    y = y + Parts.menu_separator(draw, 0, y, w)
    local btn_w = w - Theme.pad * 2
    y = y + Parts.button(draw, Theme.pad, y, btn_w, _("Clear cover cache"), false, function()
        self:clear_covers()
    end)
    y = y + Theme.gap
    y = y + Parts.button(draw, Theme.pad, y, btn_w, _("Remove unpinned downloads"), false, function()
        self:remove_unpinned()
    end)

    if #snap.rows > 0 then
        y = y + Parts.menu_separator(draw, 0, y, w)
        -- Do not use `_` as the loop index: it shadows gettext and the first
        -- downloaded book used to crash layout (blank fullscreen tap-eater).
        local pinned_l = _("pinned")
        local unpinned_l = _("unpinned")
        local row_fmt = _("%1 · %2")
        for i = 1, #snap.rows do
            local row = snap.rows[i]
            if y + Theme.icon > h then break end
            local suffix = row.pinned and pinned_l or unpinned_l
            y = y + Parts.row(draw, 0, y, w, row.title, {
                value = T(row_fmt, Fmt.bytes(row.bytes), suffix),
            })
        end
    end
end

function DeviceStorage.show()
    UIManager:show(Panel:new{})
end

return DeviceStorage
