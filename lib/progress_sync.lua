local Background = require("lib.background")
local CacheMap = require("lib.cache_map")
local DataStorage = require("datastorage")
local Event = require("ui/event")
local KosyncClient = require("lib.kosync_client")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Origin = require("lib.origin")
local Queue = require("lib.sync_queue")
local Session = require("lib.session")
local Settings = require("lib.settings")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local ProgressSync = {}

local PAGE_TRIGGER = 10
local DEBOUNCE_SECONDS = 10
local CONFLICT_DELTA = 0.005

local current
local busy = false
local periodic_task
local generation = 0
local native_auth_error = false
local worker_epoch = 0
local stand_down_cache
local stand_down_checked_at = 0

-- Link-level, not KOReader's internet DNS probe: a LAN-only Grimmory must
-- still sync.
local function online()
    if Session.network_available then return Session.network_available() end
    return NetworkMgr and NetworkMgr.isWifiOn and NetworkMgr:isWifiOn()
end

local function decode(body)
    return Session.decode_json(body)
end

local function plugin_enabled(name)
    local disabled = G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    if type(disabled) == "table" and disabled[name] then return false end
    if G_reader_settings and G_reader_settings.isTrue
            and G_reader_settings:isTrue("plugins_disable_external") then
        return false
    end
    local ok_loader, PluginLoader = pcall(require, "pluginloader")
    if ok_loader and PluginLoader and PluginLoader.isPluginLoaded then
        local ok, loaded = pcall(PluginLoader.isPluginLoaded, PluginLoader, name)
        if ok and loaded then return true end
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return false end
    local roots = { DataStorage:getDataDir() .. "/plugins" }
    local extra = G_reader_settings and G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra) == "string" then extra = { extra } end
    for _, root in ipairs(type(extra) == "table" and extra or {}) do
        roots[#roots + 1] = tostring(root):gsub("/+$", "")
    end
    for _, root in ipairs(roots) do
        local dir = root .. "/" .. name .. ".koplugin"
        if lfs.attributes(dir, "mode") == "directory" then return true end
    end
    return false
end

function ProgressSync.grimmory_plugin_active()
    return plugin_enabled("grimmory")
end

function ProgressSync.kosync_settings()
    local path = DataStorage:getSettingsDir() .. "/kosync.lua"
    local stored
    local ok, file = pcall(LuaSettings.open, LuaSettings, path)
    if ok and file then stored = file:readSetting("settings") end
    if type(stored) ~= "table" and G_reader_settings then
        stored = G_reader_settings:readSetting("kosync")
    end
    return type(stored) == "table" and stored or nil, path, file
end

function ProgressSync.stand_down_kind()
    local kind
    if ProgressSync.grimmory_plugin_active() then kind = "grimmory_plugin" end
    local kosync = ProgressSync.kosync_settings()
    local origin = Settings.server_url()
    local kosync_configured = kosync
        and (kosync.auto_sync or (kosync.username and kosync.userkey))
    if not kind and kosync_configured and kosync.custom_server and origin
            and Origin.host_matches_kosync(origin, kosync.custom_server) then
        kind = "kosync"
    end
    if kind and periodic_task then
        UIManager:unschedule(periodic_task)
        periodic_task = nil
    end
    stand_down_cache = kind or false
    stand_down_checked_at = os.time()
    return kind
end

local function current_stand_down_kind()
    if stand_down_checked_at == 0 or os.time() - stand_down_checked_at >= 30 then
        return ProgressSync.stand_down_kind()
    end
    return stand_down_cache or nil
end

local function account_key()
    return Settings.account_key()
end

function ProgressSync.status()
    local enabled = Settings.get("auto_sync_enabled") == true
    local stand_down = ProgressSync.stand_down_kind()
    local needs_reconnect = enabled
        and (native_auth_error or not Settings.has_sync_credentials())
    local active = enabled and not stand_down and not needs_reconnect
    local waiting = Queue.count(account_key())
    local label
    local owner
    if stand_down == "grimmory_plugin" then
        owner = _("Grimmory plugin")
    elseif stand_down == "kosync" then
        owner = _("KOReader Progress Sync")
    end
    -- `label` always describes Hansel's own switch. The competing sync owner is
    -- reported separately so an off switch can never look enabled merely
    -- because Grimmory's plugin is doing work.
    if not Settings.has_tier2() then
        label = _("Sign in first")
    elseif not enabled then
        label = _("Off")
    elseif stand_down then
        label = _("Paused")
    elseif needs_reconnect then
        label = _("On · reconnect required")
    elseif enabled and waiting > 0 then
        label = T(_("On · %1 waiting"), waiting)
    elseif enabled then
        label = _("On · up to date")
    else
        label = _("Off")
    end
    return {
        enabled = enabled,
        active = active,
        needs_reconnect = needs_reconnect,
        configured = enabled,
        stand_down = stand_down,
        owner = owner,
        waiting = waiting,
        label = label,
        actionable = Settings.has_tier2() and not stand_down,
    }
end

local function random_credentials()
    local md5 = require("ffi/sha2").md5
    local device_id = G_reader_settings and G_reader_settings:readSetting("device_id") or "device"
    local entropy
    local random = io.open("/dev/urandom", "rb")
    if random then
        entropy = random:read(32)
        random:close()
    end
    if type(entropy) ~= "string" or #entropy < 16 then entropy = nil end
    local seed = entropy or (tostring(device_id) .. ":" .. tostring(os.time())
        .. ":" .. tostring(math.random()))
    local first = md5(seed)
    local second = md5(seed .. ":password")
    return "hansel-" .. tostring(first):sub(1, 16), tostring(second)
end

function ProgressSync.configure_credentials()
    if not Settings.has_tier2() then return false, _("Sign in to Grimmory first.") end
    if not online() then return false, _("Connect to Wi-Fi to set up Auto sync.") end
    local response = require("lib.api").request("GET", "/api/v1/koreader-users/me", {
        preserve_connection = true,
    })
    local profile
    local created_username
    if response.ok then
        profile = decode(response.body)
    elseif response.status == 404 then
        local username, password = random_credentials()
        created_username = username
        response = require("lib.api").request("PUT", "/api/v1/koreader-users/me", {
            body = { username = username, password = password },
            preserve_connection = true,
        })
        if not response.ok then
            if response.error_kind == "auth_required" then
                return false, _("Reconnect your Grimmory account first.")
            elseif response.error_kind == "forbidden" then
                return false, _("This account needs KOReader Sync permission.")
            end
            return false, _("This Grimmory server cannot set up Auto sync.")
        end
        profile = decode(response.body) or {}
        profile.username = profile.username or created_username
        profile.password = profile.password or password
    else
        if response.error_kind == "auth_required" then
            return false, _("Reconnect your Grimmory account first.")
        elseif response.error_kind == "forbidden" then
            return false, _("This account needs KOReader Sync permission.")
        end
        return false, _("Could not reach Grimmory to set up Auto sync.")
    end
    if type(profile) ~= "table" or not profile.username then
        return false, _("Grimmory returned an invalid sync profile.")
    end
    if profile.syncEnabled == false
            or (created_username and profile.syncEnabled ~= true) then
        local enabled = require("lib.api").request("PATCH",
            "/api/v1/koreader-users/me/sync?enabled=true", {
                preserve_connection = true,
            })
        if not enabled.ok then
            if enabled.error_kind == "auth_required" then
                return false, _("Reconnect your Grimmory account first.")
            elseif enabled.error_kind == "forbidden" then
                return false, _("This account needs KOReader Sync permission.")
            end
            return false, _("Could not enable KOReader Sync in Grimmory.")
        end
    end
    local userkey = profile.passwordMD5
    if (not userkey or userkey == "") and profile.password then
        userkey = require("ffi/sha2").md5(profile.password)
    end
    if not userkey or userkey == "" then
        return false, _("Grimmory did not provide a native sync key.")
    end
    Settings.set_sync_credentials(profile.username, userkey)
    native_auth_error = false
    return true
end

function ProgressSync.set_enabled(enabled)
    enabled = enabled and true or false
    if not enabled then
        worker_epoch = worker_epoch + 1
        Settings.set("auto_sync_enabled", false)
        Queue.clear(account_key())
        native_auth_error = false
        if periodic_task then UIManager:unschedule(periodic_task) periodic_task = nil end
        return true
    end
    local stand_down = ProgressSync.stand_down_kind()
    if stand_down then return false, ProgressSync.status().label end
    local ok, err = ProgressSync.configure_credentials()
    if not ok then
        Settings.set("auto_sync_enabled", false)
        return false, err
    end
    Settings.set("auto_sync_enabled", true)
    worker_epoch = worker_epoch + 1
    ProgressSync.drain()
    return true
end

local function credentials()
    if not Settings.has_sync_credentials() then return nil end
    return {
        username = Settings.get("sync_username"),
        userkey = Settings.sync_key(),
    }
end

local function eligible()
    return Settings.get("auto_sync_enabled") == true
        and Settings.has_tier2()
        and not current_stand_down_kind()
end

local function clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function snapshot(ui, book_id, path)
    if not ui or not ui.document or not book_id then return nil end
    path = path or ui.document.file
    local has_pages = ui.document.info and ui.document.info.has_pages
    local module = has_pages and ui.paging or ui.rolling
    if not module then return nil end
    local ok_percent, percentage = pcall(module.getLastPercent, module)
    if not ok_percent or tonumber(percentage) == nil then return nil end
    percentage = clamp(percentage, 0, 1)
    local xpointer
    if not has_pages and module.getLastProgress then
        local ok_progress, progress = pcall(module.getLastProgress, module)
        if ok_progress and type(progress) == "string" and progress ~= "" then xpointer = progress end
    end
    local digest = ui.doc_settings and ui.doc_settings:readSetting("partial_md5_checksum")
    if not digest and path then
        local ok_util, util = pcall(require, "util")
        if ok_util and util.partialMD5 then digest = util.partialMD5(path) end
    end
    if not digest then return nil end
    local Device = require("device")
    local device_id = G_reader_settings and G_reader_settings:readSetting("device_id") or ""
    return {
        digest = digest,
        percentage = percentage,
        xpointer = xpointer,
        kind = has_pages and "paged" or "rolling",
        device = Device.model or "KOReader",
        device_id = device_id,
        captured_at = os.time(),
        path = path,
    }
end

local function current_snapshot()
    if not current then return nil end
    return snapshot(current.ui, current.book_id, current.path)
end

local function enqueue_current()
    local item = current_snapshot()
    if not item then return nil end
    return Queue.put(current.book_id, item, account_key())
end

local function remote_ahead(remote, local_item)
    return remote and tonumber(remote.percentage) and local_item
        and tonumber(remote.percentage) > (tonumber(local_item.percentage) or 0) + CONFLICT_DELTA
end

local function apply_remote(remote)
    if not current or not remote then return end
    current.suppress_next = true
    if current.kind == "rolling" and type(remote.progress) == "string" and remote.progress ~= "" then
        current.ui:handleEvent(Event:new("GotoXPointer", remote.progress))
    elseif current.kind == "rolling" then
        current.ui:handleEvent(Event:new("GotoPercent", clamp(remote.percentage, 0, 1) * 100))
    else
        local count = 1
        if current.ui.document.getPageCount then
            local ok, value = pcall(current.ui.document.getPageCount, current.ui.document)
            if ok then count = math.max(1, tonumber(value) or 1) end
        end
        local page = clamp(math.floor(clamp(remote.percentage, 0, 1) * count + 0.5), 1, count)
        current.ui:handleEvent(Event:new("GotoPage", page))
    end
    Queue.remove(current.book_id, nil, account_key())
end

local function show_conflict(remote)
    if not current or current.prompting then return end
    current.prompting = true
    local book_id = current.book_id
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Grimmory is further ahead (%1%%). Continue there or keep this device?"),
            math.floor((tonumber(remote.percentage) or 0) * 1000 + 0.5) / 10),
        ok_text = _("Continue from Grimmory"),
        ok_callback = function()
            if current and current.book_id == book_id then current.prompting = false end
            ProgressSync.resolve_conflict(book_id, "grimmory")
        end,
        cancel_text = _("Keep this device"),
        cancel_callback = function()
            if current and current.book_id == book_id then current.prompting = false end
            ProgressSync.resolve_conflict(book_id, "device")
        end,
    })
