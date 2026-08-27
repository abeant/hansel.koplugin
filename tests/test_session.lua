package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
Stub.install()

local unpack_values = table.unpack or unpack
local calls = { login = 0, refresh = 0, request = 0 }
local login_reply = { true, 200, {
    accessToken = "access-1", refreshToken = "refresh-1", expires = 3600,
} }
local refresh_reply = { true, 200, {
    accessToken = "access-2", refreshToken = "refresh-2", expires = 3600,
} }
local request_replies = {}

package.loaded["lib.http"] = {
    post_json = function(url)
        if url:find("/auth/refresh", 1, true) then
            calls.refresh = calls.refresh + 1
            return unpack_values(refresh_reply)
        end
        calls.login = calls.login + 1
        return unpack_values(login_reply)
    end,
    json = function(_, _, _, opts)
        calls.request = calls.request + 1
        calls.last_authorization = opts.headers.Authorization
        local reply = table.remove(request_replies, 1) or { true, 200, { content = {} } }
        return unpack_values(reply)
    end,
}

local Settings = require("lib.settings")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t2_credentials("reader", "secret")
local Session = require("lib.session")

local checks = 0
local function ok(value, message)
    checks = checks + 1
    assert(value, "FAIL: " .. message)
end
local function eq(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, ("FAIL %s: %s ~= %s"):format(message,
        tostring(actual), tostring(expected)))
end

-- Login seeds both the in-memory access token and the durable rotating token.
local logged = Session.login(Settings.server_url(), "reader", "secret")
ok(logged.ok, "login succeeds")
eq(Session.peek_token(), "access-1", "access token seeded")
eq(Settings.refresh_token(), "refresh-1", "refresh token stored")

-- A token within the 60-second safety window is refreshed before the request.
Session.adopt({ accessToken = "near-expiry", refreshToken = "refresh-near", expires = 30 },
    Settings.server_url(), "reader")
request_replies = { { true, 200, { content = {} } } }
local proactive = Session.request("GET", "/api/v1/books/page")
ok(proactive.ok, "proactive refresh request succeeds")
eq(calls.last_authorization, "Bearer access-2", "fresh token used")
eq(Settings.refresh_token(), "refresh-2", "rotated refresh token persisted")

-- A 401 invalidates the access token, refreshes, and retries exactly once.
refresh_reply = { true, 200, {
    accessToken = "access-3", refreshToken = "refresh-3", expires = 3600,
} }
request_replies = {
    { false, 401, "expired" },
    { true, 200, { content = {} } },
}
local before_requests = calls.request
local retried = Session.request("GET", "/api/v1/books/page")
ok(retried.ok and retried.retried, "401 retry reported")
eq(calls.request - before_requests, 2, "original request retried once")
eq(calls.last_authorization, "Bearer access-3", "retry uses refreshed token")

-- Streaming callers (covers/downloads) share the exact same one-retry lane.
Session.adopt({ accessToken = "stream-expired", refreshToken = "stream-refresh", expires = 3600 },
    Settings.server_url(), "reader")
refresh_reply = { true, 200, {
    accessToken = "stream-fresh", refreshToken = "stream-rotated", expires = 3600,
} }
local stream_calls = 0
local stream_ok, _, stream_body, _, stream_result = Session.with_bearer(function(token)
    stream_calls = stream_calls + 1
    if token == "stream-expired" then return false, 401, "expired" end
    return true, 200, "downloaded", { ["content-type"] = "application/epub+zip" }
end)
ok(stream_ok, "streaming bearer request succeeds after refresh")
eq(stream_body, "downloaded", "streaming response retained")
eq(stream_calls, 2, "streaming request retried exactly once")
ok(stream_result.retried, "streaming retry reported")

-- If the refresh transport disappears after a 401, report offline rather than
-- pretending the stored account was rejected.
Session.adopt({ accessToken = "server-expired", refreshToken = "refresh-offline", expires = 3600 },
    Settings.server_url(), "reader")
request_replies = { { false, 401, "expired" } }
refresh_reply = { false, 0, "network disappeared" }
local retry_offline = Session.request("GET", "/api/v1/books/page")
eq(retry_offline.error_kind, "offline", "401 refresh transport remains offline")
eq(Session.status().kind, "offline", "retry transport does not claim sign-in failure")

-- A rejected refresh falls back to the retained account password once.
Session.adopt({ accessToken = "expired-again", refreshToken = "bad-refresh", expires = 1 },
    Settings.server_url(), "reader")
refresh_reply = { false, 401, "refresh rejected" }
login_reply = { true, 200, {
    accessToken = "password-fallback", refreshToken = "refresh-4", expires = 3600,
} }
local before_logins = calls.login
request_replies = { { true, 200, {} } }
local fallback = Session.request("GET", "/api/v1/books/page")
ok(fallback.ok, "password fallback succeeds")
eq(calls.login - before_logins, 1, "password fallback logs in once")
eq(calls.last_authorization, "Bearer password-fallback", "fallback token used")

-- Transport, authorization, and server failures remain distinct states.
request_replies = { { false, 0, "network down" } }
local offline = Session.request("GET", "/api/v1/books/page")
eq(offline.error_kind, "offline", "transport classified offline")
eq(Session.status().kind, "offline", "offline session state")

request_replies = { { false, 403, "forbidden" } }
local forbidden = Session.request("GET", "/api/v1/books/page")
eq(forbidden.error_kind, "forbidden", "403 classified forbidden")

request_replies = { { false, 403, "sync permission missing" } }
local limited = Session.request("GET", "/api/v1/koreader-users/me", {
    preserve_connection = true,
})
eq(limited.error_kind, "forbidden", "feature permission remains forbidden")
eq(Session.status().kind, "connected", "feature permission does not invalidate login health")

request_replies = { { false, 503, "maintenance" } }
local server = Session.request("GET", "/api/v1/books/page")
eq(server.error_kind, "server_error", "5xx classified server error")

request_replies = { { false, 404, "optional feature missing" } }
local missing = Session.request("GET", "/api/v1/koreader-users/me")
eq(missing.error_kind, "not_found", "404 remains actionable to the caller")
eq(Session.status().kind, "connected", "404 still verifies a live authenticated server")

login_reply = { false, 401, "changed password" }
local changed = Session.login(Settings.server_url(), "reader", "old-secret")
eq(changed.error_kind, "auth_required", "changed password requires sign-in")
eq(Session.status().kind, "auth_required", "sign-in state is truthful")

-- After a transport failure, do not keep probing (each probe is an ANR).
Session.adopt({ accessToken = "still-valid", refreshToken = "refresh-1", expires = 3600 },
    Settings.server_url(), "reader")
request_replies = { { false, 0, "network down" } }
local down = Session.request("GET", "/api/v1/books/page")
eq(down.error_kind, "offline", "transport classified offline for cooldown")
local NetworkMgr = require("ui/network/manager")
NetworkMgr.online = true
ok(not Session.should_probe(), "should_probe is false during offline cooldown")
ok(not Session.should_probe() or Session.status().kind == "connected",
    "unknown/offline never probes")
NetworkMgr.online = false

print("session: " .. checks .. " ok")
