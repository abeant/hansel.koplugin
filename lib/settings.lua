local LuaSettings = require("luasettings")
local Obfuscate = require("lib.obfuscate")
local Paths = require("lib.paths")
local Origin = require("lib.origin")

local DENSITIES = {
    ["3x3"] = { cols = 3, rows = 3 },
    ["4x4"] = { cols = 4, rows = 4 },
    ["5x4"] = { cols = 5, rows = 4 },
    ["2x3"] = { cols = 3, rows = 3 },
    ["3x4"] = { cols = 3, rows = 3 },
    ["4x5"] = { cols = 4, rows = 4 },
}

local DEFAULTS = {
    server_url = "",
    opds_url = "",
    t1_username = "",
    t1_secret = "",
    t2_username = "",
    t2_secret = "",
    t2_refresh_secret = "",
    t2_token_expires_at = 0,
    t2_token_origin = "",
    t2_token_user = "",
    auto_sync_enabled = false,
    sync_username = "",
    sync_key_secret = "",
    sync_origin = "",
    sync_account = "",
    grid_density = "3x3",
    cover_budget_bytes = 1024 * 1024 * 1024,
    download_dir = "",
    prefetch_next_page_covers = false,
    library_totals = {},
    last_view = "all",
    last_page = 1,
    last_filter = "all",
    hide_unavailable = true,
}

local Settings = {
    DENSITIES = DENSITIES,
}

local CRITICAL_KEYS = {
    t1_username = true,
    t1_secret = true,
    t2_username = true,
    t2_secret = true,
    t2_refresh_secret = true,
    t2_token_expires_at = true,
    t2_token_origin = true,
    t2_token_user = true,
    sync_username = true,
    sync_key_secret = true,
    sync_origin = true,
    sync_account = true,
}

local _file
local _data

local function salt()
    local id = G_reader_settings and G_reader_settings:readSetting("device_id")
    -- Historical fallback; changing it would break secrets encoded without device_id.
    return type(id) == "string" and id or "dork"
end

local function open()
    if _file then return _file end
    Paths.ensure_data_dirs()
    _file = LuaSettings:open(Paths.settings_file())
    local stored = _file:readSetting("hansel") or _file:readSetting("dork") or {}
    _data = {}
    -- Keep extension/dynamic keys (filters, sort, migration fields) instead of
    -- silently dropping anything not present in DEFAULTS on every restart.
    for k, v in pairs(stored) do _data[k] = v end
    for k, v in pairs(DEFAULTS) do
        if _data[k] == nil then
            _data[k] = v
        end
    end
    return _file
end

function Settings.load()
    open()
    return _data
end

function Settings.flush()
    open()
    _file:saveSetting("hansel", _data)
    if _file.delSetting then
        _file:delSetting("dork")
    elseif type(_file.data) == "table" then
        _file.data.dork = nil
    end
    _file:flush()
end

function Settings.get(key)
    open()
    return _data[key]
end

function Settings.set(key, value)
    open()
    -- Scalars that did not change are not worth a synchronous disk write.
    -- Tables may have been mutated in place, so they always flush.
    if type(value) ~= "table" and _data[key] == value then return end
    _data[key] = value
    Settings.flush()
end

function Settings.update(values)
    if type(values) ~= "table" then return end
    open()
    local critical = false
    for key, value in pairs(values) do
        _data[key] = value
        if CRITICAL_KEYS[key] then
            critical = true
        end
    end
    Settings.flush()
    return critical
end

function Settings.server_url()
    return Origin.from_any(Settings.get("server_url") or "")
end

function Settings.set_server_url(url)
    local previous = Settings.server_url()
    local origin = Origin.from_any(url)
    Settings.set("server_url", origin or "")
    if origin and (not Settings.get("opds_url") or Settings.get("opds_url") == "") then
        Settings.set("opds_url", Origin.opds_root(origin))
    end
    if previous and previous ~= origin then
        Settings.clear_tokens()
        Settings.clear_sync_credentials()
        Settings.set("auto_sync_enabled", false)
        pcall(function() require("lib.session").reset() end)
    end
end

function Settings.has_tier1()
    local url = Settings.server_url()
    local user = Settings.get("t1_username") or ""
    return url ~= nil and url ~= "" and user ~= ""
end

function Settings.has_tier2()
    local user = Settings.get("t2_username") or ""
    local secret = Settings.t2_password()
    return user ~= "" and secret ~= ""
end

function Settings.can_browse()
    return Settings.has_tier1() or Settings.has_tier2()
end

function Settings.set_account(username, password)
    Settings.set_t2_credentials(username, password)
end

function Settings.t1_password()
    return Obfuscate.decode(Settings.get("t1_secret"), salt())
end

