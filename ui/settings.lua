local Device = require("device")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("ui.base")
local CacheMap = require("lib.cache_map")
local Parts = require("ui.parts")
local ProgressSync = require("lib.progress_sync")
local Settings = require("lib.settings")
local Session = require("lib.session")
local Theme = require("ui.theme")

local Screen = Device.screen

local VERSION = "0.3.0"

local SettingsUI = {}

local Panel = Base:extend{
    name = "hansel_settings",
    home = nil,
}

local function downloaded_count()
    local count = 0
    local map = CacheMap.load and CacheMap.load() or nil
    for _, entry in pairs((map and map.books) or {}) do
        if entry.path then count = count + 1 end
    end
    return count
end

local function connection_value(kind)
    if kind == "connected" then return _("Connected") end
    if kind == "auth_required" or kind == "forbidden" then return _("Sign-in required") end
    if kind == "server_error" then return _("Server unavailable") end
    if kind == "offline" then return _("Offline") end
    if kind == "checking" then return _("Checking…") end
    return _("Not checked")
end

function SettingsUI.toggle_auto_sync(host, sync)
    sync = sync or ProgressSync.status()
    local function finish()
        if host.notify_changed then host:notify_changed() end
        if not host._closed then host:rebuild("ui") end
    end
    if sync.enabled then
        ProgressSync.set_enabled(false)
        finish()
        return
    end
    if sync.stand_down then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = T(_("Hansel Auto sync is off while %1 is active. Disable it first."),
                sync.owner or _("another sync service")),
            timeout = 5,
        })
        return
    end
    Trapper:wrap(function()
        Trapper:info(_("Setting up Auto sync…"))
        local ok, err = ProgressSync.set_enabled(true)
        Trapper:clear()
        if not ok then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = tostring(err or _("Could not enable Auto sync.")),
                timeout = 5,
            })
        end
        finish()
    end)
end

function SettingsUI.auto_sync_opts(host)
    local sync = ProgressSync.status()
    return {
        value = sync.label or (sync.enabled and _("On") or _("Off")),
        control = function(d, right, ry, rh)
            return Parts.switch(d, right, ry, rh, sync.enabled, function()
                SettingsUI.toggle_auto_sync(host, sync)
            end)
        end,
    }, sync
end

function Panel:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)

    local y = Parts.header(draw, {
        width = w,
        title = _("Settings"),
        subtitle = T(_("Hansel %1"), VERSION),
        left = {
            icon = "left",
            callback = function() self:onClose() end,
        },
    })

    local origin = Settings.server_url()
    local session = Session.status()

    draw:fill(0, y, w, Theme.hair, Theme.ash)
    y = y + Theme.hair
    y = y + Parts.row(draw, 0, y, w, _("Server"), {
        value = (origin ~= nil and origin ~= "") and origin or _("Not set"),
    })
    y = y + Parts.row(draw, 0, y, w, _("Connection"), {
        value = connection_value(session.kind),
    })
    y = y + Parts.row(draw, 0, y, w, _("Auto sync"), SettingsUI.auto_sync_opts(self))
    y = y + Parts.menu_separator(draw, 0, y, w)
    y = y + Parts.row(draw, 0, y, w, _("Grimmory account"), {
        icon = "person",
        value = Settings.has_tier2() and (Settings.get("t2_username") or _("signed in")) or _("sign in"),
        chevron = true,
        callback = function()
            require("ui.account").show(self.home, nil, function()
                if not self._closed then self:rebuild("ui") end
            end)
        end,
    })
    y = y + Parts.row(draw, 0, y, w, _("Library"), {
        icon = "grid",
        chevron = true,
        callback = function()
            require("ui.library_settings").show(self.home, function()
                if not self._closed then self:rebuild("ui") end
            end)
        end,
    })
    y = y + Parts.row(draw, 0, y, w, _("On this device"), {
        icon = "tray",
        value = T(_("%1 books"), downloaded_count()),
        chevron = true,
        callback = function()
            require("ui.device_storage").show()
        end,
    })
end

function SettingsUI.show(home)
    UIManager:show(Panel:new{ home = home })
end

return SettingsUI
