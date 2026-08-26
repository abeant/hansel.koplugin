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

print("cache scope: " .. checks .. " ok")
