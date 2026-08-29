local Device = require("device")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local API = require("lib.api")
local Base = require("ui.base")
local Origin = require("lib.origin")
local Parts = require("ui.parts")
local Paths = require("lib.paths")
local ProgressSync = require("lib.progress_sync")
local Settings = require("lib.settings")
local Session = require("lib.session")
local Theme = require("ui.theme")

local Screen = Device.screen
local S = Theme.s

local Account = Base:extend{
    name = "hansel_account",
    home = nil,
    on_authenticated = nil,
    on_changed = nil,
}

function Account:notify_changed()
    if self.on_changed then self.on_changed() end
end

function Account:maybe_offer_auto_sync()
    if Settings.get("auto_sync_offered") then return end
    Settings.set("auto_sync_offered", true)
    if Settings.get("auto_sync_enabled") == true then return end
    local sync = ProgressSync.status()
    if sync.stand_down then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Enable Auto sync to keep reading progress in sync with Grimmory?"),
        ok_text = _("Enable Auto sync"),
        cancel_text = _("Not now"),
        ok_callback = function()
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
                self:notify_changed()
                if not self._closed then self:rebuild("ui") end
            end)
        end,
        cancel_callback = function() end,
    })
end

function Account:setup()
    self.draft = {
        server = Settings.get("server_url") or "",
        user = Settings.get("t2_username") or Settings.get("t1_username") or "",
        password = "",
    }
    if Settings.has_tier2() then
        UIManager:nextTick(function()
            if self._closed then return end
            local online = NetworkMgr.isOnline and NetworkMgr:isOnline()
            if online then self:check_connection(false) else Session.mark_offline() end
        end)
    end
end

local function connection_label()
    local status = Session.status()
    if status.kind == "connected" then
        local age = math.max(0, os.time() - (tonumber(status.checked_at) or 0))
        if age < 60 then return _("Connected · checked just now") end
        return T(_("Connected · checked %1m ago"), math.floor(age / 60))
    end
    if status.kind == "checking" then return _("Checking…") end
    if status.kind == "auth_required" or status.kind == "forbidden" then
        return _("Sign-in required · reconnect")
    end
    if status.kind == "server_error" then return _("Grimmory unavailable · retry") end
    if status.kind == "offline" then return _("Offline · saved library available") end
    return _("Not checked")
end

function Account:check_connection(explicit)
    if self._checking or not Settings.has_tier2() then return end
    local function go()
        self._checking = true
        self:rebuild("ui")
        Trapper:wrap(function()
            if explicit then Trapper:info(_("Checking Grimmory…")) end
            local response = Session.check()
            if explicit then Trapper:clear() end
            self._checking = false
            if explicit and response.ok and self.home and self.home.reload then
                self.home:reload(true)
            end
            self:notify_changed()
            if not self._closed then self:rebuild("ui") end
        end)
    end
    if explicit and NetworkMgr.willRerunWhenOnline
            and NetworkMgr:willRerunWhenOnline(go) then
        return
    end
    if not explicit and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        Session.mark_offline()
        self:rebuild("ui")
        return
    end
    go()
end

local function ask(title, value, password, done)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        text_type = password and "password" or nil,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("OK"),
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    done(text)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Account:reconnect()
    local origin = Settings.server_url()
    local username = Settings.get("t2_username")
    if not origin or not username or username == "" then return end
    ask(_("Grimmory password"), "", true, function(password)
        if not password or password == "" then return end
        Trapper:wrap(function()
            Trapper:info(_("Reconnecting to Grimmory…"))
            local ok, _, response = API.test_tier2(origin, username, password)
            Trapper:clear()
            if not ok then
                local message = _("Could not reconnect. Check your password.")
                if response and response.error_kind == "offline" then
                    message = _("Could not reach Grimmory. Your saved library is still available.")
                elseif response and response.error_kind == "server_error" then
                    message = _("Grimmory is unavailable right now. Try again later.")
                end
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = message,
                    timeout = 4,
                })
                if not self._closed then self:rebuild("ui") end
                return
            end
            Settings.set_account(username, password)
            if response and response.body then
                Session.adopt(response.body, origin, username)
            end
            if self.home and self.home.reload then self.home:reload(true) end
            self:notify_changed()
            if not self._closed then self:rebuild("ui") end
        end)
    end)
end

