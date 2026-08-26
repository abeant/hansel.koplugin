local API = require("lib.api")
local Catalog = require("lib.catalog")
local Http = require("lib.http")
local OPDS = require("lib.opds")
local Origin = require("lib.origin")
local Settings = require("lib.settings")
local logger = require("logger")

local Nav = {}

local KINDS = {
    series = "series",
    authors = "authors",
    shelves = "shelves",
    magic = "magic-shelves",
}

-- Grimmory filter-options / facets: categories + tags. No genres resource.
-- Grimmory books/page uses facet=genre:Horror and query covers "genre" + "tag".
-- filter-options exposes categories[] and tags[]. There is no genres resource.
local FACET_MATCH = {
    categories = { "genre", "genres", "category", "categories" },
    tags = { "tag", "tags" },
    series = { "series" },
    authors = { "author", "authors" },
    shelves = { "shelf", "shelves" },
}

local _cache = {}
local _places = {}
local _cache_identity

local function account_identity()
    return Settings.account_key and Settings.account_key() or tostring(Settings.server_url())
end

local function persist_places()
    local all = Settings.get("nav_places")
    if type(all) ~= "table" then all = {} end
    all[_cache_identity or account_identity()] = _places
    Settings.set("nav_places", all)
end

local function ensure_cache_identity()
    local identity = account_identity()
    if _cache_identity ~= identity then
        _cache_identity = identity
        _cache = {}
        local all = Settings.get("nav_places")
        local stored = type(all) == "table" and all[identity]
        _places = type(stored) == "table" and stored or {}
    end
end

local function creds()
    return Settings.get("t1_username"), Settings.t1_password()
end

function Nav.get(kind)
    ensure_cache_identity()
    return _cache[kind] or { items = {} }
end

local function urlencode(s)
    s = tostring(s or "")
    s = s:gsub("\n", "\r\n"):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return s
end

local FACET_KEY = {
    categories = "genre",
    tags = "tag",
    series = "series",
    authors = "author",
    shelves = "shelf",
}

local function facet_href(kind, name)
    local origin = Settings.server_url()
    if not origin then return nil end
    local key = FACET_KEY[kind] or kind
    return origin .. "/api/v1/books/page?facet=" .. key .. ":" .. urlencode(name)
end

local function decode_json(blob)
    if type(blob) == "table" then return blob end
    local ok_j, json = pcall(require, "json")
    if not ok_j or not json or not json.decode then return nil end
    local s, r = pcall(json.decode, blob)
    return s and r or nil
end

local function items_from_facet_group(group, kind)
    local items = {}
    for _, link in ipairs((group and group.links) or {}) do
        local name = link.title or link.value
        if name and name ~= "" then
            local n = link.properties and tonumber(link.properties.numberOfItems)
            items[#items + 1] = {
                title = name,
                count = n,
                href = facet_href(kind, link.value or name),
            }
        end
    end
    return items
end

local function magic_list()
    local ok, _, body = API.rest_get("/api/magic-shelves")
    if not ok then return nil end
    local rows = decode_json(body)
    if type(rows) ~= "table" then return nil end
    local items = {}
    for _, row in ipairs(rows) do
        if row.id and row.name then
            items[#items + 1] = {
                title = row.name,
                href = facet_href("shelves", "magic:" .. tostring(row.id)),
            }
        end
    end
    table.sort(items, function(a, b) return a.title < b.title end)
    return { items = items }
end

local function facet_list(kind)
    local needles = FACET_MATCH[kind]
    if not needles then return nil end
    local origin = Settings.server_url()
    if not origin then return nil end
    local ok, _, body = API.rest_get("/api/v1/books/facets")
    if not ok then return nil end
    local payload = decode_json(body)
    if type(payload) ~= "table" or type(payload.facets) ~= "table" then return nil end
    local picked
    for _, group in ipairs(payload.facets) do
        local meta = group.metadata or {}
        local key = string.lower(tostring(meta.key or meta.rel or ""))
        local title = string.lower(tostring(meta.title or ""))
        for _, needle in ipairs(needles) do
            if key == needle or title == needle then
                picked = group
                break
            end
        end
        if picked then break end
    end
    local items = items_from_facet_group(picked, kind)
    if #items == 0 then return nil end
    table.sort(items, function(a, b) return a.title < b.title end)
    return { items = items }
end

