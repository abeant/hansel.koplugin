local LuaSettings = require("luasettings")
local Paths = require("lib.paths")
local logger = require("logger")

local Catalog = {}

local _file
local _root
local _data
local _identity
local _dirty

local function current_identity()
    local ok, Settings = pcall(require, "lib.settings")
    if ok and Settings and Settings.account_key then
        return Settings.account_key()
    end
    return "local\nanonymous"
end

local function empty_bucket()
    return { pages = {}, by_id = {}, manifest = {} }
end

local function migrate_pages(bucket)
    local additions = {}
    local changed = false
    for key, rec in pairs(bucket.pages or {}) do
        local view = tostring((type(rec) == "table" and rec.view) or key)
        if view:find("/api/v1/books/page", 1, true)
                and not view:find("facet=", 1, true) then
            local page = tonumber(rec.page) or 1
            local size = tonumber(rec.size) or 12
            additions[string.format("all:%d:%d", page, size)] = rec
            rec.view = "all"
            changed = true
        end
    end
    for key, rec in pairs(additions) do
        if bucket.pages[key] == nil then
            bucket.pages[key] = rec
            changed = true
        end
    end
    return changed
end

local function open()
    local migrated = false
    if not _file then
        Paths.ensure_data_dirs()
        _file = LuaSettings:open(Paths.catalog_file())
        local stored = _file:readSetting("catalog")
        if type(stored) == "table" and type(stored.accounts) == "table" then
            _root = stored
        else
            _root = { version = 2, accounts = {} }
            if type(stored) == "table" then
                local id = current_identity()
                stored.pages = stored.pages or {}
                stored.by_id = stored.by_id or {}
                stored.manifest = stored.manifest or {}
                migrate_pages(stored)
                _root.accounts[id] = stored
                migrated = true
            end
        end
        _root.version = 2
        _root.accounts = _root.accounts or {}
    end

    local id = current_identity()
    if _identity ~= id or not _data then
        _identity = id
        _root.accounts[id] = _root.accounts[id] or empty_bucket()
        _data = _root.accounts[id]
        _data.pages = _data.pages or {}
        _data.by_id = _data.by_id or {}
        _data.manifest = _data.manifest or {}
        migrated = migrate_pages(_data) or migrated
    end
    if migrated then
        _dirty = true
        Catalog.flush()
    end
end

function Catalog.load()
    open()
    return _data
end

function Catalog.flush()
    open()
    if not _dirty then return end
    _file:saveSetting("catalog", _root)
    _file:flush()
    _dirty = false
end

local function mark_dirty()
    _dirty = true
end

local function page_key(view, page, size)
    return string.format("%s:%d:%d", view or "all", tonumber(page) or 1, tonumber(size) or 12)
end

