local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Base = require("ui.base")
local Filter = require("ui.filter")
local Parts = require("ui.parts")
local Settings = require("lib.settings")
local Theme = require("ui.theme")

local Screen = Device.screen

local LibrarySettings = {}

local Panel = Base:extend{
    name = "hansel_library_settings",
    home = nil,
    on_changed = nil,
}

function Panel:notify_changed()
    if self.on_changed then self.on_changed() end
end

function Panel:refresh_home()
    if self.home and self.home.reload then self.home:reload() end
end

function Panel:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)

    local y = Parts.header(draw, {
        width = w,
        title = _("Library"),
        left = {
            icon = "left",
            callback = function() self:onClose() end,
        },
    })
    draw:fill(0, y, w, Theme.hair, Theme.ash)
    y = y + Theme.hair

    local hide = Settings.hide_unavailable()
    y = y + Parts.row(draw, 0, y, w, _("Hide unavailable books"), {
        help = _("When this device can't reach Grimmory, only show books already on it."),
        control = function(d, right, ry, rh)
            return Parts.switch(d, right, ry, rh, hide, function()
                Settings.set("hide_unavailable", not hide)
                self:refresh_home()
                self:notify_changed()
                self:rebuild("ui")
            end)
        end,
    })

    local prefetch = Settings.get("prefetch_next_page_covers") and true or false
    y = y + Parts.row(draw, 0, y, w, _("Prefetch next page covers"), {
        control = function(d, right, ry, rh)
            return Parts.switch(d, right, ry, rh, prefetch, function()
                Settings.set("prefetch_next_page_covers", not prefetch)
                self:notify_changed()
                self:rebuild("ui")
            end)
        end,
    })

    local density = Settings.get("grid_density") or "3x3"
    y = y + Parts.row(draw, 0, y, w, _("Grid density"), {
        control = function(d, right, ry, rh)
            local items = {}
            local labels = { ["3x3"] = _("Comfortable"), ["4x4"] = _("Compact"), ["5x4"] = _("Dense") }
            for _, key in ipairs({ "3x3", "4x4", "5x4" }) do
                items[#items + 1] = {
                    label = labels[key],
                    on = key == density,
                    callback = function()
                        Settings.set("grid_density", key)
                        if self.home and self.home.set_density then
                            self.home:set_density(key)
                        end
                        self:notify_changed()
                        self:rebuild("ui")
                    end,
                }
            end
            return Parts.segmented(d, right, ry, rh, items)
        end,
    })

    y = y + Parts.menu_separator(draw, 0, y, w)
    Parts.row(draw, 0, y, w, _("Reset filters and sort"), {
        callback = function()
            Filter.reset()
            self:refresh_home()
            self:notify_changed()
            self:rebuild("ui")
        end,
    })
end

function LibrarySettings.show(home, on_changed)
    UIManager:show(Panel:new{ home = home, on_changed = on_changed })
end

return LibrarySettings