end

local function finish_worker(continue)
    busy = false
    if continue then UIManager:nextTick(function() ProgressSync.drain() end) end
end

local function native_auth_failed()
    Settings.clear_sync_credentials()
    native_auth_error = true
end

local function push_item(item, creds, epoch)
    if epoch ~= worker_epoch or not eligible() then
        finish_worker(false)
        return
    end
    local latest = Queue.get(item.book_id, account_key())
    if not latest or latest.sequence ~= item.sequence then
        finish_worker(true)
        return
    end
    Background.run(function() return KosyncClient.put(creds, item) end, function(ok_worker, response)
        if epoch ~= worker_epoch or not eligible() then
            finish_worker(false)
            return
        end
        if not ok_worker or type(response) ~= "table" then
            finish_worker(false)
            return
        end
        if response.ok then
            Queue.remove(item.book_id, item.sequence, account_key())
            finish_worker(true)
        else
            if response.error_kind == "auth_required" then native_auth_failed() end
            finish_worker(false)
        end
    end)
end

function ProgressSync.drain()
    if busy or not eligible() or not online() then return end
    local creds = credentials()
    if not creds then return end
    local item
    for _, candidate in ipairs(Queue.entries(account_key())) do
        if not candidate.blocked then item = candidate break end
    end
    if not item then return end
    busy = true
    local epoch = worker_epoch
    Background.run(function() return KosyncClient.get(creds, item.digest) end,
        function(ok_worker, response)
            if epoch ~= worker_epoch or not eligible() then
                finish_worker(false)
                return
            end
            if not ok_worker or type(response) ~= "table" then
                finish_worker(false)
                return
            end
            local latest = Queue.get(item.book_id, account_key())
            if not latest or latest.sequence ~= item.sequence then
                finish_worker(true)
                return
            end
            if response.ok then
                local remote = response.body or {}
                if remote_ahead(remote, item) and not item.keep_device then
                    Queue.mark_blocked(item.book_id, remote, account_key())
                    finish_worker(true)
                else
                    push_item(item, creds, epoch)
                end
            elseif response.error_kind == "not_found" then
                push_item(item, creds, epoch)
            else
                if response.error_kind == "auth_required" then native_auth_failed() end
                finish_worker(false)
            end
        end)
