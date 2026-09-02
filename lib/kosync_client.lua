local Http = require("lib.http")
local Origin = require("lib.origin")
local Settings = require("lib.settings")

local Client = {}

local function decode(body)
    if type(body) == "table" then return body end
    local ok_json, json = pcall(require, "json")
    if not ok_json or not json then return nil end
    local ok, value = pcall(json.decode, body or "")
    return ok and value or nil
end

-- On Android, Background.run cannot fork, so these calls run on the UI
-- thread. Keep them well under the 5s ANR budget there.
local function timeouts()
    local ok, Device = pcall(require, "device")
    if ok and Device and Device.isAndroid and Device:isAndroid() then
        return 2, 4
    end
    return 4, 8
end

local function headers(credentials)
    return {
        ["x-auth-user"] = credentials.username,
        ["x-auth-key"] = credentials.userkey,
        Accept = "application/vnd.koreader.v1+json",
        ["Content-Type"] = "application/vnd.koreader.v1+json",
    }
end

local function xpointer_only(value)
    if type(value) ~= "string" or value == "" then return nil end
    if value:sub(1, 4) == "epub" or value:find("cfi", 1, true) then return nil end
    return value
end

local function v1_body(raw)
    local body = decode(raw)
    if type(body) ~= "table" then return body end
    return {
        timestamp = body.timestamp,
        document = body.document,
        percentage = tonumber(body.percentage),
        progress = xpointer_only(body.progress or body.xpointer),
        device = body.device,
        device_id = body.device_id,
    }
end

local function response(ok, status, body)
    local kind
    if not ok then
        if status == 0 then kind = "offline"
        elseif status == 401 or status == 403 then kind = "auth_required"
        elseif status == 404 then kind = "not_found"
        elseif status >= 500 then kind = "server_error"
        else kind = "invalid_response" end
    end
    return { ok = ok and true or false, status = tonumber(status) or 0,
        body = v1_body(body), error_kind = kind }
end

function Client.get(credentials, digest)
    local origin = Settings.server_url()
    if not origin or not credentials or not digest then return response(false, 0) end
    local url = Origin.koreader_sync(origin) .. "/syncs/progress/" .. tostring(digest)
    local block, total = timeouts()
    local ok, status, body = Http.get(url, {
        headers = headers(credentials), timeout_block = block, timeout_total = total,
    })
    return response(ok, status, body)
end

function Client.put(credentials, snapshot)
    local origin = Settings.server_url()
    if not origin or not credentials or not snapshot then return response(false, 0) end
    local payload = {
        timestamp = snapshot.captured_at or os.time(),
        document = snapshot.digest,
        percentage = snapshot.percentage,
        progress = xpointer_only(snapshot.xpointer or snapshot.progress),
        device = snapshot.device,
        device_id = snapshot.device_id,
    }
    local block, total = timeouts()
    local ok, status, body = Http.put_json(Origin.koreader_sync(origin) .. "/syncs/progress",
        payload, { headers = headers(credentials), timeout_block = block, timeout_total = total })
    return response(ok, status, body)
end

return Client
