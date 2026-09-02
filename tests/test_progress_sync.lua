package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
local env = Stub.install()

local mapping = {}
package.loaded["lib.cache_map"] = {
    id_for_path = function(path) return mapping[path] end,
    mark_opened = function() end,
}
package.loaded["lib.session"] = {
    decode_json = function(value) return value end,
    reset = function() end,
    peek_token = function() return "jwt" end,
    status = function() return { kind = "connected", checked_at = os.time() } end,
    network_available = function() return env.NetworkMgr:isConnected() end,
}
package.loaded["lib.background"] = {
    run = function(task, done)
        local ok, value = pcall(task)
        done(ok, value)
    end,
}

local remote_replies = {}
local gets, puts, last_put = 0, 0, nil
package.loaded["lib.kosync_client"] = {
    get = function()
        gets = gets + 1
        return table.remove(remote_replies, 1)
            or { ok = true, status = 200, body = { percentage = 0 } }
    end,
    put = function(_, item)
        puts = puts + 1
        last_put = item
        return { ok = true, status = 200, body = {} }
    end,
}

local api_handler
package.loaded["lib.api"] = {
    request = function(method, path, opts) return api_handler(method, path, opts) end,
}

local Settings = require("lib.settings")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t2_credentials("reader", "secret")
local Queue = require("lib.sync_queue")
local ProgressSync = require("lib.progress_sync")

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

eq(Settings.get("auto_sync_enabled"), false, "Auto sync defaults off")

