package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
local env = Stub.install()

local Settings = require("lib.settings")
local Paths = require("lib.paths")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t2_credentials("reader", "secret")

local first_identity = Settings.account_key()
env.settings_files[Paths.cache_map_file()] = {
    cache = {
        books = {
            ["1"] = { path = "/books/one.epub", pinned = true, bytes = 123 },
        },
        open_path = "/books/one.epub",
    },
    entries = {
        ["2"] = { path = "/books/two.pdf", owned = false },
    },
}

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

local CacheMap = require("lib.cache_map")
eq(CacheMap.get("1").bytes, 123, "legacy cache row retained")
eq(CacheMap.get("2").path, "/books/two.pdf", "separate legacy entries merged")
local stored = env.settings_files[Paths.cache_map_file()].cache
ok(stored.accounts and stored.accounts[first_identity], "legacy map account-scoped")

local Covers = require("lib.covers")
local first_cover = Covers.path("1")
ok(first_cover:match("/covers/[^/]+%-1%.jpg$") ~= nil,
    "cover filename includes an account scope")

Settings.set_t2_credentials("other", "secret")
eq(CacheMap.get("1"), nil, "second account cannot see first download metadata")
local second_cover = Covers.path("1")
ok(second_cover ~= first_cover, "second account gets a different cover path")

Settings.set_t2_credentials("reader", "secret")
eq(CacheMap.get("1").bytes, 123, "first account map restored")
eq(Covers.path("1"), first_cover, "first account cover scope restored")

-- Reopening the module must retain the versioned account buckets.
package.loaded["lib.cache_map"] = nil
CacheMap = require("lib.cache_map")
eq(CacheMap.get("2").path, "/books/two.pdf", "scoped map survives restart")
eq(CacheMap.get("1").pinned, true, "pin survives restart")
eq(CacheMap.get("1").path, "/books/one.epub", "download path survives restart")

eq(Paths.cover_path("7", "scope"), Paths.covers_dir() .. "/scope-7.jpg",
    "scoped cover path fallback")
eq(Paths.cover_path("../7"), Paths.covers_dir() .. "/.._7.jpg",
    "cover id cannot add a path separator")

local lfs = package.loaded["libs/libkoreader-lfs"]
local disk = {}
function lfs.attributes(path, field)
    local a = disk[path]
    if not a then return nil end
    if field then return a[field] end
    return a
end

