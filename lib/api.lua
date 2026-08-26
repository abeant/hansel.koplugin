local Http = require("lib.http")
local Origin = require("lib.origin")
local Session = require("lib.session")
local Settings = require("lib.settings")
local logger = require("logger")

local API = {}

function API.clear_token()
    Session.reset()
end

function API.token()
    return Session.ensure_token(false)
end

function API.rest_get(path, opts)
    local response = Session.request("GET", path, opts)
    return response.ok, response.status, response.body, nil, response
end

function API.request(method, path, opts)
    return Session.request(method, path, opts)
end

function API.test_tier1(origin, username, password)
    origin = Origin.from_any(origin)
    if not origin then return false, "missing server URL" end
    local url = Origin.opds_root(origin)
    local ok, code, body = Http.get(url, {
        user = username,
        password = password,
        timeout_block = 8,
        timeout_total = 15,
    })
    if not ok then
        if code == 401 or code == 403 then
            return false, "authentication failed"
        end
        return false, tostring(body or code)
    end
    if type(body) == "string" and (body:find("<feed") or body:find("opds")) then
        return true, "OPDS catalog reachable"
    end
    return true, "HTTP " .. tostring(code)
end

function API.test_tier2(origin, username, password)
    origin = Origin.from_any(origin)
    if not origin then return false, "missing server URL" end
    if not username or username == "" or not password or password == "" then
        return false, "no Grimmory login"
    end
    local response = Session.login(origin, username, password)
    if not response.ok then
        if response.status == 401 or response.status == 403 then
            return false, "login failed", response
        end
        return false, tostring(response.body or response.status), response
    end
    if type(response.body) == "table" and response.body.accessToken then
        return true, "logged in", response
    end
    return false, "login response missing token", response
end

function API.test_connection()
    local origin = Settings.server_url()
    local t1_ok, t1_msg = API.test_tier1(origin, Settings.get("t1_username"), Settings.t1_password())
    local t2_ok, t2_msg = false, "not configured"
    if Settings.has_tier2() then
        t2_ok, t2_msg = API.test_tier2(origin, Settings.get("t2_username"), Settings.t2_password())
    end
    logger.dbg("[hansel] test connection t1=", t1_ok, t1_msg, "t2=", t2_ok, t2_msg)
    return {
        origin = origin,
        tier1 = t1_ok,
        tier1_msg = t1_msg,
        tier2 = t2_ok,
        tier2_msg = t2_msg,
    }
end

return API