function Catalog.put_page(view, page, size, books, total)
    open()
    local key = page_key(view, page, size)
    local ids = {}
    for _, book in ipairs(books or {}) do
        if book.id then
            ids[#ids + 1] = tostring(book.id)
            Catalog.upsert_book(book)
        end
    end
    _data.pages[key] = {
        ids = ids,
        total = tonumber(total),
        fetched_at = os.time(),
        view = view,
        page = tonumber(page) or 1,
        size = tonumber(size) or 12,
    }
    logger.dbg("[hansel] catalog page store", view or "all", page, size, #ids)
    mark_dirty()
    Catalog.flush()
end

local function books_for(rec)
    local books = {}
    for _, id in ipairs((rec and rec.ids) or {}) do
        local book = _data.by_id[tostring(id)]
        if book then books[#books + 1] = book end
    end
    return books
end

function Catalog.get_page(view, page, size)
    open()
    page = tonumber(page) or 1
    size = tonumber(size) or 12
    local rec = _data.pages[page_key(view, page, size)]
    local source = rec and "exact" or nil
    if not rec then
        for _, candidate in pairs(_data.pages) do
            if candidate.view == view and tonumber(candidate.page) == page
                    and (not rec or (tonumber(candidate.fetched_at) or 0)
                        > (tonumber(rec.fetched_at) or 0)) then
                rec = candidate
                source = "logical-page"
            end
        end
    end
    if not rec and view == "all" and page == 1 and next(_data.by_id) then
        logger.dbg("[hansel] catalog page hit", view, page, size, "manifest")
        return {
            books = Catalog.all_books(),
            total = tonumber(_data.manifest.total) or Catalog.book_count(),
            fetched_at = _data.manifest.fetched_at,
            page = 1,
            size = size,
            offline = true,
            source = "cache",
            stale = true,
        }
    end
    if not rec then
        logger.dbg("[hansel] catalog page miss", view, page, size)
        return nil
    end
    logger.dbg("[hansel] catalog page hit", view, page, size, source)
    return {
        books = books_for(rec),
        total = rec.total,
        fetched_at = rec.fetched_at,
        page = rec.page,
        size = rec.size,
        offline = true,
        source = "cache",
        stale = true,
    }
end

function Catalog.upsert_book(book)
    open()
    if not book or not book.id then return end
    local id = tostring(book.id)
    local prev = _data.by_id[id] or {}
    local merged = {}
    for key, value in pairs(prev) do merged[key] = value end
    for key, value in pairs(book) do
        if value ~= nil then merged[key] = value end
    end
    merged.id = id
    _data.by_id[id] = merged
    mark_dirty()
end

function Catalog.get_book(id)
    open()
    if not id then return nil end
    return _data.by_id[tostring(id)]
end

function Catalog.book_count()
    open()
    local count = 0
    for _ in pairs(_data.by_id) do count = count + 1 end
    return count
end

function Catalog.all_books()
    open()
    local books = {}
    for _, book in pairs(_data.by_id) do books[#books + 1] = book end
    return books
end

function Catalog.manifest()
    open()
    return _data.manifest
end

function Catalog.set_manifest(total, fetched)
    open()
    _data.manifest.total = tonumber(total) or _data.manifest.total
    _data.manifest.count = Catalog.book_count()
    _data.manifest.fetched_at = fetched or os.time()
    mark_dirty()
    Catalog.flush()
end

function Catalog.put_books(books)
    open()
    for _, book in ipairs(books or {}) do Catalog.upsert_book(book) end
end

function Catalog.all_ids()
    open()
    local ids = {}
    for id in pairs(_data.by_id) do ids[#ids + 1] = id end
    return ids
end

function Catalog.recent_ids(limit)
    open()
    limit = limit or 12
    local rec = _data.pages["all:1:" .. tostring(limit)]
    if not rec then
        for _, candidate in pairs(_data.pages) do
            if candidate.view == "all" and tonumber(candidate.page) == 1
                    and (not rec or (tonumber(candidate.fetched_at) or 0)
                        > (tonumber(rec.fetched_at) or 0)) then
                rec = candidate
            end
        end
    end
    if rec then return rec.ids or {} end
    return {}
end

local function count_field(field)
    open()
    local counts = {}
    for _, book in pairs(_data.by_id) do
        local values = book[field]
        if type(values) == "string" then values = { values } end
        for _, name in ipairs(values or {}) do
            if type(name) == "string" and name ~= "" then
                counts[name] = (counts[name] or 0) + 1
            end
        end
    end
    return counts
end

function Catalog.genre_counts() return count_field("genres") end
function Catalog.category_counts() return count_field("categories") end
function Catalog.tag_counts() return count_field("tags") end

function Catalog.books_in_genre(name)
    open()
    local out = {}
    local want = string.lower(tostring(name or ""))
    for _, book in pairs(_data.by_id) do
        for _, cat in ipairs(book.categories or book.tags or {}) do
            if string.lower(tostring(cat)) == want then
                out[#out + 1] = book
                break
            end
        end
    end
    return out
end

function Catalog.clear()
    open()
    _root.accounts[_identity] = empty_bucket()
    _data = _root.accounts[_identity]
    mark_dirty()
    Catalog.flush()
    logger.dbg("[hansel] catalog cleared")
end

return Catalog