function Account:build(draw)
    local w, h = Screen:getWidth(), Screen:getHeight()
    draw:fill(0, 0, w, h, Theme.paper)

    local header_h = Parts.header(draw, {
        width = w,
        title = _("Grimmory account"),
        left = {
            icon = "left",
            callback = function() self:onClose() end,
        },
    })

    local in_ = Settings.has_tier2()
    local y = header_h + S(28)
    local root = Paths.plugin_dir() or "."
    local lfs = require("libs/libkoreader-lfs")
    local logo = root .. "/assets/hansel-lockup.png"
    if not lfs.attributes(logo, "mode") then
        logo = root .. "/assets/grimmory-wordmark.jpg"
        if not lfs.attributes(logo, "mode") then
            logo = root .. "/assets/grimmory-wordmark.png"
        end
    end
    local logo_w = w - Theme.pad * 4
    local logo_h = S(44)
    if draw:image(logo, Theme.pad * 2, y, logo_w, logo_h) then
        y = y + logo_h + S(14)
    else
        draw:text_center(math.floor(w / 2), y, "Hansel", Theme.text("title"), Theme.ink, w - Theme.pad * 2)
        y = y + draw:label_height(Theme.text("title")) + S(14)
    end
    draw:text_center(math.floor(w / 2), y,
        in_ and connection_label() or _("Sign in to your library"),
        Theme.mono("small"), Theme.graphite, w - Theme.pad * 2)
    y = y + draw:label_height(Theme.mono("small")) + S(28)

    if in_ then
        draw:fill(0, y, w, Theme.hair, Theme.ash)
        y = y + Theme.hair
        y = y + Parts.row(draw, 0, y, w, _("Username"), {
            value = Settings.get("t2_username") or "",
        })
        y = y + Parts.row(draw, 0, y, w, _("Server"), {
            value = Settings.server_url() or "",
        })
        y = y + Parts.row(draw, 0, y, w, _("Connection"), {
            value = connection_label(),
            chevron = true,
            callback = function()
                local kind = Session.status().kind
                if kind == "auth_required" or kind == "forbidden" then
                    self:reconnect()
                else
                    self:check_connection(true)
                end
            end,
        })

        y = y + Parts.menu_separator(draw, 0, y, w)
        local sync = ProgressSync.status()
        local sync_opts = { value = sync.label }
        sync_opts.control = function(d, right, ry, rh)
            return Parts.switch(d, right, ry, rh, sync.enabled, function()
                if sync.enabled then
                    ProgressSync.set_enabled(false)
                    self:notify_changed()
                    self:rebuild("ui")
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
                    self:notify_changed()
                    if not self._closed then self:rebuild("ui") end
                end)
            end)
        end
        y = y + Parts.row(draw, 0, y, w, _("Auto sync"), sync_opts)
        if sync.owner then
            y = y + Parts.row(draw, 0, y, w, _("Current sync service"), {
                value = sync.owner,
            })
        end
        y = y + S(24)
        local bw = w - Theme.pad * 2
        Parts.button(draw, Theme.pad, y, bw, _("Sign out"), false, function()
            ProgressSync.set_enabled(false)
            Settings.clear_account()
            if self.home then self.home:reload() end
            self:notify_changed()
            self:rebuild("ui")
        end)
        return
    end

    local d = self.draft
    draw:fill(0, y, w, Theme.hair, Theme.ash)
    y = y + Theme.hair
    y = y + Parts.row(draw, 0, y, w, _("Server"), {
        value = d.server ~= "" and d.server or _("required"),
        chevron = true,
        callback = function()
            ask(_("Server"), d.server, false, function(v)
                self.draft.server = v
                self:rebuild("ui")
            end)
        end,
    })
    y = y + Parts.row(draw, 0, y, w, _("Username"), {
        value = d.user ~= "" and d.user or _("required"),
        chevron = true,
        callback = function()
            ask(_("Username"), d.user, false, function(v)
                self.draft.user = v
                self:rebuild("ui")
            end)
        end,
    })
    y = y + Parts.row(draw, 0, y, w, _("Password"), {
        value = d.password ~= "" and "••••••••" or _("required"),
        chevron = true,
        callback = function()
            ask(_("Password"), "", true, function(v)
                self.draft.password = v
                self:rebuild("ui")
            end)
        end,
    })
    y = y + S(24)
    Parts.button(draw, Theme.pad, y, w - Theme.pad * 2, _("Sign in"), true, function()
        self:submit()
    end)
end

function Account:submit()
    local origin = Origin.from_any(self.draft.server)
    if not origin or self.draft.user == "" or self.draft.password == "" then
        return
    end
    local function go()
        Trapper:wrap(function()
            Trapper:info(_("Signing in…"))
            local ok, _, response = API.test_tier2(origin, self.draft.user, self.draft.password)
            Trapper:clear()
            if not ok then
                require("ui/widget/infomessage")
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("Could not sign in. Check server and password."),
                    timeout = 4,
                })
                return
            end
            Settings.set_server_url(origin)
            Settings.set_account(self.draft.user, self.draft.password)
            if response and response.body then
                Session.adopt(response.body, origin, self.draft.user)
            end
            self.draft.password = ""
            if self.on_authenticated then
                self.on_authenticated()
            elseif self.home then
                self.home:reload(true)
            end
            self:notify_changed()
            self:rebuild("ui")
            self:maybe_offer_auto_sync()
        end)
    end
    if NetworkMgr.willRerunWhenOnline and NetworkMgr:willRerunWhenOnline(go) then
        return
    end
    go()
end

function Account.show(home, on_authenticated, on_changed)
    if Account._open and not Account._open._closed then
        UIManager:close(Account._open)
    end
    local screen = Account:new{
        home = home,
        on_authenticated = on_authenticated,
        on_changed = on_changed,
    }
    Account._open = screen
    UIManager:show(screen)
end

return Account