end

local function pull_current(gen)
    if not current or gen ~= generation or not eligible() or not online() then return end
    if busy then
        UIManager:scheduleIn(1, function() pull_current(gen) end)
        return
    end
    local creds = credentials()
    local local_item = current_snapshot()
    if not creds or not local_item then return end
    busy = true
    local epoch = worker_epoch
    Background.run(function() return KosyncClient.get(creds, local_item.digest) end,
        function(ok_worker, response)
            busy = false
            if epoch ~= worker_epoch or not eligible()
                    or not current or gen ~= generation then return end
            if not ok_worker or type(response) ~= "table" then return end
            local newest = current_snapshot() or local_item
            local queued = Queue.get(current.book_id, account_key())
            local keep_device = queued and queued.keep_device
            if response.ok and remote_ahead(response.body, newest) and not keep_device then
                local queued_item = Queue.put(current.book_id, newest, account_key())
                Queue.mark_blocked(current.book_id, response.body, account_key())
                if queued_item then show_conflict(response.body) end
                return
            end
            if response.ok or response.error_kind == "not_found" then
                if queued then Queue.put(current.book_id, newest, account_key()) end
                Queue.unblock(current.book_id, account_key())
                ProgressSync.drain()
            elseif response.error_kind == "auth_required" then
                native_auth_failed()
            end
        end)
