local Http = require("lib.http")
local Origin = require("lib.origin")
local Settings = require("lib.settings")
local logger = require("logger")

local Session = {}

local access_token
local access_expires_at = 0
local access_identity
local state = {
    kind = "unknown",
    checked_at = 0,
    status = 0,
}

local function now()
    return os.time()
end

local function decode_json(blob)
    if type(blob) == "table" then return blob end
    local ok_json, json = pcall(require, "json")
    if not ok_json or not json or not json.decode then return nil end
    local ok, value = pcall(json.decode, blob or "")
    return ok and value or nil
end

local function identity(origin, username)
    origin = Origin.from_any(origin)
    if not origin or not username or username == "" then return nil end
    return origin .. "\n" .. username
end

local function classify(status)
    status = tonumber(status) or 0
    if status == 0 then return "offline" end
    if status == 401 then return "auth_required" end
    if status == 403 then return "forbidden" end
    if status == 404 then return "not_found" end
    if status >= 500 then return "server_error" end
    return "invalid_response"
end

local function set_state(kind, status)
    state = {
        kind = kind,
        checked_at = now(),
        status = tonumber(status) or 0,
    }
    logger.dbg("[hansel] session", kind, state.status)
end

local function result(ok, status, body, opts)
    opts = opts or {}
    return {
        ok = ok and true or false,
        status = tonumber(status) or 0,
        body = body,
        error_kind = ok and nil or (opts.error_kind or classify(status)),
        checked_at = now(),
        retried = opts.retried and true or false,
    }
end

local function persist_tokens(refresh, expires_at, origin, username)
    if type(Settings.set_tokens) == "function" then
        return Settings.set_tokens(refresh, expires_at, origin, username)
    end
    if type(Settings.update) == "function" then
        return Settings.update({
            t2_refresh_secret = refresh or "",
            t2_token_expires_at = tonumber(expires_at) or 0,
            t2_token_origin = origin or "",
            t2_token_user = username or "",
        })
    end
    Settings.set("t2_refresh_secret", refresh or "")
    Settings.set("t2_token_expires_at", tonumber(expires_at) or 0)
    Settings.set("t2_token_origin", origin or "")
    Settings.set("t2_token_user", username or "")
end

local function accept_tokens(payload, origin, username)
    if type(payload) ~= "table" or type(payload.accessToken) ~= "string"
            or payload.accessToken == "" then
        return false
    end
    access_token = payload.accessToken
    access_identity = identity(origin, username)
    local lifetime = tonumber(payload.expires) or 0
    access_expires_at = lifetime > 0 and (now() + lifetime) or 0
    local refresh = payload.refreshToken
    if type(refresh) ~= "string" or refresh == "" then
        refresh = Settings.refresh_token()
    end
    persist_tokens(refresh, access_expires_at, origin, username)
    set_state("connected", 200)
    return true
end

function Session.adopt(payload, origin, username)
    if accept_tokens(payload, Origin.from_any(origin), username) then
        return result(true, 200, payload)
    end
    set_state("invalid_response", 200)
    return result(false, 200, payload, { error_kind = "invalid_response" })
end

function Session.reset()
    access_token = nil
    access_expires_at = 0
    access_identity = nil
    state = { kind = "unknown", checked_at = 0, status = 0 }
end

function Session.status()
    return {
        kind = state.kind,
        checked_at = state.checked_at,
        status = state.status,
        configured = Settings.has_tier2(),
    }
end

-- After Grimmory fails, do not keep probing. Each probe is 8–15s on the
-- Lua thread and that is the Android ANR (close/wait) on this device.
local PROBE_COOLDOWN = 20

function Session.should_probe()
    local ok_n, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_n and NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        return false
    end
    if state.kind == "offline" or state.kind == "server_error" then
        if (now() - (state.checked_at or 0)) < PROBE_COOLDOWN then
            return false
        end
    end
    return true
end

function Session.peek_token()
    local want = identity(Settings.server_url(), Settings.get("t2_username"))
    if access_token and access_identity == want
            and (access_expires_at == 0 or now() < access_expires_at - 60) then
        return access_token
    end
    return nil
end

function Session.mark_offline()
    set_state("offline", 0)
end

function Session.login(origin, username, password)
    origin = Origin.from_any(origin)
    if not origin or not username or username == "" or not password or password == "" then
        set_state("auth_required", 401)
        return result(false, 401, "missing credentials")
    end
    set_state("checking", 0)
    local ok, status, body = Http.post_json(Origin.login(origin), {
        username = username,
        password = password,
    }, { timeout_block = 8, timeout_total = 15 })
    if not ok then
        local kind = classify(status)
        set_state(kind, status)
        return result(false, status, body, { error_kind = kind })
    end
    local payload = decode_json(body)
    if not accept_tokens(payload, origin, username) then
        set_state("invalid_response", status)
        return result(false, status, body, { error_kind = "invalid_response" })
    end
    return result(true, status, payload)