-- Reuse an existing native profile and enable it without touching web-reader prefs.
local requests = {}
api_handler = function(method, path)
    requests[#requests + 1] = method .. " " .. path
    if method == "GET" then
        return { ok = true, status = 200, body = {
            username = "native-reader", passwordMD5 = "native-key",
            syncEnabled = false, webReaderEnabled = false,
        } }
    end
    return { ok = true, status = 200, body = {} }
end
env.NetworkMgr.online = true
env.NetworkMgr.wifi_on = true
local enabled, enable_err = ProgressSync.set_enabled(true)
ok(enabled, "existing native credentials enable: " .. tostring(enable_err))
eq(Settings.get("sync_username"), "native-reader", "existing native username reused")
eq(Settings.sync_key(), "native-key", "existing native key reused")
eq(requests[2], "PATCH /api/v1/koreader-users/me/sync?enabled=true",
    "disabled native profile enabled")
ProgressSync.set_enabled(false)

-- Missing profiles get random hansel credentials; unsupported permissions stay off.
Settings.clear_sync_credentials()
api_handler = function(method, _, opts)
    if method == "GET" then return { ok = false, status = 404, error_kind = "not_found" } end
    if method == "PUT" then
        return { ok = true, status = 200, body = {
            username = opts.body.username, syncEnabled = true,
        } }
    end
    return { ok = true, status = 200, body = {} }
end
ok(ProgressSync.set_enabled(true), "missing native profile created")
ok(Settings.get("sync_username"):find("^hansel%-") ~= nil, "generated username is scoped to hansel")
ok(Settings.sync_key() ~= "", "generated password converted to native key")
ProgressSync.set_enabled(false)
Settings.clear_sync_credentials()
api_handler = function()
    return { ok = false, status = 403, error_kind = "forbidden" }
end
local permitted, permission_err = ProgressSync.set_enabled(true)
ok(not permitted and permission_err:find("permission", 1, true), "permission failure actionable")
eq(Settings.get("auto_sync_enabled"), false, "failed setup leaves switch off")

-- Use valid credentials for deterministic lifecycle tests.
Settings.set_sync_credentials("native-reader", "native-key")
Settings.set("auto_sync_enabled", true)
Queue.clear(Settings.account_key())

local function rolling_ui(path, state)
    local ui = {
        document = { file = path, info = { has_pages = false } },
        rolling = {
            getLastPercent = function() return state.percent end,
            getLastProgress = function() return state.xpointer end,
        },
        doc_settings = { readSetting = function() return nil end },
        getCurrentPage = function() return state.page end,
        events = {},
    }
    function ui:handleEvent(event) self.events[#self.events + 1] = event end
    return ui
end

local function paged_ui(path, state)
    local document = {
        file = path,
        info = { has_pages = true },
        getPageCount = function() return state.pages end,
    }
    local ui = {
        document = document,
        paging = { getLastPercent = function() return state.percent end },
        doc_settings = { readSetting = function() return nil end },
        getCurrentPage = function() return state.page end,
        events = {},
    }
    function ui:handleEvent(event) self.events[#self.events + 1] = event end
    return ui
end

-- ReaderReady pulls, but offline opens and page turns never turn Wi-Fi on or hit HTTP.
local rolling_state = { percent = 0.31, xpointer = "/body/section[3]", page = 1 }
local rolling = rolling_ui("/books/rolling.epub", rolling_state)
mapping[rolling.document.file] = "42"
env.NetworkMgr.online = false
env.NetworkMgr.wifi_on = false
local before_gets = gets
ProgressSync.on_reader_ready(rolling)
env.UIManager:drain()
eq(gets, before_gets, "offline ReaderReady makes no request")
for page = 2, 11 do ProgressSync.on_page_update(page) end
eq(#env.UIManager.queue, 1, "ten distinct pages schedule one trailing debounce")
ProgressSync.on_page_update(12)
eq(#env.UIManager.queue, 1, "further turns reset rather than duplicate debounce")
eq(gets, before_gets, "no live-per-page requests")
env.UIManager:run_next()
eq(Queue.count(Settings.account_key()), 1, "debounced snapshot queued durably")
local queued = Queue.get("42", Settings.account_key())
eq(queued.xpointer, "/body/section[3]", "reflowable snapshot keeps XPointer")
eq(queued.percentage, 0.31, "reflowable snapshot keeps fractional percent")

-- Suspend snapshots immediately and cancels a pending duplicate debounce.
for page = 13, 22 do ProgressSync.on_page_update(page) end
eq(#env.UIManager.queue, 1, "second cadence scheduled before suspend")
rolling_state.percent = 0.35
rolling_state.xpointer = "/body/section[3.5]"
ProgressSync.on_suspend()
eq(#env.UIManager.queue, 0, "suspend cancels pending duplicate debounce")
eq(Queue.count(Settings.account_key()), 1, "suspend keeps one latest snapshot")
eq(Queue.get("42", Settings.account_key()).percentage, 0.35,
    "suspend snapshot is immediately durable")

-- Close replaces, rather than appends to, the pending book snapshot.
rolling_state.percent = 0.42
rolling_state.xpointer = "/body/section[4]"
ProgressSync.on_close_document()
eq(Queue.count(Settings.account_key()), 1, "close keeps newest snapshot per book")
queued = Queue.get("42", Settings.account_key())
eq(queued.percentage, 0.42, "close captured latest progress")
package.loaded["lib.sync_queue"] = nil
local ReopenedQueue = require("lib.sync_queue")
eq(ReopenedQueue.get("42", Settings.account_key()).xpointer, "/body/section[4]",
    "queue survives restart")

-- A connection arriving after close still performs pull-before-push with no
-- reader object left alive.
env.NetworkMgr.online = true
env.NetworkMgr.wifi_on = true
remote_replies = { { ok = true, status = 200, body = { percentage = 0.20 } } }
before_gets = gets
local before_puts = puts
ProgressSync.on_network_connected()
eq(gets - before_gets, 1, "network reconnect compares closed-book snapshot")
eq(puts - before_puts, 1, "network reconnect drains closed-book snapshot")
eq(Queue.count(Settings.account_key()), 0, "closed-book queue drained on reconnect")

-- A later book open pulls first, then compares again before draining a push.
Queue.put("42", queued, Settings.account_key())
remote_replies = {
    { ok = true, status = 200, body = { percentage = 0.20 } },
    { ok = true, status = 200, body = { percentage = 0.20 } },
}
before_gets = gets
before_puts = puts
ProgressSync.on_reader_ready(rolling)
env.UIManager:drain()
eq(gets - before_gets, 2, "open pull plus pull-before-push")
eq(puts - before_puts, 1, "newest queued state pushed once")
eq(last_put.xpointer, "/body/section[4]", "wire push includes exact XPointer")
eq(last_put.percentage, 0.42, "wire push includes fractional percent")
eq(Queue.count(Settings.account_key()), 0, "successful push drains queue")
env.NetworkMgr.online = false
env.NetworkMgr.wifi_on = false
ProgressSync.on_close_document()
Queue.clear(Settings.account_key())

-- A remote lead over 0.5 percentage points blocks the push and asks on open.
local paged_state = { percent = 0.25, page = 25, pages = 100 }
local paged = paged_ui("/books/paged.pdf", paged_state)
mapping[paged.document.file] = "7"
env.NetworkMgr.online = true
env.NetworkMgr.wifi_on = true
remote_replies = { { ok = true, status = 200, body = { percentage = 0.40 } } }
before_puts = puts
env.UIManager.stack = {}
ProgressSync.on_reader_ready(paged)
env.UIManager:drain()
local conflict = Queue.get("7", Settings.account_key())
ok(conflict and conflict.blocked, "remote-ahead snapshot is blocked")
eq(conflict.xpointer, nil, "PDF snapshot sends percentage only")
eq(puts, before_puts, "blocked conflict is not pushed")
local prompt = env.UIManager.stack[#env.UIManager.stack]
ok(prompt and prompt.ok_callback and prompt.cancel_callback, "conflict offers both choices")
env.UIManager:close(prompt)
ok(Queue.get("7", Settings.account_key()).blocked, "dismissing leaves push blocked")
Queue.put("7", { digest = "paged", percentage = 0.26, kind = "paged" },
    Settings.account_key())
ok(Queue.get("7", Settings.account_key()).blocked,
    "a newer snapshot preserves a dismissed conflict block")
local listed = ProgressSync.blocked_conflicts()
eq(#listed, 1, "dismissed conflict stays listable")
eq(listed[1].book_id, "7", "listed conflict keeps book id")
ok(listed[1].remote and listed[1].remote.percentage == 0.40,
    "listed conflict keeps remote lead")

-- Continue from Grimmory restores to a clamped nearest page and suppresses echo.
prompt.ok_callback()
eq(paged.events[#paged.events].name, "GotoPage", "PDF restore uses page navigation")
eq(paged.events[#paged.events].args[1], 40, "PDF restore picks nearest page")
eq(Queue.get("7", Settings.account_key()), nil, "remote choice clears blocked local state")
ProgressSync.on_page_update(40) -- generated by applying remote
for page = 41, 49 do ProgressSync.on_page_update(page) end
eq(#env.UIManager.queue, 0, "applied remote page event is suppressed")
ProgressSync.on_page_update(50)
eq(#env.UIManager.queue, 1, "ten real turns still schedule normally")
env.NetworkMgr.online = false
env.NetworkMgr.wifi_on = false
ProgressSync.on_close_document()
Queue.clear(Settings.account_key())

-- Keep this device unblocks, re-compares, and explicitly overrides the lead.
env.UIManager.queue = {}
env.UIManager.stack = {}
env.NetworkMgr.online = true
env.NetworkMgr.wifi_on = true
remote_replies = {
    { ok = true, status = 200, body = { percentage = 0.40 } },
    { ok = true, status = 200, body = { percentage = 0.40 } },
}
before_puts = puts
ProgressSync.on_reader_ready(paged)
env.UIManager:drain()
prompt = env.UIManager.stack[#env.UIManager.stack]
prompt.cancel_callback()
eq(puts - before_puts, 1, "keep-device choice overrides the confirmed remote lead")
eq(last_put.xpointer, nil, "paged wire payload has no XPointer or CFI")
env.NetworkMgr.online = false
env.NetworkMgr.wifi_on = false
ProgressSync.on_close_document()
Queue.clear(Settings.account_key())

-- A keep-device resolution survives queue persistence and a later open.
env.UIManager.queue = {}
Queue.put("7", {
    digest = "paged-digest", percentage = 0.25, kind = "paged",
    keep_device = true,
}, Settings.account_key())
env.NetworkMgr.online = true
env.NetworkMgr.wifi_on = true
env.UIManager.stack = {}
remote_replies = {
    { ok = true, status = 200, body = { percentage = 0.40 } },
    { ok = true, status = 200, body = { percentage = 0.40 } },
}
before_puts = puts
ProgressSync.on_reader_ready(paged)
env.UIManager:drain()
eq(puts - before_puts, 1, "persisted keep-device resolution pushes after re-open")
eq(#env.UIManager.stack, 0, "persisted keep-device resolution does not re-prompt")
env.NetworkMgr.online = false
env.NetworkMgr.wifi_on = false
ProgressSync.on_close_document()
Queue.clear(Settings.account_key())

-- Blocked conflicts stay findable after dismiss and resolve later without a prompt.
env.UIManager.queue = {}
env.UIManager.stack = {}
env.NetworkMgr.online = true
env.NetworkMgr.wifi_on = true
remote_replies = { { ok = true, status = 200, body = { percentage = 0.40 } } }
ProgressSync.on_reader_ready(paged)
env.UIManager:drain()
prompt = env.UIManager.stack[#env.UIManager.stack]
env.UIManager:close(prompt)
eq(#ProgressSync.blocked_conflicts(), 1, "closed prompt still lists the block")
ok(not ProgressSync.resolve_conflict("7", "neither"), "unknown choice is rejected")
env.NetworkMgr.online = false
env.NetworkMgr.wifi_on = false
ProgressSync.on_close_document()
eq(#ProgressSync.blocked_conflicts(), 1, "closed book still lists dismissed conflict")
env.NetworkMgr.online = true
env.NetworkMgr.wifi_on = true
remote_replies = { { ok = true, status = 200, body = { percentage = 0.40 } } }
before_puts = puts
ok(ProgressSync.resolve_conflict("7", "device"), "later keep-device resolve")
eq(#ProgressSync.blocked_conflicts(), 0, "device resolve removes the block")
eq(puts - before_puts, 1, "later keep-device resolve pushes")
Queue.clear(Settings.account_key())
remote_replies = { { ok = true, status = 200, body = { percentage = 0.55 } } }
ProgressSync.on_reader_ready(paged)
env.UIManager:drain()
env.UIManager:close(env.UIManager.stack[#env.UIManager.stack])
ProgressSync.on_close_document()
before_puts = puts
ok(ProgressSync.resolve_conflict("7", "grimmory"), "later Grimmory resolve without reader")
eq(Queue.get("7", Settings.account_key()), nil, "later Grimmory resolve drops local snapshot")
eq(puts, before_puts, "later Grimmory resolve does not push device progress")
eq(#ProgressSync.blocked_conflicts(), 0, "later Grimmory resolve clears the list")
env.NetworkMgr.online = false
env.NetworkMgr.wifi_on = false
Queue.clear(Settings.account_key())

-- Both competing sync implementations make Hansel stand down without changing preference.
local PluginLoader = require("pluginloader")
PluginLoader.isPluginLoaded = function(_, name) return name == "grimmory" end
eq(ProgressSync.stand_down_kind(), "grimmory_plugin", "Grimmory plugin detected")
eq(Settings.get("auto_sync_enabled"), true, "stand-down preserves switch preference")
local paused_status = ProgressSync.status()
eq(paused_status.label, "Paused", "enabled hansel sync is clearly paused during stand-down")
eq(paused_status.owner, "Grimmory plugin", "competing sync owner is reported separately")
ok(not paused_status.active, "stand-down never reports hansel sync as active")
Settings.set("auto_sync_enabled", false)
local off_status = ProgressSync.status()
eq(off_status.label, "Off", "competing plugin cannot make Hansel's off switch look on")
eq(off_status.owner, "Grimmory plugin", "off status still explains the active sync owner")
Settings.set("auto_sync_enabled", true)
PluginLoader.isPluginLoaded = function() return false end
env.settings_files["/tmp/hansel-test/settings/kosync.lua"] = {
    settings = { auto_sync = false, username = "native", userkey = "key",
        custom_server = "http://grimmory.test:6060/api/koreader" },
}
eq(ProgressSync.stand_down_kind(), "kosync", "configured same-origin KOReader sync detected")
env.settings_files["/tmp/hansel-test/settings/kosync.lua"].settings.custom_server =
    "http://grimmory.test:6061/api/koreader"
eq(ProgressSync.stand_down_kind(), nil, "different port does not falsely stand down")

-- Queue storage is account scoped, and a deliberate off clears this account only.
Queue.put("1", { digest = "a", percentage = 0.1 }, "account-a")
Queue.put("1", { digest = "b", percentage = 0.2 }, "account-b")
eq(Queue.count("account-a"), 1, "queue account A isolated")
eq(Queue.count("account-b"), 1, "queue account B isolated")
Queue.put("9", { digest = "x", percentage = 0.9 }, Settings.account_key())
ProgressSync.set_enabled(false)
eq(Queue.count(Settings.account_key()), 0, "turning Auto sync off clears this account queue")
eq(Queue.count("account-b"), 1, "turning off preserves other account queue")

print("progress sync: " .. checks .. " ok")