end

local function schedule_periodic()
    if periodic_task then UIManager:unschedule(periodic_task) end
    periodic_task = function()
        periodic_task = nil
        if not current or not eligible() then return end
        current.page_count = 0
        enqueue_current()
        ProgressSync.drain()
    end
    UIManager:scheduleIn(DEBOUNCE_SECONDS, periodic_task)
end

function ProgressSync.on_reader_ready(ui)
    generation = generation + 1
    if periodic_task then UIManager:unschedule(periodic_task) periodic_task = nil end
    ProgressSync.stand_down_kind()
    if not eligible() or not ui or not ui.document then current = nil return end
    local path = ui.document.file
    -- Hansel opens mapped files by their recorded path. Avoid a whole-file hash
    -- on ReaderReady; moved files can be recovered by the normal cache rebuild.
    local book_id = CacheMap.id_for_path(path, false)
    if not book_id then current = nil return end
    local page
    if ui.getCurrentPage then
        local ok, value = pcall(ui.getCurrentPage, ui)
        if ok then page = value end
    end
    current = {
        ui = ui,
        path = path,
        book_id = tostring(book_id),
        kind = ui.document.info and ui.document.info.has_pages and "paged" or "rolling",
        last_page = page,
        page_count = 0,
    }
    local gen = generation
    UIManager:nextTick(function() pull_current(gen) end)
