local API = require("lib.api")
local Catalog = require("lib.catalog")
local Http = require("lib.http")
local OPDS = require("lib.opds")
local Origin = require("lib.origin")
local Settings = require("lib.settings")
local logger = require("logger")
local _ = require("gettext")

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
local _fetched_at = 0
local _filter_payload
local _facet_payload
local _rest_index = 0
local NAV_TTL = 120
local NAV_BLOCK = 2
local NAV_TOTAL = 3

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
        _fetched_at = 0
        _filter_payload = nil
        _facet_payload = nil
        _rest_index = 0
        local all = Settings.get("nav_places")
        local stored = type(all) == "table" and all[identity]
        _places = type(stored) == "table" and stored or {}
    end
end

local function can_probe()
    local ok, Session = pcall(require, "lib.session")
    if ok and Session and Session.should_probe then
        return Session.should_probe()
    end
    return true
end

local function rest_get(path)
    return API.rest_get(path, { timeout_block = NAV_BLOCK, timeout_total = NAV_TOTAL })
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

-- Grimmory's library API returns creation order. Sidebar default is name A-Z.
local function title_asc(a, b)
    local an = string.lower(tostring(a.title or a.name or ""))
    local bn = string.lower(tostring(b.title or b.name or ""))
    if an ~= bn then return an < bn end
    return tostring(a.id or "") < tostring(b.id or "")
end

