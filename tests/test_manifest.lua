package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
local env = Stub.install()

local Settings = require("lib.settings")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t2_credentials("reader", "secret")
env.NetworkMgr.online = true

local writes = 0
local put_pages = 0
package.loaded["lib.catalog"] = {
    manifest = function() return {} end,
    book_count = function() return 0 end,
    put_books = function() put_pages = put_pages + 1 end,
    upsert_book = function() end,
    set_manifest = function() writes = writes + 1 end,
}
package.loaded["lib.session"] = { peek_token = function() return "jwt" end }
package.loaded["lib.library"] = {
    fetch_feed = function()
        return { books = { { id = "1", title = "Old account" } }, total = 1 }
    end,
}

local pending_task, pending_done
package.loaded["lib.background"] = {
    run = function(task, done)
        pending_task, pending_done = task, done
    end,
}

local Manifest = require("lib.manifest")
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

Manifest.ensure()
ok(env.UIManager:run_next(), "manifest schedules outside first paint")
ok(pending_task and pending_done, "manifest worker launched")

-- Simulate an account change while the old account's child request is in flight.
local old_result = pending_task()
Settings.set_t2_credentials("other", "secret")
pending_done(true, old_result)
eq(writes, 0, "old account result cannot enter the new account catalog")
eq(put_pages, 0, "page and metadata are not written separately")
eq(Manifest.busy(), false, "account change releases manifest worker")

Settings.set_t2_credentials("reader", "secret")
pending_task, pending_done = nil, nil
Manifest.ensure()
ok(env.UIManager:run_next(), "manifest reschedules after account restore")
ok(pending_task and pending_done, "manifest worker relaunched")
pending_done(true, pending_task())
eq(writes, 1, "page books and manifest metadata commit together")
eq(put_pages, 0, "put_books flush is not used for a page commit")
eq(Manifest.busy(), false, "single-page fetch finishes")

print("manifest: " .. checks .. " ok")
