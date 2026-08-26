package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
Stub.install()

local Settings = require("lib.settings")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t2_credentials("reader", "secret")
Settings.set("sort_key", "title")
Settings.set_library_total(11)

local checks = 0
local function eq(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, ("FAIL %s: %s ~= %s"):format(message,
        tostring(actual), tostring(expected)))
end

-- Simulate a KOReader restart: dynamic settings must not be discarded merely
-- because they are not defaults.
package.loaded["lib.settings"] = nil
local Reopened = require("lib.settings")
Reopened.load()
eq(Reopened.get("sort_key"), "title", "dynamic sort survives restart")
eq(Reopened.library_total(), 11, "account total survives restart")

Reopened.set_t2_credentials("other", "secret")
eq(Reopened.library_total(), 0, "second account cannot see first count")
Reopened.set_library_total(22)
Reopened.set_t2_credentials("reader", "secret")
eq(Reopened.library_total(), 11, "first account count restored")
Reopened.set_t2_credentials("other", "secret")
eq(Reopened.library_total(), 22, "second account keeps its own count")

Reopened.set_tokens("refresh", os.time() + 3600, Reopened.server_url(), "other")
Reopened.set("auto_sync_enabled", true)
Reopened.set_server_url("")
eq(Reopened.refresh_token(), "", "clearing server clears its refresh token")
eq(Reopened.get("auto_sync_enabled"), false, "clearing server stops active sync work")

local flushes = 0
local real_flush = Reopened.flush
function Reopened.flush()
    flushes = flushes + 1
    return real_flush()
end

local before = flushes
Reopened.set("last_view", "unread")
eq(flushes - before, 1, "set still flushes immediately")
eq(Reopened.get("last_view"), "unread", "set writes last_view")

before = flushes
Reopened.update({ last_view = "all", last_page = 4, last_filter = "unread" })
eq(flushes - before, 1, "update flushes once")
eq(Reopened.get("last_view"), "all", "update writes last_view")
eq(Reopened.get("last_page"), 4, "update writes last_page")
eq(Reopened.get("last_filter"), "unread", "update writes last_filter")

before = flushes
Reopened.update({
    t2_refresh_secret = "batched",
    t2_token_expires_at = 99,
    t2_token_origin = "http://grimmory.test:6060",
    t2_token_user = "other",
})
eq(flushes - before, 1, "critical update flushes once")
eq(Reopened.get("t2_token_expires_at"), 99, "critical update writes tokens")

eq(Reopened.hide_unavailable(), true, "hide unavailable defaults on")
Reopened.set("hide_unavailable", false)
eq(Reopened.hide_unavailable(), false, "hide unavailable can be turned off")
Reopened.set("hide_unavailable", true)
eq(Reopened.hide_unavailable(), true, "hide unavailable can be turned back on")

print("settings: " .. checks .. " ok")