local FACET_KEY = {
    categories = "genre",
    tags = "tag",
    series = "series",
    authors = "author",
    shelves = "shelf",
    libraries = "library",
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

local function rows_from(body)
    local rows = decode_json(body)
    if type(rows) ~= "table" then return nil end
    if rows[1] ~= nil then return rows end
    if type(rows.content) == "table" then return rows.content end
    return nil
end

local function unshelved_count()
    if not Catalog.all_books then return nil end
    local n = 0
    for _, book in ipairs(Catalog.all_books()) do
        local values = book.shelves
        if type(values) == "string" then values = { values } end
        local has = false
        for _, row in ipairs(type(values) == "table" and values or {}) do
            local name = type(row) == "table" and (row.name or row.title) or row
            if name and tostring(name) ~= "" then
                has = true
                break
            end
        end
        if not has then n = n + 1 end
    end
    return n
end

local function unshelved_item()
    local origin = Settings.server_url()
    local href = origin and (origin .. "/api/v1/books/page?facet=unshelved:1") or nil
    return {
        id = "unshelved",
        title = _("Unshelved"),
        count = unshelved_count(),
        href = href,
        icon = "inbox",
        icon_type = "LUCIDE",
        special = "unshelved",
    }
end

local function attach_unshelved(parsed)
    local items = (parsed and parsed.items) or {}
    local out = { unshelved_item() }
    for i = 1, #items do
        if items[i].id ~= "unshelved" and items[i].special ~= "unshelved" then
            out[#out + 1] = items[i]
        end
    end
    return { items = out }
end

-- Grimmory Favorites is a real shelf with a heart. Harvested rows have no
-- icon field; CUSTOM_SVG names are files under /api/v1/icons/{name}/content.
local function apply_icons(items, fetch_custom)
    local Icons = require("lib.icons")
    local n = 0
    for i = 1, #(items or {}) do
        local item = items[i]
        if (not item.icon or item.icon == "") and item.title == "Favorites" then
            item.icon = "heart"
            item.icon_type = item.icon_type or "LUCIDE"
        end
        if string.upper(tostring(item.icon_type or "")) == "CUSTOM_SVG"
                and item.icon and item.icon ~= "" then
            local path = Icons.cached(item.icon)
            if not path and fetch_custom and n < 6 then
                n = n + 1
                path = Icons.fetch(item.icon)
            end
            item.icon_file = path
        end
    end
end

local function libraries_list()
    if not can_probe() then return nil end
    local ok, _, body = rest_get("/api/v1/libraries")
    if not ok then return nil end
    local rows = rows_from(body)
    if not rows then return nil end
    local items = {}
    for i = 1, #rows do
        local row = rows[i]
        local id = row.id or row.libraryId
        local name = row.name or row.title
        if id and name and name ~= "" then
            items[#items + 1] = {
                id = tostring(id),
                title = name,
                count = tonumber(row.bookCount or row.count),
                href = facet_href("libraries", tostring(id)),
                icon = row.icon,
                icon_type = row.iconType or row.icon_type,
            }
        end
    end
    if #items == 0 then return nil end
    table.sort(items, title_asc)
    apply_icons(items, true)
    return { items = items }
end

local function shelves_list()
    if not can_probe() then return nil end
    local ok, _, body = rest_get("/api/v1/shelves")
    if not ok then return nil end
    local rows = rows_from(body)
    if not rows then return nil end
    local items = {}
    for i = 1, #rows do
        local row = rows[i]
        local id = row.id
        local name = row.name or row.title
        if id and name and name ~= "" then
            items[#items + 1] = {
                id = tostring(id),
                title = name,
                count = tonumber(row.bookCount or row.count),
                href = facet_href("shelves", tostring(id)),
                icon = row.icon,
                icon_type = row.iconType or row.icon_type,
            }
        end
    end
    if #items == 0 then return nil end
    table.sort(items, title_asc)
    apply_icons(items, true)
    return { items = items }
end

local function harvest_libraries()
    if not Catalog.all_books then return nil end
    local counts = {}
    for _, book in ipairs(Catalog.all_books()) do
        local id = book.library_id and tostring(book.library_id)
        if id then
            local rec = counts[id] or { count = 0, title = book.library_name or id }
            rec.count = rec.count + 1
            if book.library_name and book.library_name ~= "" then
                rec.title = book.library_name
            end
            counts[id] = rec
        end
    end
    local items = {}
    for id, rec in pairs(counts) do
        items[#items + 1] = {
            id = id,
            title = rec.title,
            count = rec.count,
            href = facet_href("libraries", id),
        }
    end
    if #items == 0 then return nil end
    table.sort(items, title_asc)
    return { items = items }
end

local function magic_list()
    if not can_probe() then return nil end
    local ok, _, body = rest_get("/api/magic-shelves")
    if not ok then return nil end
    local rows = decode_json(body)
    if type(rows) ~= "table" then return nil end
    local items = {}
    for _, row in ipairs(rows) do
        if row.id and row.name then
            items[#items + 1] = {
                title = row.name,
                href = facet_href("shelves", "magic:" .. tostring(row.id)),
                icon = row.icon,
                icon_type = row.iconType or row.icon_type,
            }
        end
    end
    table.sort(items, title_asc)
    apply_icons(items, true)
    return { items = items }
end

local function facet_list(kind)
    local needles = FACET_MATCH[kind]
    if not needles then return nil end
    local origin = Settings.server_url()
    if not origin then return nil end
    if _facet_payload == false then return nil end
    local payload = _facet_payload
    if payload == nil then
        if not can_probe() then
            return nil
        end
        local ok, _, body = rest_get("/api/v1/books/facets")
        payload = ok and decode_json(body) or nil
        _facet_payload = payload or false
    end
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
    table.sort(items, title_asc)
    return { items = items }
end

local function filter_options_list(kind)
    local origin = Settings.server_url()
    if not origin then return nil end
    if _filter_payload == false then return nil end
    local payload = _filter_payload
    if payload == nil then
        if not can_probe() then
            return nil
        end
        local ok, _, body = rest_get("/api/v1/app/filter-options")
        payload = ok and decode_json(body) or nil
        _filter_payload = payload or false
    end
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
    table.sort(items, title_asc)
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
    local overlay = false
    local ok_l, Library = pcall(require, "lib.library")
    local ok_f, Filter = pcall(require, "ui.filter")
    if ok_l and Library.is_unreachable and ok_f and Filter.effective then
        local down = Library.is_unreachable()
        local _, hid = Filter.effective(nil, down)
        overlay = hid and true or false
    end
    local CacheMap
    if overlay then
        local ok_c, cm = pcall(require, "lib.cache_map")
        if ok_c then CacheMap = cm end
    end
    local counts = {}
    for _, book in ipairs(Catalog.all_books()) do
        if overlay and CacheMap and CacheMap.get then
            local e = CacheMap.get(book.id)
            if not (e and e.path) then
                book = nil
            end
        end
        if book then
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
    table.sort(items, title_asc)
    if kind == "shelves" then apply_icons(items, false) end
    return { items = items }
end

function Nav.fetch(kind, opts)
    opts = opts or {}
    ensure_cache_identity()
    local cached = _cache[kind]
    if not opts.force_rest and cached and cached.items and #cached.items > 0
            and _fetched_at > 0 and (os.time() - _fetched_at) < NAV_TTL then
        return cached
    end
    if kind == "libraries" then
        local saved = harvest_libraries()
        if saved then _cache[kind] = saved end
    else
        local saved = FACET_MATCH[kind] and harvest_from_catalog(kind)
        if saved then
            _cache[kind] = saved
        end
    end
    if Settings.has_tier2() and can_probe() then
        if kind == "libraries" then
            local from_rest = libraries_list()
            if from_rest then
                _cache[kind] = from_rest
                return from_rest
            end
        end
        if kind == "shelves" then
            local from_rest = shelves_list()
            if from_rest then
                _cache[kind] = attach_unshelved(from_rest)
                return _cache[kind]
            end
        end
        if kind == "magic" then
            local from_rest = magic_list()
            if from_rest then
                _cache[kind] = from_rest
                return from_rest
            end
        elseif FACET_MATCH[kind] then
            local from_rest = filter_options_list(kind)
            if from_rest then
                _cache[kind] = kind == "shelves" and attach_unshelved(from_rest) or from_rest
                return _cache[kind]
            end
            if not opts.rest_only or _filter_payload == false then
                from_rest = facet_list(kind)
                if from_rest then
                    _cache[kind] = kind == "shelves" and attach_unshelved(from_rest) or from_rest
                    return _cache[kind]
                end
            end
        end
    end
    local spec = KINDS[kind]
    local paths = type(spec) == "table" and spec or { spec }
    local origin = Settings.server_url()
    local user, password = creds()
    if spec and Settings.has_tier1() and can_probe() and not opts.rest_only then
        for i = 1, #paths do
            local path = paths[i]
            local url = Origin.opds_nav(origin, path)
            if url then
                local ok, code, body = Http.get(url, {
                    user = user,
                    password = password,
                    timeout_block = NAV_BLOCK,
                    timeout_total = NAV_TOTAL,
                })
                if ok then
                    local parsed = OPDS.parse_nav(body, url)
                    if parsed.items and #parsed.items > 0 then
                        _cache[kind] = kind == "shelves" and attach_unshelved(parsed) or parsed
                        return _cache[kind]
                    end
                else
                    logger.dbg("[hansel] nav fetch failed", kind, path, code)
                end
            end
        end
    end
    if kind == "shelves" then
        _cache[kind] = attach_unshelved(_cache[kind])
    end
    return _cache[kind] or { items = {} }
end

function Nav.href(name, kind)
    return facet_href(kind or "categories", name)
end

function Nav.harvest()
    ensure_cache_identity()
    for kind in pairs(FACET_MATCH) do
        local saved = harvest_from_catalog(kind)
        if saved then _cache[kind] = saved end
    end
    local libs = harvest_libraries()
    if libs then _cache.libraries = libs end
    _cache.shelves = attach_unshelved(_cache.shelves)
    _fetched_at = os.time()
end

local REST_ORDER = { "libraries", "categories", "tags", "series", "authors", "shelves", "magic" }

function Nav.step_rest()
    ensure_cache_identity()
    if not can_probe() then return false end
    _rest_index = _rest_index + 1
    local kind = REST_ORDER[_rest_index]
    if not kind then return false end
    Nav.fetch(kind, { rest_only = true, force_rest = true })
    return _rest_index < #REST_ORDER
end

function Nav.refresh()
    ensure_cache_identity()
    Nav.harvest()
    _rest_index = 0
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