local function write_file(path, body, mtime)
    local f = assert(io.open(path, "wb"))
    f:write(body)
    f:close()
    disk[path] = { mode = "file", size = #body, modification = mtime or 1 }
end

local dir = "/tmp/hansel-cache-hash"
os.execute("mkdir -p " .. dir)
local a_path = dir .. "/a.epub"
local b_path = dir .. "/b.epub"
local pin_path = dir .. "/pin.epub"
write_file(a_path, "hello-cache-a", 10)
write_file(b_path, "hello-cache-bb", 11)
write_file(pin_path, "pinned-book", 12)

local h1 = CacheMap.file_hash(a_path)
ok(type(h1) == "string" and #h1 > 0, "chunked hash returns a string")
eq(CacheMap.file_hash(a_path), h1, "unchanged size/mtime skips rehash")
write_file(a_path, "HELLO-CACHE-A", 10)
eq(CacheMap.file_hash(a_path), h1, "same size and mtime keeps cached hash")
write_file(a_path, "HELLO-CACHE-A", 99)
ok(CacheMap.file_hash(a_path) ~= h1, "mtime change recomputes hash")

CacheMap.record_download("10", a_path, #("HELLO-CACHE-A"), { owned = true })
CacheMap.record_download("11", b_path, #("hello-cache-bb"), { owned = true })
CacheMap.record_download("12", pin_path, #("pinned-book"), { owned = true })
CacheMap.set_pinned("12", true)
CacheMap.get("10").last_access = 1
CacheMap.get("11").last_access = 2
CacheMap.flush()

ok(CacheMap.evict_for(#("HELLO-CACHE-A")), "evict_for frees oldest owned bytes")
eq(CacheMap.local_path("10"), nil, "oldest unpinned file evicted")
ok(CacheMap.local_path("11") ~= nil, "newer unpinned file kept when enough freed")
eq(CacheMap.state("12"), "pinned", "pinned file is never evicted")

eq(CacheMap.free_unpinned(), 1, "free_unpinned removes remaining unpinned owned")
eq(CacheMap.local_path("11"), nil, "unpinned file removed")
eq(CacheMap.state("12"), "pinned", "pinned file survives free_unpinned")
ok(io.open(pin_path, "rb") ~= nil, "pinned bytes remain on disk")
local pin_f = io.open(pin_path, "rb")
if pin_f then pin_f:close() end

-- Cover hits and explicit refresh must stay inside the active account, even
-- when both accounts use the same book ID. Exercise real files and fetches.
local cover_dir = Paths.covers_dir()
os.execute("mkdir -p " .. cover_dir)
disk[cover_dir] = { mode = "directory" }
function lfs.dir(path)
    local names = { ".", ".." }
    for entry in pairs(disk) do
        if entry:sub(1, #path + 1) == path .. "/" then
            local name = entry:sub(#path + 2)
            if not name:find("/", 1, true) then names[#names + 1] = name end
        end
    end
    local index = 0
    return function()
        index = index + 1
        return names[index]
    end
end
local real_remove = os.remove
function os.remove(path)
    local removed, err = real_remove(path)
    if removed then disk[path] = nil end
    return removed, err
end
local fetch_count, fail_fetch = 0, false
local Http = require("lib.http")
function Http.download_file(_, dest)
    fetch_count = fetch_count + 1
    if fail_fetch then return false end
    write_file(dest, "cover-fetch-" .. fetch_count)
    return true
end
package.loaded["lib.session"] = {
    network_available = function() return true end,
    peek_token = function() return "test-bearer" end,
}
local book = { id = "1" }
eq(Covers.fetch_one(book), first_cover, "first account fetch writes scoped cover")
eq(fetch_count, 1, "first account cover fetched once")
eq(Covers.fetch_one(book), first_cover, "repeat fetch uses cached hit")
eq(fetch_count, 1, "cached cover avoids download")
Settings.set_t2_credentials("other", "secret")
eq(Covers.cached("1"), nil, "first account memory hit cannot leak to second")
eq(Covers.fetch_one(book), second_cover, "second account fetch has its own file")
local second_initial = assert(io.open(second_cover, "rb"))
local second_bytes = second_initial:read("*a")
second_initial:close()
Settings.set_t2_credentials("reader", "secret")
eq(Covers.cached("1"), first_cover, "switching back restores scoped memory hit")

local unpinned_path = dir .. "/keep.epub"
write_file(unpinned_path, "keep-download", 20)
CacheMap.record_download("13", unpinned_path, 13, { owned = true })
CacheMap.set_open_path(pin_path)
local account_before = Settings.account_key()
local password_before = Settings.t2_password()
local pending = { id = "pending" }
local callback_count = 0
Covers.fetch_visible({ pending }, function() callback_count = callback_count + 1 end)
local before_clear = fetch_count
-- Stale partial artwork also belongs to this account, but a foreign file and
-- an unscoped legacy cover have no current-account ownership to clear.
local partial = Covers.path("pending") .. ".part"
write_file(partial, "partial")
local unrelated = cover_dir .. "/unrelated.txt"
local legacy_cover = cover_dir .. "/unscoped.jpg"
write_file(unrelated, "keep-unrelated")
write_file(legacy_cover, "keep-legacy")
eq(Covers.clear(), 2, "clear removes active cover and partial only")
env.UIManager:drain()
eq(fetch_count, before_clear, "clear cancels queued downloads")
eq(callback_count, 0, "canceled fetch does not repaint stale artwork")
eq(Covers.cached("1"), nil, "clear forgets active account memory hit")
eq(Covers.fetch_one(book), first_cover, "clear allows fresh artwork fetch")
eq(fetch_count, before_clear + 1, "fresh artwork downloaded after clear")
eq(CacheMap.state("12"), "pinned", "cover clear preserves pin")
eq(CacheMap.local_path("12"), pin_path, "cover clear preserves pinned download")
eq(CacheMap.local_path("13"), unpinned_path, "cover clear preserves unpinned download")
eq(CacheMap.load().open_path, pin_path, "cover clear preserves currently open book")
eq(Settings.account_key(), account_before, "cover clear preserves account settings")
eq(Settings.t2_password(), password_before, "cover clear preserves credentials")
ok(lfs.attributes(pin_path, "mode") == "file", "pinned book bytes survive")
ok(lfs.attributes(unpinned_path, "mode") == "file", "unpinned book bytes survive")
ok(lfs.attributes(unrelated, "mode") == "file", "unrelated cover-directory file survives")
ok(lfs.attributes(legacy_cover, "mode") == "file", "unowned legacy artwork survives")
Settings.set_t2_credentials("other", "secret")
eq(Covers.cached("1"), second_cover, "other account memory hit survives clear")
local second_f = assert(io.open(second_cover, "rb"))
eq(second_f:read("*a"), second_bytes, "other account cover bytes unchanged")
second_f:close()
fail_fetch = true
Covers.fetch_visible({ { id = "other-failed" } })
env.UIManager:drain()
local other_failure_count = fetch_count
Settings.set_t2_credentials("reader", "secret")
Covers.clear()
Settings.set_t2_credentials("other", "secret")
Covers.fetch_visible({ { id = "other-failed" } })
env.UIManager:drain()
eq(fetch_count, other_failure_count, "other account failure backoff survives clear")
Settings.set_t2_credentials("reader", "secret")
-- Clear resets this account's failure backoff, so updated covers can retry
-- immediately rather than waiting five minutes after a previous failure.
fail_fetch = true
Covers.fetch_visible({ { id = "failed" } })
env.UIManager:drain()
local after_failure = fetch_count
Covers.fetch_visible({ { id = "failed" } })
env.UIManager:drain()
eq(fetch_count, after_failure, "failed cover remains in backoff before clear")
Covers.clear()
fail_fetch = false
Covers.fetch_visible({ { id = "failed" } })
env.UIManager:drain()
eq(fetch_count, after_failure + 1, "clear forgets active cover failure backoff")
ok(Covers.cached("failed") ~= nil, "failed cover fetched successfully after clear")
os.remove = real_remove

print("cache scope: " .. checks .. " ok")