local function filter_options_list(kind)
    local origin = Settings.server_url()
    if not origin then return nil end
    local ok, _, body = API.rest_get("/api/v1/app/filter-options")
    if not ok then return nil end
    local payload = decode_json(body)
    if type(payload) ~= "table" then return nil end
    local rows = payload[kind] or payload[kind:gsub("s$", "")]
    if kind == "genres" then rows = payload.genres end
    if kind == "categories" then rows = payload.categories end
    if kind == "tags" then rows = payload.tags end
    if type(rows) ~= "table" then return nil end
    local items = {}
    local function add(row)
        local name = type(row) == "table" and (row.name or row.title) or row
        if type(name) == "string" and name ~= "" then
            local value = type(row) == "table" and (row.value or row.id) or nil
            items[#items + 1] = {
                title = name,
                count = type(row) == "table" and tonumber(row.count) or nil,
                href = facet_href(kind, value or name),
            }
        end
    end
    if rows[1] ~= nil then
        for _, row in ipairs(rows) do add(row) end
    else
        for name, row in pairs(rows) do
            if type(row) == "table" then add(row) else add(name) end
        end
    end
    if #items == 0 then return nil end
    table.sort(items, function(a, b) return a.title < b.title end)
    return { items = items }
end

local CATALOG_FIELD = {
    categories = "categories",
    tags = "tags",
    series = "series",
    authors = "authors",
    shelves = "shelves",
}

local function harvest_from_catalog(kind)
    local field = CATALOG_FIELD[kind]
    if not field or not Catalog.all_books then return nil end
    local counts = {}
    for _, book in ipairs(Catalog.all_books()) do
        local values = book[field]
        if type(values) == "string" then values = { values } end
        for _, row in ipairs(type(values) == "table" and values or {}) do
            local name = type(row) == "table" and (row.name or row.title) or row
            local value = type(row) == "table" and (row.id or row.value) or name
            if type(name) == "string" and name ~= "" then
                local rec = counts[name] or { count = 0, value = value }
                rec.count = rec.count + 1
                counts[name] = rec
            end
        end
    end
    local items = {}
    for name, rec in pairs(counts) do
        items[#items + 1] = {
            title = name,
            count = rec.count,
            href = facet_href(kind, rec.value or name),
        }
    end
    if #items == 0 then return nil end
    table.sort(items, function(a, b) return a.title < b.title end)
    return { items = items }
end

function Nav.fetch(kind)
    ensure_cache_identity()
    if kind == "magic" and Settings.has_tier2() then
        local from_rest = magic_list()
        if from_rest then
            _cache[kind] = from_rest
            return from_rest
        end
    end
    if FACET_MATCH[kind] and Settings.has_tier2() then
        local from_rest = filter_options_list(kind) or facet_list(kind)
        if from_rest then
            _cache[kind] = from_rest
            return from_rest
        end
    end
    local spec = KINDS[kind]
    local paths = type(spec) == "table" and spec or { spec }
    local origin = Settings.server_url()
    local user, password = creds()
    if spec and Settings.has_tier1() then
        for _, path in ipairs(paths) do
            local url = Origin.opds_nav(origin, path)
            if url then
                local ok, code, body = Http.get(url, {
                    user = user,
                    password = password,
                    timeout_block = 8,
                    timeout_total = 15,
                })
                if ok then
                    local parsed = OPDS.parse_nav(body, url)
                    if parsed.items and #parsed.items > 0 then
                        _cache[kind] = parsed
                        return parsed
                    end
                else
                    logger.dbg("[hansel] nav fetch failed", kind, path, code)
                end
            end
        end
    end
    local saved = FACET_MATCH[kind] and harvest_from_catalog(kind)
    if saved then
        _cache[kind] = saved
        return saved
    end
    return _cache[kind] or { items = {} }
end

function Nav.href(name, kind)
    return facet_href(kind or "categories", name)
end

function Nav.refresh()
    ensure_cache_identity()
    local seen = {}
    for kind in pairs(KINDS) do Nav.fetch(kind) seen[kind] = true end
    for kind in pairs(FACET_MATCH) do if not seen[kind] then Nav.fetch(kind) end end
end

function Nav.place_key(kind, id)
    kind = tostring(kind or "all")
    if kind == "all" or kind == "" then return "all" end
    if kind == "search" then
        local q = tostring(id or ""):gsub("^%s+", ""):gsub("%s+$", "")
        return q == "" and "search" or ("search:" .. q)
    end
    if id == nil or id == "" then return kind end
    return kind .. ":" .. tostring(id)
end

function Nav.remember(key, place)
    ensure_cache_identity()
    key = Nav.place_key(key)
    if type(place) ~= "table" then return end
    local page = tonumber(place.page) or 1
    if page < 1 then page = 1 end
    local position = tonumber(place.position) or 0
    if position < 0 then position = 0 end
    _places[key] = { page = page, position = position }
    persist_places()
end

function Nav.recall(key)
    ensure_cache_identity()
    key = Nav.place_key(key)
    local rec = _places[key]
    if type(rec) ~= "table" then
        return { page = 1, position = 0 }
    end
    local page = tonumber(rec.page) or 1
    local position = tonumber(rec.position) or 0
    if page < 1 then page = 1 end
    if position < 0 then position = 0 end
    return { page = page, position = position }
end

return Nav