function Settings.set_t1_credentials(username, password)
    Settings.update({
        t1_username = username or "",
        t1_secret = Obfuscate.encode(password or "", salt()),
    })
end

function Settings.t2_password()
    return Obfuscate.decode(Settings.get("t2_secret"), salt())
end

function Settings.set_t2_credentials(username, password)
    local previous = Settings.get("t2_username") or ""
    Settings.update({
        t2_username = username or "",
        t2_secret = Obfuscate.encode(password or "", salt()),
    })
    Settings.clear_tokens()
    if previous ~= "" and previous ~= (username or "") then
        Settings.clear_sync_credentials()
        Settings.set("auto_sync_enabled", false)
    end
    pcall(function() require("lib.session").reset() end)
end

function Settings.refresh_token()
    return Obfuscate.decode(Settings.get("t2_refresh_secret"), salt())
end

function Settings.set_tokens(refresh_token, expires_at, origin, username)
    Settings.update({
        t2_refresh_secret = Obfuscate.encode(refresh_token or "", salt()),
        t2_token_expires_at = tonumber(expires_at) or 0,
        t2_token_origin = Origin.from_any(origin) or "",
        t2_token_user = username or "",
    })
end

function Settings.clear_tokens()
    Settings.update({
        t2_refresh_secret = "",
        t2_token_expires_at = 0,
        t2_token_origin = "",
        t2_token_user = "",
    })
end

function Settings.account_key()
    local origin = Settings.server_url() or "local"
    local user = Settings.get("t2_username") or ""
    if user == "" then user = Settings.get("t1_username") or "anonymous" end
    return origin .. "\n" .. user
end

function Settings.library_total()
    local totals = Settings.get("library_totals")
    if type(totals) ~= "table" then totals = {} end
    local key = Settings.account_key()
    local total = tonumber(totals[key])
    if total then return total end
    -- Older builds stored one unscoped count. Adopt it into the account that
    -- was active during the upgrade, then remove the legacy field.
    local legacy = tonumber(Settings.get("library_total"))
    if legacy then
        local migrated = {}
        for account, value in pairs(totals) do migrated[account] = value end
        migrated[key] = legacy
        Settings.set("library_totals", migrated)
        Settings.set("library_total", nil)
        return legacy
    end
    return 0
end

function Settings.set_library_total(total)
    total = tonumber(total)
    if not total then return end
    local current = Settings.get("library_totals")
    local totals = {}
    for account, value in pairs(type(current) == "table" and current or {}) do
        totals[account] = value
    end
    totals[Settings.account_key()] = total
    Settings.set("library_totals", totals)
end

function Settings.sync_key()
    return Obfuscate.decode(Settings.get("sync_key_secret"), salt())
end

function Settings.set_sync_credentials(username, userkey)
    Settings.update({
        sync_username = username or "",
        sync_key_secret = Obfuscate.encode(userkey or "", salt()),
        sync_origin = Settings.server_url() or "",
        sync_account = Settings.get("t2_username") or "",
    })
end

function Settings.clear_sync_credentials()
    Settings.update({
        sync_username = "",
        sync_key_secret = "",
        sync_origin = "",
        sync_account = "",
    })
end

function Settings.has_sync_credentials()
    return (Settings.get("sync_username") or "") ~= ""
        and Settings.sync_key() ~= ""
        and Settings.get("sync_origin") == (Settings.server_url() or "")
        and Settings.get("sync_account") == (Settings.get("t2_username") or "")
end

function Settings.clear_t2()
    local prior_account = Settings.account_key()
    pcall(function() require("lib.sync_queue").clear(prior_account) end)
    Settings.set("t2_username", "")
    Settings.set("t2_secret", "")
    Settings.clear_tokens()
    Settings.clear_sync_credentials()
    Settings.set("auto_sync_enabled", false)
    pcall(function() require("lib.session").reset() end)
end

function Settings.clear_account()
    Settings.clear_t2()
end

function Settings.grid()
    local key = Settings.get("grid_density") or "3x3"
    return DENSITIES[key] or DENSITIES["3x3"]
end

function Settings.page_size()
    local g = Settings.grid()
    return g.cols * g.rows
end

function Settings.download_dir()
    local dir = Settings.get("download_dir")
    if type(dir) == "string" and dir ~= "" then
        return dir:gsub("/+$", "")
    end
    return Paths.default_download_dir()
end

function Settings.cover_budget()
    return tonumber(Settings.get("cover_budget_bytes")) or DEFAULTS.cover_budget_bytes
end

--- When Grimmory is unreachable, only show downloaded ∪ pinned. Default on.
function Settings.hide_unavailable()
    return Settings.get("hide_unavailable") ~= false
end

function Settings.defaults()
    return DEFAULTS
end

return Settings