end

function ProgressSync.on_page_update(page)
    if not current or not eligible() or page == nil then return end
    if current.suppress_next then
        current.suppress_next = false
        current.last_page = page
        return
    end
    if current.last_page ~= page then
        current.last_page = page
        current.page_count = (current.page_count or 0) + 1
        if periodic_task or current.page_count >= PAGE_TRIGGER then schedule_periodic() end
    end
end

function ProgressSync.on_suspend()
    if not current or not eligible() then return end
    if periodic_task then UIManager:unschedule(periodic_task) periodic_task = nil end
    current.page_count = 0
    enqueue_current()
end

function ProgressSync.on_close_document()
    if current and eligible() then enqueue_current() end
    generation = generation + 1
    if periodic_task then UIManager:unschedule(periodic_task) periodic_task = nil end
    current = nil
end

function ProgressSync.on_network_connected()
    ProgressSync.stand_down_kind()
    if not eligible() then return end
    if current then
        local gen = generation
        UIManager:nextTick(function() pull_current(gen) end)
    else
        ProgressSync.drain()
    end
end

function ProgressSync.note_open(book_id, path)
    if book_id and path then CacheMap.mark_opened(book_id, path) end
end

function ProgressSync.blocked_conflicts()
    local blocked = {}
    for _, item in ipairs(Queue.entries(account_key())) do
        if item.blocked then blocked[#blocked + 1] = item end
    end
    return blocked
end

function ProgressSync.resolve_conflict(book_id, choice)
    if not book_id then return false end
    book_id = tostring(book_id)
    local item = Queue.get(book_id, account_key())
    if not item or not item.blocked then return false end
    if choice == "grimmory" then
        if current and current.book_id == book_id then
            apply_remote(item.remote)
        else
            Queue.remove(book_id, nil, account_key())
        end
        ProgressSync.drain()
        return true
    end
    if choice == "device" then
        local snapshot_item = (current and current.book_id == book_id and current_snapshot()) or item
        snapshot_item.keep_device = true
        Queue.put(book_id, snapshot_item, account_key())
        Queue.unblock(book_id, account_key())
        ProgressSync.drain()
        return true
    end
    return false
end

return ProgressSync
