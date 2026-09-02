local logger = require("logger")
local Origin = require("lib.origin")

local Http = {}

local function clients()
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    return http, https, ltn12, socket, socketutil
end

local function pick_client(url, http, https)
    if url:match("^https:") then
        return https or http
    end
    return http
end

local function header_get(headers, name)
    if not headers then
        return nil
    end
    local want = name:lower()
    local v = headers[name] or headers[want]
    if v ~= nil then
        return v
    end
    for k, val in pairs(headers) do
        if type(k) == "string" and k:lower() == want then
            return val
        end
    end
    return nil
end

function Http.header_get(headers, name)
    return header_get(headers, name)
end

-- etag / last_modified from a response header table (any casing).
function Http.validators(headers)
    if not headers then
        return nil
    end
    local etag = header_get(headers, "etag")
    local last_modified = header_get(headers, "last-modified")
    if etag == nil and last_modified == nil then
        return nil
    end
    return { etag = etag, last_modified = last_modified }
end

function Http.apply_conditional(headers, opts)
    opts = opts or {}
    local v = opts.validators or opts
    local etag = opts.etag or (v and v.etag)
    local last_modified = opts.last_modified or (v and v.last_modified)
    if etag and not header_get(headers, "If-None-Match") then
        headers["If-None-Match"] = etag
    end
    if last_modified and not header_get(headers, "If-Modified-Since") then
        headers["If-Modified-Since"] = last_modified
    end
    return headers
end

-- Blocking request. Call from Trapper or a scheduled cover tick, never from
-- a paint/layout path.
--
-- opts: method, headers, body, user, password, sink, timeout_block, timeout_total,
--       etag, last_modified, validators
-- 304 Not Modified is success (ok=true).
-- Returns: ok, code, body_or_err, headers
function Http.request(url, opts)
    opts = opts or {}
    if type(url) ~= "string" or url == "" then
        return false, 0, "missing url"
    end
    local ok_req, http, https, ltn12, socket, socketutil = pcall(clients)
    if not ok_req then
        return false, 0, "socket unavailable"
    end

    local chunks = {}
    local sink = opts.sink or ltn12.sink.table(chunks)
    local headers = {}
    if opts.headers then
        for k, v in pairs(opts.headers) do
            headers[k] = v
        end
    end
    headers["User-Agent"] = headers["User-Agent"] or "hansel.koplugin/0.3.1"
    headers["Accept-Encoding"] = headers["Accept-Encoding"] or "identity"
    Http.apply_conditional(headers, opts)

    local source
    if opts.body then
        source = ltn12.source.string(opts.body)
        headers["Content-Length"] = tostring(#opts.body)
        headers["Content-Type"] = headers["Content-Type"] or "application/json"
    end

    local request = {
        url = url,
        method = opts.method or "GET",
        headers = headers,
        source = source,
        sink = sink,
        user = opts.user,
        password = opts.password,
        redirect = opts.redirect ~= false,
    }

    local client = pick_client(url, http, https)
    -- Never fall back to KOReader's LARGE_* (tens of seconds). That is an ANR.
    local block = opts.timeout_block or 4
    local total = opts.timeout_total or 8

    local ok, code, resp_headers, status = pcall(function()
        socketutil:set_timeout(block, total)
        local c, h, s = socket.skip(1, client.request(request))
        socketutil:reset_timeout()
        return c, h, s
    end)
    pcall(function() socketutil:reset_timeout() end)

    if not ok then
        logger.warn("[hansel] http error", url, code)
        return false, 0, tostring(code)
    end

    if type(code) ~= "number" then
        return false, 0, tostring(status or code or "network error")
    end

    local body
    if not opts.sink then
        body = table.concat(chunks)
    end

    if code == 304 then
        return true, 304, body, resp_headers
    end
    if code < 200 or code >= 300 then
        return false, code, body or tostring(status or code), resp_headers
    end
    return true, code, body, resp_headers
end

function Http.get(url, opts)
    opts = opts or {}
    opts.method = "GET"
    return Http.request(url, opts)
end

function Http.post_json(url, payload, opts)
    opts = opts or {}
    opts.method = "POST"
    local json = require("json")
    opts.body = json.encode(payload)
    opts.headers = opts.headers or {}
    opts.headers["Content-Type"] = opts.headers["Content-Type"] or "application/json"
    return Http.request(url, opts)
end

function Http.json(method, url, payload, opts)
    opts = opts or {}
    opts.method = method
    if payload ~= nil then
        local json = require("json")
        opts.body = json.encode(payload)
        opts.headers = opts.headers or {}
        opts.headers["Content-Type"] = opts.headers["Content-Type"] or "application/json"
    end
    return Http.request(url, opts)
end

function Http.put_json(url, payload, opts)
    return Http.json("PUT", url, payload, opts)
end

function Http.patch_json(url, payload, opts)
    return Http.json("PATCH", url, payload, opts)
end

function Http.download_file(url, dest_path, opts)
    opts = opts or {}
    local tmp = dest_path .. ".part"
    local f, err = io.open(tmp, "wb")
    if not f then
        return false, 0, err or "cannot open temp file"
    end
    local ltn12 = require("ltn12")
    opts.sink = ltn12.sink.file(f)
    opts.timeout_block = opts.timeout_block or require("socketutil").FILE_BLOCK_TIMEOUT
    opts.timeout_total = opts.timeout_total or require("socketutil").FILE_TOTAL_TIMEOUT
    local ok, code, body, headers = Http.request(url, opts)
    -- sink.file closes the handle
    if code == 304 then
        pcall(os.remove, tmp)
        return true, 304, dest_path, headers
    end
    if not ok then
        pcall(os.remove, tmp)
        pcall(os.remove, dest_path)
        return false, code, body
    end
    os.remove(dest_path)
    local renamed, rename_err = os.rename(tmp, dest_path)
    if not renamed then
        pcall(os.remove, tmp)
        return false, 0, rename_err or "rename failed"
    end
    return true, code, dest_path, headers
end

function Http.gated(url, creds)
    if creds and creds.user and creds.url and not Origin.same_origin(creds.url, url) then
        return { user = nil, password = nil }
    end
    return creds or {}
end

return Http