end

local function refresh(origin, username)
    local refresh_token = Settings.refresh_token()
    if refresh_token == "" then return nil end
    if Settings.get("t2_token_origin") ~= origin
            or Settings.get("t2_token_user") ~= username then
        return nil
    end
    local ok, status, body = Http.post_json(origin .. "/api/v1/auth/refresh", {
        refreshToken = refresh_token,
    }, { timeout_block = 8, timeout_total = 15 })
    if not ok then
        if status == 401 or status == 403 then Settings.clear_tokens() end
        return result(false, status, body)
    end
    local payload = decode_json(body)
    if not accept_tokens(payload, origin, username) then
        return result(false, status, body, { error_kind = "invalid_response" })
    end
    return result(true, status, payload)
end

function Session.ensure_token(force)
    if not Settings.has_tier2() then
        set_state("auth_required", 401)
        return nil, result(false, 401, "no Grimmory account")
    end
    local origin = Settings.server_url()
    local username = Settings.get("t2_username")
    local want_identity = identity(origin, username)
    if access_identity ~= want_identity then
        access_token = nil
        access_expires_at = 0
        access_identity = want_identity
    end
    if not force and access_token
            and (access_expires_at == 0 or now() < access_expires_at - 60) then
        return access_token
    end

    set_state("checking", 0)
    local refreshed = refresh(origin, username)
    if refreshed and refreshed.ok then return access_token end
    if refreshed and refreshed.error_kind == "offline" then
        set_state("offline", refreshed.status)
        return nil, refreshed
    end

    local logged = Session.login(origin, username, Settings.t2_password())
    if logged.ok then return access_token end
    return nil, logged
end

function Session.request(method, path, opts)
    opts = opts or {}
    local origin = Settings.server_url()
    if not origin then return result(false, 0, "no origin") end
    local token, token_error = Session.ensure_token(false)
    if not token then return token_error or result(false, 401, "no token") end

    local function send(bearer)
        local headers = {}
        for key, value in pairs(opts.headers or {}) do headers[key] = value end
        headers.Authorization = "Bearer " .. bearer
        return Http.json(method or "GET", origin .. path, opts.body, {
            headers = headers,
            timeout_block = opts.timeout_block or 4,
            timeout_total = opts.timeout_total or 8,
        })
    end

    local ok, status, body = send(token)
    local retried = false
    if not ok and status == 401 then
        access_token = nil
        access_expires_at = 0
        local retry_error
        token, retry_error = Session.ensure_token(true)
        if token then
            retried = true
            ok, status, body = send(token)
        elseif retry_error then
            retry_error.retried = false
            return retry_error
        end
    end
    if ok then
        set_state("connected", status)
        return result(true, status, body, { retried = retried })
    end
    local kind = classify(status)
    -- A missing optional resource still proves that Grimmory accepted the
    -- bearer and answered. Optional feature permission checks may make the
    -- same choice explicitly, while retaining their typed caller error.
    local health_kind = kind
    if kind == "not_found" or (kind == "forbidden" and opts.preserve_connection) then
        health_kind = "connected"
    end
    set_state(health_kind, status)
    return result(false, status, body, { error_kind = kind, retried = retried })
end

function Session.with_bearer(call)
    local token, token_error = Session.ensure_token(false)
    if not token then
        return false, token_error and token_error.status or 401,
            token_error and token_error.body or "no token", nil, token_error
    end
    local ok, status, body, headers = call(token)
    local retried = false
    if not ok and status == 401 then
        access_token = nil
        access_expires_at = 0
        local retry_error
        token, retry_error = Session.ensure_token(true)
        if token then
            retried = true
            ok, status, body, headers = call(token)
        elseif retry_error then
            return false, retry_error.status, retry_error.body, nil, retry_error
        end
    end
    local response
    if ok then
        set_state("connected", status)
        response = result(true, status, body, { retried = retried })
    else
        local kind = classify(status)
        set_state(kind == "not_found" and "connected" or kind, status)
        response = result(false, status, body, { error_kind = kind, retried = retried })
    end
    return ok, status, body, headers, response
end

function Session.check()
    return Session.request("GET", "/api/v1/books/page?page=0&size=1", {
        timeout_block = 5,
        timeout_total = 10,
    })
end

Session.decode_json = decode_json
Session.classify = classify

return Session
