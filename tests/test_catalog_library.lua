package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
local env = Stub.install()

local Settings = require("lib.settings")
local Paths = require("lib.paths")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t2_credentials("reader", "secret")

-- Seed the URL-keyed shape written by older builds before opening Catalog.
local identity = Settings.account_key()
env.settings_files[Paths.catalog_file()] = {
    catalog = {
        pages = {
            ["http://grimmory.test:6060/api/v1/books/page?page=0&size=9"] = {
                ids = { "1" }, total = 1, page = 1, size = 9, fetched_at = 10,
            },
        },
        by_id = { ["1"] = { id = "1", title = "Zulu", file_type = "epub" } },
        manifest = { total = 1, fetched_at = 10 },
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

local Catalog = require("lib.catalog")
local migrated = Catalog.get_page("all", 1, 12)
ok(migrated and #migrated.books == 1, "legacy URL page migrates to all")
eq(migrated.books[1].id, "1", "legacy book retained")
local stored_root = env.settings_files[Paths.catalog_file()].catalog
ok(stored_root.accounts and stored_root.accounts[identity], "legacy cache account-scoped")
ok(stored_root.accounts[identity].pages["all:1:9"], "canonical all key persisted")

-- Page size/grid changes reuse the same logical page rather than missing cache.
local resized = Catalog.get_page("all", 1, 20)
ok(resized and resized.books[1].id == "1", "grid-density cache fallback")

-- Catalog data is isolated by normalized server + account.
Settings.set_t2_credentials("someone-else", "secret")
eq(Catalog.get_page("all", 1, 12), nil, "second account cannot see first catalog")
Settings.set_t2_credentials("reader", "secret")
ok(Catalog.get_page("all", 1, 12) ~= nil, "original account catalog restored")

-- A successful write survives a module restart.
Catalog.put_page("all", 1, 20, {
    { id = "1", title = "Zulu", file_type = "epub" },
    { id = "2", title = "Delta", file_type = "pdf" },
}, 2)
package.loaded["lib.catalog"] = nil
Catalog = require("lib.catalog")
local reopened = Catalog.get_page("all", 1, 20)
eq(#reopened.books, 2, "catalog survives offline restart")
Catalog.put_page("all", 1, 20, reopened.books, 99)

local local_rows = {
    { id = "2", title = "Delta", file_type = "pdf" },
    { id = "3", title = "Alpha", file_type = "epub" },
    { id = "4", title = "Charlie", file_type = "epub" },
    { id = "5", title = "Bravo", file_type = "epub" },
}
local local_ids = { ["2"] = true, ["3"] = true, ["4"] = true, ["5"] = true }
local cache_rev = 1
package.loaded["lib.cache_map"] = {
    local_books = function() return local_rows end,
    local_path = function(id) return local_ids[tostring(id)] and ("/books/" .. id .. ".epub") end,
    state = function(id) return local_ids[tostring(id)] and "cached" or "remote" end,
    get = function() return nil end,
    revision = function() return cache_rev end,
}
package.loaded["lib.books"] = nil
package.loaded["ui.filter"] = nil
package.loaded["lib.library"] = nil
local api_reply
package.loaded["lib.api"] = {
    rest_get = function()
        return true, 200, api_reply, nil, { ok = true, status = 200, body = api_reply }
    end,
}

local Library = require("lib.library")
local all_state = {
    device = "all",
    status = { unread = true, reading = true, finished = true },
    formats = {}, sort_key = "title", sort_dir = "asc",
}
local downloaded_state = {
    device = "downloaded",
    status = all_state.status,
    formats = {}, sort_key = "title", sort_dir = "asc",
}
local remote_state = {
    device = "remote",
    status = all_state.status,
    formats = {}, sort_key = "title", sort_dir = "asc",
}

env.NetworkMgr.online = false
local all = Library.query(all_state, 1, 20)
eq(#all.books, 5, "All unions cached server and four downloads")
eq(all.known_total, 5, "server/local duplicate removed by Grimmory id")
eq(all.total, 5, "offline pager exposes saved books rather than ghost server pages")
ok(all.unavailable and all.error_kind == "offline", "saved library reports offline quietly")

local downloaded = Library.query(downloaded_state, 1, 20)
eq(#downloaded.books, 4, "Downloaded remains local-only offline")
for _, book in ipairs(downloaded.books) do
    ok(book.state ~= "remote", "downloaded filter excludes remote records")
end

local remote = Library.query(remote_state, 1, 20)
eq(#remote.books, 1, "Server only excludes an already-downloaded duplicate")
eq(remote.books[1].id, "1", "remote-only record retained")
ok(remote.unavailable, "Server only knows server result is unavailable")

-- Sorting/filtering happens over the unified snapshot before it is sliced.
local second_page = Library.query(all_state, 2, 2)
eq(second_page.books[1].title, "Charlie", "sort precedes pagination (first)")
eq(second_page.books[2].title, "Delta", "sort precedes pagination (second)")
eq(second_page.total, 5, "unified total retained across pages")

local recovered_page = Library.query(all_state, 9, 20)
eq(recovered_page.page, 1, "offline restart clamps a stale page number")
eq(#recovered_page.books, 5, "stale offline page still shows saved books")

local all_calls = 0
local orig_all = Catalog.all_books
function Catalog.all_books()
    all_calls = all_calls + 1
    return orig_all()
end
cache_rev = cache_rev + 1
local first_snap = Library.query(all_state, 1, 20)
local reused = Library.query(all_state, 2, 2)
eq(all_calls, 1, "unified snapshot reused until revision changes")
eq(reused.total, first_snap.total, "cached snapshot keeps derived total")
eq(first_snap.counts.known, 5, "derived known count")
eq(first_snap.counts.downloaded, 4, "derived downloaded count")
eq(first_snap.counts.remote, 1, "derived remote count")

Catalog.put_page("all", 1, 20, {
    { id = "1", title = "Zulu", file_type = "epub" },
    { id = "6", title = "Echo", file_type = "epub" },
}, 3)
local after_catalog = Library.query(all_state, 1, 20)
ok(all_calls >= 2, "catalog write rebuilds snapshot")
eq(after_catalog.counts.known, 6, "catalog change updates derived known")

cache_rev = cache_rev + 1
local_rows[#local_rows + 1] = { id = "7", title = "Foxtrot", file_type = "epub" }
local_ids["7"] = true
local after_cache = Library.query(all_state, 1, 20)
ok(all_calls >= 3, "cache revision rebuilds snapshot")
eq(after_cache.counts.known, 7, "cache change updates derived known")
Catalog.all_books = orig_all

-- Current Grimmory BookFile fields normalize alongside older payload shapes.
api_reply = {
    content = {{
        id = 9,
        title = "Current payload",
        addedOn = "2026-08-24T10:00:00Z",
        primaryFile = {
            id = 91, fileName = "current.epub", extension = "EPUB", fileSizeKb = 256,
        },
        metadata = {
            title = "Current payload", authors = { "An Author" },
            seriesName = "A Series", seriesNumber = 3.5,
            publishedDate = "2026-01-01",
        },
    }},
    page = { totalElements = 1 },
}
local current = Library.fetch_feed("http://grimmory.test:6060/api/v1/books/page", 1, 9,
    { cache_key = "current-shape" })
eq(current.books[1].filename, "current.epub", "current BookFile filename")
eq(current.books[1].file_type, "epub", "current BookFile extension")
eq(current.books[1].file_size, 256 * 1024, "current BookFile size converted from KiB")
eq(current.books[1].series_index, 3.5, "current series position")

print("catalog/library: " .. checks .. " ok")
