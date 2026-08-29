package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.reset_settings()
Stub.install()

package.loaded["lib.session"] = { reset = function() end }
package.loaded["lib.http"] = {
    get = function() return true, 200, "<feed/>" end,
}
package.loaded["lib.opds"] = {
    parse_nav = function()
        return { items = { { title = "Tier 1 series", href = "/series/1" } } }
    end,
}
local Settings = require("lib.settings")
Settings.load()
Settings.set_server_url("http://grimmory.test:6060")
Settings.set_t2_credentials("reader", "secret")

local calls = {}
package.loaded["lib.api"] = {
    rest_get = function(path)
        calls[#calls + 1] = path
        if path == "/api/magic-shelves" then
            return true, 200, { { id = 8, name = "Unread later" } }
        end
        if path == "/api/v1/libraries" then
            return true, 200, {
                { id = 1, name = "Library", bookCount = 429 },
                { id = 4, name = "Classics", bookCount = 24 },
            }
        end
        if path == "/api/v1/shelves" then
            return true, 200, {
                { id = 17, name = "Favorites", bookCount = 4 },
            }
        end
        if path == "/api/v1/books/facets" then
            return true, 200, { facets = {
                { metadata = { key = "series", title = "Series" },
                    links = { { title = "Earthsea", value = "Earthsea",
                        properties = { numberOfItems = 6 } } } },
                { metadata = { key = "author", title = "Authors" },
                    links = { { title = "Ursula K. Le Guin", value = "Ursula K. Le Guin",
                        properties = { numberOfItems = 9 } } } },
                { metadata = { key = "shelf", title = "Shelves" },
                    links = { { title = "Favorites", value = "17",
                        properties = { numberOfItems = 4 } } } },
            } }
        end
        return false, 404, "not supported"
    end,
}

local Nav = require("lib.nav")
local checks = 0
local function eq(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, ("FAIL %s: %s ~= %s"):format(message,
        tostring(actual), tostring(expected)))
end

local series = Nav.fetch("series").items[1]
local authors = Nav.fetch("authors").items[1]
local shelves = Nav.fetch("shelves").items[1]
local magic = Nav.fetch("magic").items[1]
local libraries = Nav.fetch("libraries").items
eq(series.title, "Earthsea", "series fetched over JWT navigation")
eq(authors.title, "Ursula K. Le Guin", "authors fetched over JWT navigation")
eq(shelves.href:match("facet=shelf:17") ~= nil, true, "shelf facet uses server id")
eq(magic.href:match("facet=shelf:magic%%3A8") ~= nil, true, "magic shelf uses REST facet")
eq(#libraries, 2, "libraries fetched over REST")
eq(libraries[1].title, "Classics", "libraries sorted by name")
eq(libraries[1].id, "4", "library id is the Grimmory id")

Settings.set_t2_credentials("other", "secret")
eq(#Nav.get("series").items, 0, "navigation memory cache is account scoped")

Settings.clear_t2()
Settings.set_t1_credentials("opds-reader", "opds-secret")
eq(Nav.fetch("series").items[1].title, "Tier 1 series",
    "Tier 1 series navigation falls back to OPDS")

eq(Nav.place_key("all"), "all", "all-books key")
eq(Nav.place_key("search", "  Earthsea  "), "search:Earthsea", "search key trims")
eq(Nav.place_key("shelf", 17), "shelf:17", "per-shelf key")
eq(Nav.place_key("author", "Ursula K. Le Guin"), "author:Ursula K. Le Guin", "author key")
eq(Nav.place_key("series", "Earthsea"), "series:Earthsea", "series key")

Nav.remember("all", { page = 4, position = 12 })
Nav.remember(Nav.place_key("shelf", 17), { page = 2, position = 3 })
Nav.remember(Nav.place_key("author", "Ursula K. Le Guin"), { page = 5, position = 0 })
Nav.remember(Nav.place_key("series", "Earthsea"), { page = 3, position = 8 })
Nav.remember(Nav.place_key("search", "Earthsea"), { page = 7, position = 1 })

eq(Nav.recall("all").page, 4, "all books page remembered")
eq(Nav.recall("all").position, 12, "all books position remembered")
eq(Nav.recall(Nav.place_key("shelf", 17)).page, 2, "shelf page independent")
eq(Nav.recall(Nav.place_key("author", "Ursula K. Le Guin")).page, 5, "author page independent")
eq(Nav.recall(Nav.place_key("series", "Earthsea")).page, 3, "series page independent")
eq(Nav.recall(Nav.place_key("search", "Earthsea")).page, 7, "search page independent")
eq(Nav.recall(Nav.place_key("shelf", 99)).page, 1, "unknown place defaults to page 1")

Nav.remember(Nav.place_key("shelf", 17), { page = 9, position = 4 })
eq(Nav.recall("all").page, 4, "updating a shelf does not move all books")
eq(Nav.recall(Nav.place_key("shelf", 17)).page, 9, "back to shelf restores last place")
eq(Nav.recall(Nav.place_key("search", "Earthsea")).position, 1, "back to search restores position")

Settings.set_t2_credentials("place-other", "secret")
eq(Nav.recall("all").page, 1, "places are account scoped")
Settings.clear_t2()
Settings.set_t1_credentials("opds-reader", "opds-secret")
eq(Nav.recall("all").page, 4, "places return with the account")

-- Offline cooldown must not hammer Grimmory (drawer open used to ANR here).
package.loaded["lib.session"] = {
    reset = function() end,
    should_probe = function() return false end,
}
package.loaded["lib.nav"] = nil
Nav = require("lib.nav")
local before = #calls
Nav.refresh()
eq(#calls, before, "refresh skips HTTP when should_probe is false")

print("nav: " .. checks .. " ok")
