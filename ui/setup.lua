local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local API = require("lib.api")
local Origin = require("lib.origin")
local Settings = require("lib.settings")

local Setup = {}

local function notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 3 })
end

local function run_online(fn)
    if NetworkMgr.willRerunWhenOnline and NetworkMgr:willRerunWhenOnline(fn) then
        return
    end
    fn()
end

function Setup.show_test_result(result)
    if result.tier2 then
        notify(_("Signed in to Grimmory."), 3)
    elseif result.tier1 then
        notify(_("OPDS library connected. Grimmory account is not signed in."), 4)
    else
        notify(T(_("Sign-in failed: %1"), result.tier2_msg or result.tier1_msg or _("unknown")), 5)
    end
end

function Setup.test_now(on_done)
    run_online(function()
        Trapper:wrap(function()
            Trapper:info(_("Testing connection…"))
            local result = API.test_connection()
            Trapper:clear()
            Setup.show_test_result(result)
            if on_done then on_done(result) end
        end)
    end)
end

function Setup.apply_opds(entry)
    local origin = Origin.from_any(entry.url)
    if not origin then
        notify(_("Could not parse that catalog URL."))
        return
    end
    Settings.set_server_url(origin)
    Settings.set("opds_url", entry.url)
    Settings.set_t1_credentials(entry.username or "", entry.password or "")
    notify(T(_("Using %1 as Grimmory."), entry.title or origin))
end

function Setup.prompt_tier2(on_done)
    Setup.show(on_done)
end

function Setup.manual(on_done)
    Setup.show(on_done)
end

function Setup.show(on_done, home)
    require("ui.account").show(home, on_done)
end

function Setup.confirm_if_needed(on_done, home)
    if Settings.can_browse() then
        if on_done then on_done() end
        return
    end
    require("ui.account").show(home, on_done)
end

return Setup
