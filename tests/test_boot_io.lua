package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
local env = Stub.install()

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

local state_calls, path_calls = 0, 0
package.loaded["lib.cache_map"] = {
    get = function() return nil end,
    state = function()
        state_calls = state_calls + 1
        return "remote"
    end,
    local_path = function()
        path_calls = path_calls + 1
        return nil
    end,
}
package.loaded["lib.catalog"] = {
    get_book = function() return nil end,
}
package.loaded["lib.books"] = nil
local Books = require("lib.books")
local light = Books.hydrate({ id = "99", title = "Remote" }, { disk = false })
eq(light.state, "remote", "missing cache row is remote")
eq(state_calls, 0, "disk=false must not call CacheMap.state")
eq(path_calls, 0, "disk=false must not call CacheMap.local_path")

package.loaded["lib.cache_map"].get = function()
    return { path = "/tmp/x.epub", pinned = true }
end
local pinned = Books.hydrate({ id = "1" }, { disk = false })
eq(pinned.state, "pinned", "cache map path+pin without disk")
eq(state_calls, 0, "pinned light hydrate still no state()")

-- fetch_feed skip-probe returns cache, not cached_failure(offline).
package.loaded["lib.cache_map"] = {
    local_books = function() return {} end,
    local_path = function() return nil end,
    state = function() return "remote" end,
    get = function() return nil end,
    revision = function() return 1 end,
}
local Settings = require("lib.settings")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t2_credentials("reader", "secret")
local Paths = require("lib.paths")
env.settings_files[Paths.catalog_file()] = {
    catalog = {
        pages = {
            ["all:1:9"] = {
                ids = { "1" }, total = 1, page = 1, size = 9, fetched_at = 10, view = "all",
            },
        },
        by_id = { ["1"] = { id = "1", title = "Zulu", file_type = "epub" } },
        manifest = { total = 1, fetched_at = 10 },
    },
}
package.loaded["lib.catalog"] = nil
package.loaded["lib.session"] = {
    should_probe = function() return false end,
    status = function() return { kind = "unknown", checked_at = 0, status = 0 } end,
}
env.NetworkMgr.online = true
package.loaded["lib.library"] = nil
package.loaded["lib.books"] = nil
package.loaded["ui.filter"] = nil
local Library = require("lib.library")
local skipped = Library.fetch_feed("http://grimmory.test:6060/api/v1/books/page", 1, 9, {
    cache_key = "all",
})
ok(skipped and skipped.books and skipped.books[1], "skip-probe still returns cached page")
ok(not skipped.unavailable, "skip-probe is not fake-offline")
eq(skipped.source, "cache", "skip-probe source is cache")

-- One scheduled cover step does at most one Http.download_file.
local downloads = 0
package.loaded["lib.http"] = {
    download_file = function()
        downloads = downloads + 1
        return true, 200
    end,
}
package.loaded["lib.session"] = {
    peek_token = function() return "tok" end,
    should_probe = function() return true end,
}
package.loaded["lib.covers"] = nil
local Covers = require("lib.covers")
Settings.set_t2_credentials("reader", "secret")
Covers.fetch_visible({
    { id = "a", cover_url = "http://grimmory.test:6060/a.jpg" },
    { id = "b", cover_url = "http://grimmory.test:6060/b.jpg" },
}, function() end)
eq(downloads, 0, "pump does not download before the scheduled tick")
env.UIManager:run_next()
eq(downloads, 1, "one scheduled step does at most one Http.request")

print("boot io: " .. checks .. " ok")
