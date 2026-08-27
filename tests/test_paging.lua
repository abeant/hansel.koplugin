--[[--
Page turns on every shelf: All Books, On this device, category/tag/series/
author lists, and the book grid inside a facet feed.

The failure this pins down: page 2 of a category returned total=0 because that
*page* was not in the feed cache, so Home painted "2 / 1" and "This shelf is
empty" even though page 1 still had the books.
]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
local env = Stub.install()
env.NetworkMgr.online = false

local Settings = require("lib.settings")
local Paths = require("lib.paths")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t1_credentials("device", "secret")
Settings.set("hide_unavailable", false)
Settings.set("grid_density", "3x3")

local ORIGIN = "http://grimmory.test:6060"
local identity = Settings.account_key()

local by_id = {}
local all_ids = {}
for i = 1, 50 do
    local id = tostring(i)
    all_ids[#all_ids + 1] = id
    local nn = string.format("%02d", i)
    by_id[id] = {
        id = id,
        title = "Horror " .. nn,
        authors = { "Author " .. nn },
        categories = (i <= 25) and { "Cat" .. nn, "Horror" } or { "Cat" .. nn },
        tags = { "Tag" .. nn },
        series = "Series " .. nn,
        file_type = (i <= 20) and "epub" or "pdf",
        added_on = string.format("2026-01-%02dT10:00:00Z", (i % 28) + 1),
        shelves = { { name = "Favorites", id = "17" } },
    }
end

env.settings_files[Paths.catalog_file()] = {
    catalog = {
        version = 2,
        accounts = {
            [identity] = {
                pages = {
                    ["all:1:9"] = {
                        ids = { "1", "2", "3", "4", "5", "6", "7", "8", "9" },
                        total = 50, page = 1, size = 9, fetched_at = 10, view = "all",
                    },
                },
                by_id = by_id,
                manifest = { total = 50, fetched_at = 10 },
            },
        },
    },
}

local local_ids = {}
for i = 1, 20 do local_ids[tostring(i)] = true end
package.loaded["lib.cache_map"] = {
    local_books = function()
        local rows = {}
        for i = 1, 20 do
            rows[#rows + 1] = {
                id = tostring(i),
                title = by_id[tostring(i)].title,
                file_type = "epub",
            }
        end
        return rows
    end,
    local_path = function(id) return local_ids[tostring(id)] and ("/books/" .. id .. ".epub") end,
    state = function(id) return local_ids[tostring(id)] and "cached" or "remote" end,
    get = function(id)
        if local_ids[tostring(id)] then
            return { path = "/books/" .. id .. ".epub", pinned = false }
        end
        return nil
    end,
    revision = function() return 1 end,
    continue_ids = function() return { "1", "2" } end,
    on_device_ids = function()
        local ids = {}
        for i = 1, 20 do ids[i] = tostring(i) end
        return ids
    end,
}

package.loaded["lib.api"] = {
    rest_get = function()
        return false, 0, nil, nil, { ok = false, status = 0, error_kind = "offline" }
    end,
}
package.loaded["lib.http"] = {
    get = function() return false, 0, nil end,
    post_json = function() return false, 0 end,
    json = function() return false, 0 end,
}

package.loaded["lib.books"] = nil
package.loaded["ui.filter"] = nil
package.loaded["lib.library"] = nil
package.loaded["lib.catalog"] = nil
package.loaded["lib.nav"] = nil

local Catalog = require("lib.catalog")
local Library = require("lib.library")
local Filter = require("ui.filter")
local Nav = require("lib.nav")
local UIManager = env.UIManager

local checks = 0
local function ok(cond, msg)
    checks = checks + 1
    if not cond then error("FAIL: " .. tostring(msg), 2) end
end
local function eq(actual, expected, msg)
    checks = checks + 1
    if actual ~= expected then
        error(("FAIL %s: %s ~= %s"):format(msg, tostring(actual), tostring(expected)), 2)
    end
end

local function collected_text(widget)
    local seen = {}
    for _, child in ipairs((widget._draw and widget._draw.owned) or {}) do
        if child.text then seen[tostring(child.text)] = true end
    end
    return seen
end

local function paint(widget, label)
    widget:paintTo(env.bb, 0, 0)
    ok(widget._draw ~= nil, label .. " has no draw list")
end

local all_state = {
    device = "all",
    status = {},
    formats = {},
    sort_key = "title",
    sort_dir = "asc",
}

-- ---------- parse_facet ----------

local horror_url = ORIGIN .. "/api/v1/books/page?facet=genre:Horror"
local tag_url = ORIGIN .. "/api/v1/books/page?facet=tag:Tag01"
local series_url = ORIGIN .. "/api/v1/books/page?facet=series:Series%2001"
local author_url = ORIGIN .. "/api/v1/books/page?facet=author:Author%2001"
local shelf_url = ORIGIN .. "/api/v1/books/page?facet=shelf:17"
local magic_url = ORIGIN .. "/api/v1/books/page?facet=shelf:magic%3A8"

eq(Library.parse_facet(horror_url).key, "genre", "parse genre key")
eq(Library.parse_facet(horror_url).value, "Horror", "parse genre value")
eq(Library.parse_facet(tag_url).value, "Tag01", "parse tag")
eq(Library.parse_facet(series_url).value, "Series 01", "parse encoded series")
eq(Library.parse_facet(author_url).value, "Author 01", "parse encoded author")
eq(Library.parse_facet(shelf_url).value, "17", "parse shelf id")
eq(Library.parse_facet(magic_url).value, "magic:8", "parse magic shelf")

-- Only page 1 of the Horror feed is cached - this is the live bug setup.
local horror_page1 = {}
for i = 1, 9 do horror_page1[i] = by_id[tostring(i)] end
Catalog.put_page(horror_url, 1, 9, horror_page1, 25)

-- ---------- Library.query / Library.page over a facet ----------

local function feed_state(url)
    local st = {}
    for k, v in pairs(all_state) do st[k] = v end
    st.feed_url = url
    return st
end

local horror1 = Library.query(feed_state(horror_url), 1, 9)
eq(horror1.total, 25, "horror total is the matching set, not the cached page")
eq(#horror1.books, 9, "horror page 1 size")
eq(horror1.books[1].title, "Horror 01", "horror page 1 first")
eq(horror1.books[9].title, "Horror 09", "horror page 1 last")

local horror2 = Library.query(feed_state(horror_url), 2, 9)
eq(horror2.page, 2, "horror stays on page 2")
eq(horror2.total, 25, "horror page 2 keeps the full total")
eq(#horror2.books, 9, "horror page 2 is not empty")
eq(horror2.books[1].title, "Horror 10", "horror page 2 first")
eq(horror2.books[9].title, "Horror 18", "horror page 2 last")
ok(horror2.total / 9 > 1, "horror pager has more than one page")

local horror3 = Library.query(feed_state(horror_url), 3, 9)
eq(#horror3.books, 7, "horror last page remainder")
eq(horror3.total, 25, "horror last page total")

-- Direct page() cache miss used to return total=0, books={}.
local missed = Library.page(horror_url, 2, 9)
eq(missed.source, "cache", "facet cache miss fills from catalog")
eq(missed.total, 25, "facet cache miss keeps matching total")
ok(#missed.books > 0, "facet cache miss is not an empty shelf")

local tag1 = Library.query(feed_state(tag_url), 1, 9)
eq(tag1.total, 1, "tag facet matches one book")
eq(tag1.books[1].title, "Horror 01", "tag facet book")

local series1 = Library.query(feed_state(series_url), 1, 9)
eq(series1.total, 1, "series facet matches one book")

local author1 = Library.query(feed_state(author_url), 1, 9)
eq(author1.total, 1, "author facet matches one book")

local shelf1 = Library.query(feed_state(shelf_url), 1, 9)
eq(shelf1.total, 50, "shelf facet matches by id")
local shelf2 = Library.query(feed_state(shelf_url), 2, 9)
eq(#shelf2.books, 9, "shelf page 2 is not empty")
eq(shelf2.total, 50, "shelf page 2 keeps total")

-- A filter on a feed must not collapse the pager to the current page length.
local epub_state = feed_state(horror_url)
epub_state.formats = { epub = true }
local horror_epub = Library.query(epub_state, 2, 9)
eq(horror_epub.total, 20, "filtered horror total is the filtered set")
ok(#horror_epub.books > 0, "filtered horror page 2 still has books")
ok(horror_epub.total > #horror_epub.books, "filtered total is not the page slice")

-- All Books / On this device still page over the unified snapshot.
local all2 = Library.query(all_state, 2, 9)
eq(all2.total, 50, "all-books total across pages")
eq(#all2.books, 9, "all-books page 2")
local device_state = {
    device = "downloaded",
    status = {},
    formats = {},
    sort_key = "title",
    sort_dir = "asc",
}
local device2 = Library.query(device_state, 2, 9)
eq(device2.total, 20, "on-device total")
eq(#device2.books, 9, "on-device page 2")

-- ---------- Home: facet feed page turn ----------

package.loaded["lib.covers"] = {
    cached = function() return nil end,
    fetch_visible = function() end,
    cancel = function() end,
    prefetch_next = function() end,
    usage_bytes = function() return 0 end,
}
package.loaded["ui.home"] = nil
local Home = require("ui.home")
local home = Home:new{ plugin = { open_book = function() end } }
UIManager:drain()
paint(home, "home all")

home:open_feed(horror_url, "Horror")
UIManager:drain()
eq(home.page, 1, "opening a category starts on page 1")
ok(#home.books > 0, "category page 1 loaded books")
ok(home.total > Settings.page_size(), "category has more than one grid page")
local page1_first = home.books[1] and home.books[1].id

home:onNextPage()
UIManager:drain()
paint(home, "category page 2")
eq(home.page, 2, "category swipe stays on page 2")
ok(home:_page_count() >= 2, "category footer is not 2 / 1")
ok(#home.books > 0, "category page 2 is not an empty shelf")
ok(home.books[1] and home.books[1].id ~= page1_first, "category page 2 is a new slice")
local texts = collected_text(home)
ok(not texts["Nothing here yet"], "category page 2 must not show empty title")
ok(not texts["This shelf is empty."], "category page 2 must not show empty body")
ok(texts["2 / " .. tostring(home:_page_count())], "category footer shows 2 / N")

home:onPrevPage()
UIManager:drain()
eq(home.page, 1, "category back to page 1")
ok(#home.books > 0, "category page 1 still has the first slice")
eq(home.books[1].id, page1_first, "category page 1 restored")

-- Same path for tag / series / author / shelf feeds.
local feed_cases = {
    { tag_url, "Tag01", 1 },
    { series_url, "Series 01", 1 },
    { author_url, "Author 01", 1 },
    { shelf_url, "Favorites", 50 },
}
for _, case in ipairs(feed_cases) do
    home:open_feed(case[1], case[2])
    UIManager:drain()
    eq(home.total, case[3], case[2] .. " feed total")
    ok(#home.books > 0, case[2] .. " feed page 1")
    if case[3] > Settings.page_size() then
        home:onNextPage()
        UIManager:drain()
        eq(home.page, 2, case[2] .. " feed page 2")
        ok(#home.books > 0, case[2] .. " feed page 2 not empty")
        ok(home:_page_count() >= 2, case[2] .. " feed footer")
    end
end

-- ---------- Home: nav lists (categories / tags / series / authors) ----------

local function assert_nav(kind, label)
    home:set_view(kind)
    UIManager:drain()
    paint(home, label .. " list")
    ok(home.nav_items and #home.nav_items > Settings.page_size(),
        label .. " list has multiple pages of rows")
    local first = home.nav_items[1] and home.nav_items[1].title
    local n = #home.nav_items
    home:onNextPage()
    UIManager:drain()
    paint(home, label .. " list page 2")
    eq(#home.nav_items, n, label .. " list did not drop rows on page 2")
    eq(home.page, 2, label .. " list stays on page 2")
    ok(home:_page_count() >= 2, label .. " list footer is not 2 / 1")
    local size = home._nav_size or home:_nav_page_size()
    local start = (home.page - 1) * size + 1
    ok(start <= #home.nav_items, label .. " page 2 start is inside the list")
    local row = home.nav_items[start]
    ok(row and row.title, label .. " page 2 has a row")
    ok(row.title ~= first, label .. " page 2 is a new slice")
    local nav_text = collected_text(home)
    ok(not nav_text["Nothing here yet"], label .. " page 2 must not empty")
    ok(nav_text[row.title], label .. " page 2 paints the row title")
    home:onPrevPage()
    UIManager:drain()
    eq(home.page, 1, label .. " list back to page 1")
    eq(home.nav_items[1].title, first, label .. " list restored page 1")
end

Nav.harvest()
assert_nav("categories", "categories")
assert_nav("tags", "tags")
assert_nav("series", "series")
assert_nav("authors", "authors")

-- All Books grid page turn (unified snapshot, not a feed cache).
home:set_view("all")
UIManager:drain()
local all_first = home.books[1] and home.books[1].id
home:onNextPage()
UIManager:drain()
eq(home.page, 2, "all-books page 2")
ok(#home.books > 0, "all-books page 2 not empty")
ok(home.books[1].id ~= all_first, "all-books page 2 is a new slice")

home:set_view("on_device")
UIManager:drain()
ok(home.total == 20 or #home.books > 0, "on-device loaded")
if home:_page_count() >= 2 then
    local dev_first = home.books[1] and home.books[1].id
    home:onNextPage()
    UIManager:drain()
    eq(home.page, 2, "on-device page 2")
    ok(#home.books > 0, "on-device page 2 not empty")
    ok(home.books[1].id ~= dev_first, "on-device page 2 is a new slice")
end

print("paging: " .. checks .. " ok")
