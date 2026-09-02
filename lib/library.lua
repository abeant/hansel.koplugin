local API = require("lib.api")
local Books = require("lib.books")
local CacheMap = require("lib.cache_map")
local Catalog = require("lib.catalog")
local Http = require("lib.http")
local OPDS = require("lib.opds")
local Origin = require("lib.origin")
local Paths = require("lib.paths")
local Settings = require("lib.settings")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local Library = {}
local cached_failure
local snap

local function session()
    local ok, Session = pcall(require, "lib.session")
    return ok and Session or nil
end

local function error_kind(status)
    local Session = session()
    if Session and Session.classify then return Session.classify(status) end
    status = tonumber(status) or 0
    if status == 0 then return "offline" end
    if status == 401 then return "auth_required" end
    if status == 403 then return "forbidden" end
    if status >= 500 then return "server_error" end
    return "invalid_response"
end

-- OPDS Basic-auth requests bypass Session. Without a Grimmory login they are
-- the only health signal there is, so feed their outcome back.
local function note_transport(ok, status)
    if Settings.has_tier2() then return end
    local Session = session()
    if Session and Session.note then Session.note(ok, status) end
end

local function t1_creds()
    return Settings.get("t1_username"), Settings.t1_password()
end

function Library.fetch_page(view, page, size)
    view = view or "all"
    page = tonumber(page) or 1
    size = tonumber(size) or Settings.page_size()
    local origin = Settings.server_url()
    if not origin then
        return Catalog.get_page(view, page, size)
    end
    if Settings.has_tier2() then
        return Library.fetch_feed(origin .. "/api/v1/books/page", page, size, {
            cache_key = view,
            force = true,
        })
    end
    local url = Origin.opds_catalog(origin, page, size)
    local user, password = t1_creds()
    local ok, code, body = Http.get(url, {
        user = user,
        password = password,
        timeout_block = 4,
        timeout_total = 8,
    })
    note_transport(ok, code)
    if not ok then
        logger.warn("[hansel] catalog fetch failed", code)
        return cached_failure(view, page, size, {
            error_kind = error_kind(code), status = code,
        })
    end
    local parsed = OPDS.parse(body, url)
    Catalog.put_page(view, page, size, parsed.books, parsed.total)
    snap = nil
    local books = Books.hydrate_list(parsed.books)
    return {
        books = books,
        total = parsed.total or #books,
        page = page,
        size = size,
        offline = false,
        unavailable = false,
        source = "network",
    }
end

local function rest_book(raw)
    if type(raw) ~= "table" then return nil end
    local md = raw.metadata or {}
    local id = raw.id or md.bookId
    if not id then return nil end
    local authors = md.authors or raw.authors
    if type(authors) == "table" and authors[1] and type(authors[1]) == "table" then
        local names = {}
        for _, a in ipairs(authors) do
            names[#names + 1] = a.name or a.title or tostring(a)
        end
        authors = names
    end
    local origin = Settings.server_url()
    local primary = raw.primaryFile or {}
    local ext = raw.primaryFileType or primary.extension or primary.fileType or primary.bookType
    if type(ext) == "string" then ext = ext:lower() end
    local file_size = raw.primaryFileSize or primary.fileSize
    if not file_size and primary.fileSizeKb then
        file_size = tonumber(primary.fileSizeKb) and tonumber(primary.fileSizeKb) * 1024
    end
    return {
        id = tostring(id),
        title = md.title or raw.title or ("Book " .. id),
        authors = authors,
        tags = md.tags or raw.tags,
        categories = md.categories or raw.categories,
        genres = md.genres or raw.genres,
        moods = md.moods or raw.moods,
        shelves = raw.shelves or md.shelves,
        library_id = raw.libraryId and tostring(raw.libraryId) or nil,
        library_name = raw.libraryName,
        file_path = primary.filePath or raw.filePath,
        series = md.seriesName or md.series,
        series_index = md.seriesNumber or md.seriesIndex or raw.seriesIndex,
        added_on = raw.addedOn or md.addedOn,
        published_date = md.publishedDate or raw.publishedDate,
        file_type = ext,
        filename = raw.primaryFileName or primary.fileName,
        primary_file_id = raw.primaryFileId or primary.id,
        read_status = raw.readStatus or md.readStatus,
        rating = raw.personalRating or md.personalRating,
        description = md.description or raw.description,
        file_size = file_size,
        cover_url = origin and (origin .. "/api/v1/media/book/" .. id .. "/thumbnail") or nil,
        download_url = origin and (origin .. "/api/v1/opds/" .. id .. "/download") or nil,
    }
end

cached_failure = function(cache_key, page, size, response)
    local cached = Catalog.get_page(cache_key, page, size)
    if cached then
        cached.error_kind = response and response.error_kind or "offline"
        cached.status = response and response.status or 0
        cached.unavailable = true
        cached.offline = cached.error_kind == "offline"
        cached.source = "cache"
        cached.stale = true
        return cached
    end
    return {
        books = {}, total = 0, page = page, size = size,
        offline = not response or response.error_kind == "offline",
        unavailable = true,
        error_kind = response and response.error_kind or "offline",
        status = response and response.status or 0,
        source = "none",
    }
end

local function feed_cache_key(url)
    local key = tostring(url or "")
    key = key:gsub("([?&])page=%d+", "%1"):gsub("([?&])size=%d+", "%1")
    key = key:gsub("[?&]+$", ""):gsub("%?&", "?"):gsub("&&+", "&")
    return key
end

local function urldecode(s)
    s = tostring(s or ""):gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local FACET_ALIASES = {
    genres = "genre",
    category = "genre",
    categories = "genre",
    tags = "tag",
    authors = "author",
    shelves = "shelf",
    libraries = "library",
}

local FACET_FIELDS = {
    genre = { "categories", "genres" },
    tag = { "tags" },
    series = { "series" },
    author = { "authors" },
    shelf = { "shelves" },
    library = { "library_id", "library_name" },
}

--- Grimmory facet URLs: /api/v1/books/page?facet=genre:Horror
function Library.parse_facet(url)
    if type(url) ~= "string" or url == "" then return nil end
    local raw = url:match("[?&]facet=([^&]*)")
    if not raw or raw == "" then return nil end
    raw = urldecode(raw)
    local key, value = raw:match("^([^:]+):(.*)$")
    if not key or value == nil or value == "" then return nil end
    key = string.lower(key)
    key = FACET_ALIASES[key] or key
    return { key = key, value = value }
end

local function field_values(book, field)
    local v = book and book[field]
    if v == nil then return {} end
    if type(v) == "string" then
        return v ~= "" and { v } or {}
    end
    if type(v) ~= "table" then
        return { tostring(v) }
    end
    local out = {}
    local function push(name)
        if name ~= nil and tostring(name) ~= "" then
            out[#out + 1] = tostring(name)
        end
    end
    if v[1] ~= nil then
        for i = 1, #v do
            local row = v[i]
            if type(row) == "table" then
                push(row.name or row.title)
                push(row.id or row.value)
            else
                push(row)
            end
        end
    else
        for k, row in pairs(v) do
            if type(row) == "table" then
                push(row.name or row.title)
                push(row.id or row.value)
            else
                if type(k) == "string" then push(k) end
                push(row)
            end
        end
    end
    return out
end

local function book_matches_facet(book, facet)
    if not book or not facet then return false end
    if facet.key == "unshelved" then
        local values = field_values(book, "shelves")
        return #values == 0
    end
    local fields = FACET_FIELDS[facet.key]
    if not fields then return false end
    local want = string.lower(facet.value)
    for i = 1, #fields do
        local values = field_values(book, fields[i])
        for j = 1, #values do
            if string.lower(values[j]) == want then
                return true
            end
        end
    end
    return false
end

local function filter_facet(books, facet)
    local out = {}
    for i = 1, #(books or {}) do
        if book_matches_facet(books[i], facet) then
            out[#out + 1] = books[i]
        end
    end
    return out
end

local function can_probe()
    local Session = session()
    if Session and Session.should_probe then
        return Session.should_probe()
    end
    return true
end

local function slice_list(list, page, size)
    local total = #(list or {})
    if size < 1 then size = 1 end
    local last_page = math.max(1, math.ceil(math.max(total, 1) / size))
    if page > last_page then page = last_page end
    if page < 1 then page = 1 end
    local first = (page - 1) * size + 1
    local last = math.min(total, first + size - 1)
    local books = {}
    if first <= last then
        for i = first, last do
            books[#books + 1] = list[i]
        end
    end
    return books, total, page
end

function Library.fetch_feed(url, page, size, opts)
    opts = opts or {}
    page = tonumber(page) or 1
    size = tonumber(size) or Settings.page_size()
    local cache_key = opts.cache_key or feed_cache_key(url)
    if type(url) ~= "string" or url == "" then
        return cached_failure(cache_key, page, size)
    end
    -- Unshelved is a Grimmory sidebar pin, not a books/page facet (400).
    local unshelved = Library.parse_facet(url)
    if unshelved and unshelved.key == "unshelved" then
        return Library.page(cache_key, page, size)
    end
    if not opts.bearer_token and not opts.force then
        local ok_s, Session = pcall(require, "lib.session")
        if ok_s and Session and Session.should_probe and not Session.should_probe() then
            return Library.page(cache_key, page, size)
        end
    end
    if url:find("/books/page", 1, true) or url:find("facet=", 1, true) then
        local rest = url
        rest = rest:gsub("[?&]page=%d+", ""):gsub("[?&]size=%d+", "")
        local join = rest:find("?", 1, true) and "&" or "?"
        rest = rest .. join .. "page=" .. math.max(0, page - 1) .. "&size=" .. size
        local path = rest:match("https?://[^/]+(/.*)$") or rest
        local ok, status, body, _, response
        if opts.bearer_token then
            ok, status, body = Http.get(rest, {
                headers = { Authorization = "Bearer " .. opts.bearer_token },
                timeout_block = 4,
                timeout_total = 8,
            })
            response = {
                ok = ok and true or false,
                status = tonumber(status) or 0,
                body = body,
                error_kind = ok and nil or error_kind(status),
            }
        else
            ok, _, body, _, response = API.rest_get(path)
        end
        if not ok then
            logger.warn("[hansel] rest feed failed", response and response.error_kind or "unknown",
                response and response.status or 0)
            return cached_failure(cache_key, page, size, response)
        end
        local payload = body
        if type(body) == "string" then
            local ok_j, json = pcall(require, "json")
            if ok_j and json and json.decode then
                local s, r = pcall(json.decode, body)
                if s then payload = r end
            end
        end
        local books = {}
        if type(payload) == "table" then
            for _, raw in ipairs(payload.content or {}) do
                local book = rest_book(raw)
                if book then books[#books + 1] = book end
            end
        else
            return cached_failure(cache_key, page, size, {
                error_kind = "invalid_response", status = 200,
            })
        end
        local total = payload and payload.page and payload.page.totalElements
        if not opts.no_cache then
            Catalog.put_page(cache_key, page, size, books, total)
            snap = nil
        end
        local shown = opts.no_cache and books or Books.hydrate_list(books)
        return {
            books = shown,
            total = total or #books,
            page = page,
            size = size,
            offline = false,
            unavailable = false,
            source = "network",
        }
    end
    local genre = url:match("[?&]q=([^&]+)")
    if genre then
        genre = genre:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        genre = genre:gsub("%+", " ")
    end
    if not url:find("page=") then
        local join = url:find("?", 1, true) and "&" or "?"
        url = url .. join .. "page=" .. page .. "&size=" .. size
    end
    local user, password = t1_creds()
    local ok, code, body = Http.get(url, {
        user = user,
        password = password,
        timeout_block = 4,
        timeout_total = 8,
    })
    note_transport(ok, code)
    if not ok then
        logger.warn("[hansel] feed fetch failed", code)
        return cached_failure(cache_key, page, size, {
            error_kind = error_kind(code),
            status = code,
        })
    end
    local parsed = OPDS.parse(body, url)
    local books = opts.no_cache and parsed.books or Books.hydrate_list(parsed.books)
    if #books == 0 and genre then
        books = Books.hydrate_list(Catalog.books_in_genre(genre))
    end
    if not opts.no_cache then
        Catalog.put_page(cache_key, page, size, books, parsed.total)
        snap = nil
    end
    return {
        books = books,
        total = parsed.total or #books,
        page = page,
        size = size,
        offline = false,
        unavailable = false,
        source = "network",
        title = parsed.title,
    }
end

local function library_unreachable()
    local Session = session()
    if Session and Session.status then
        local kind = Session.status().kind
        if kind == "offline" or kind == "server_error" then
            return true, kind
        end
    end
    return false
end

function Library.is_unreachable()
    return library_unreachable()
end

function Library.feed_key(url)
    return feed_cache_key(url)
end

function Library.page(view, page, size)
    page = tonumber(page) or 1
    size = tonumber(size) or Settings.page_size()
    local cached = Catalog.get_page(view, page, size)
    -- Never HTTP here. Unavailable only if we already know Grimmory is down —
    -- skipping a probe is not the same as the server being unreachable.
    local down, kind = library_unreachable()
    local offline = (down and kind == "offline") and true or false
    if cached then
        cached.books = Books.hydrate_list(cached.books, { disk = false })
        cached.unavailable = down
        cached.offline = offline
        cached.error_kind = down and kind or nil
        cached.status = 0
        cached.source = "cache"
        return cached
    end
    -- Facet feeds (category/tag/series/author/shelf) page over the catalog we
    -- already have. A missing *page cache* is not an empty shelf.
    local facet = Library.parse_facet(view)
    if facet then
        local all = Books.hydrate_list(Catalog.all_books() or {}, { disk = false })
        local matched = filter_facet(all, facet)
        if #matched > 0 or facet.key == "unshelved" then
            local books, total, clamped = slice_list(matched, page, size)
            return {
                books = books,
                total = total,
                page = clamped,
                size = size,
                offline = offline,
                unavailable = down,
                error_kind = down and kind or nil,
                source = "cache",
            }
        end
    end
    local inherited = Catalog.view_total and Catalog.view_total(view) or nil
    return {
        books = {},
        total = inherited or 0,
        page = page,
        size = size,
        offline = offline,
        unavailable = down,
        error_kind = down and kind or nil,
        source = "none",
    }
end

local function merge_books(...)
    local out, seen = {}, {}
    for index = 1, select("#", ...) do
        for _, book in ipairs(select(index, ...) or {}) do
            if book and book.id then
                local id = tostring(book.id)
                if not seen[id] then
                    seen[id] = book
                    out[#out + 1] = book
                else
                    for key, value in pairs(book) do
                        if value ~= nil then seen[id][key] = value end
                    end
                end
            end
        end
    end
    return out
end

local function catalog_revision()
    if Catalog.revision then return Catalog.revision() end
    local man = Catalog.manifest and Catalog.manifest()
    return (Catalog.book_count and Catalog.book_count() or 0)
        .. ":" .. tostring(man and man.fetched_at or 0)
end

local function cache_revision()
    if CacheMap.revision then return CacheMap.revision() end
    return #(CacheMap.local_books() or {})
end

local function derived_counts(known)
    local counts = { known = #known, downloaded = 0, pinned = 0, remote = 0 }
    for _, book in ipairs(known) do
        if book.state == "pinned" then
            counts.pinned = counts.pinned + 1
            counts.downloaded = counts.downloaded + 1
        elseif book.state == "cached" then
            counts.downloaded = counts.downloaded + 1
        else
            counts.remote = counts.remote + 1
        end
    end
    return counts
end

local function unified_snapshot(base_books)
    local crev, krev = catalog_revision(), cache_revision()
    if snap and snap.crev == crev and snap.krev == krev then
        return snap
    end
    local local_books = CacheMap.local_books()
    local known = Books.hydrate_list(
        merge_books(Catalog.all_books(), base_books, local_books), { disk = false })
    snap = {
        crev = crev,
        krev = krev,
        known = known,
        local_books = Books.hydrate_list(local_books, { disk = false }),
        counts = derived_counts(known),
    }
    return snap
end

function Library.query(state, page, size, force_network)
    local Filter = require("ui.filter")
    state = state or Filter.state()
    page = tonumber(page) or 1
    size = tonumber(size) or Settings.page_size()
    local feed_url = state.feed_url
    local facet = feed_url and Library.parse_facet(feed_url) or nil
    local local_facet = facet and facet.key == "unshelved"

    local base
    if force_network and not local_facet then
        if feed_url then
            base = Library.fetch_feed(feed_url, page, size)
        else
            base = Library.fetch_page("all", page, size)
        end
    end
    if not base then
        base = Library.page("all", page, size)
    end
    base = base or cached_failure(feed_url and Library.feed_key(feed_url) or "all", page, size)

    local unified = unified_snapshot(base.books)
    local effective, hid = Filter.effective(state, base.unavailable)
    local source
    if effective.device == "downloaded" or effective.device == "pinned" then
        source = unified.local_books
    else
        source = unified.known
    end

    if facet then
        local matched = filter_facet(source, facet)
        if #matched > 0 or local_facet then
            source = matched
        else
            -- Magic shelves / id facets often aren't on the catalog record.
            -- Fall back to the paged feed cache rather than a fake empty shelf.
            facet = nil
        end
    end

    if feed_url and not facet then
        local key = Library.feed_key(feed_url)
        local rec
        if force_network then
            rec = base
        else
            rec = Catalog.get_page(key, page, size)
            if rec then
                rec.books = Books.hydrate_list(rec.books, { disk = false })
            end
        end
        local empty = not rec or #(rec.books or {}) == 0
        if empty and (force_network or can_probe()) then
            rec = Library.fetch_feed(feed_url, page, size) or rec
        end
        if not rec then
            rec = Library.page(key, page, size)
        end
        rec = rec or {
            books = {},
            total = Catalog.view_total and Catalog.view_total(key) or 0,
            page = page,
            size = size,
            source = "none",
            unavailable = base.unavailable,
            offline = base.offline,
            error_kind = base.error_kind,
        }
        local page_books = Filter.apply(rec.books or {}, effective)
        local total = tonumber(rec.total) or 0
        local inherited = Catalog.view_total and Catalog.view_total(key)
        if total == 0 and inherited then
            total = inherited
        elseif inherited and inherited > total then
            total = inherited
        end
        if total == 0 then
            total = #page_books
        end
        logger.dbg("[hansel] library feed page", key, page, size, #page_books, total)
        return {
            books = page_books,
            total = total,
            known_total = total,
            counts = unified.counts,
            page = page,
            size = size,
            offline = rec.offline and true or false,
            unavailable = rec.unavailable and true or false,
            error_kind = rec.error_kind or base.error_kind,
            status = rec.status or base.status,
            source = rec.source or "none",
            stale = rec.stale and true or false,
            fetched_at = rec.fetched_at,
            hide_unavailable_active = hid or (rec.unavailable and Settings.hide_unavailable()) or false,
        }
    end

    local filtered = Filter.apply(source, effective)
    local books, known_total
    books, known_total, page = slice_list(filtered, page, size)
    books = Books.hydrate_list(books)

    local total = known_total
    if not feed_url and not Filter.active(state) and not base.unavailable
            and base.source and base.source ~= "none"
            and tonumber(base.total) and base.total > total then
        total = base.total
    end
    logger.dbg("[hansel] library snapshot", base.source or "unknown",
        base.error_kind or "ok", unified.counts.known, known_total, page, size)
    return {
        books = books,
        total = total,
        known_total = known_total,
        counts = unified.counts,
        page = page,
        size = size,
        offline = base.offline and true or false,
        unavailable = base.unavailable and true or false,
        error_kind = base.error_kind,
        status = base.status,
        source = base.source or (base.offline and "cache" or "network"),
        stale = base.stale and true or false,
        fetched_at = base.fetched_at,
        hide_unavailable_active = hid or (base.unavailable and Settings.hide_unavailable()) or false,
    }
end

function Library.book(id)
    return Books.hydrate(Catalog.get_book(id))
end

function Library.download(book)
    if not book or not book.id then
        return false, "missing book"
    end
    local existing = CacheMap.local_path(book.id)
    if existing then
        CacheMap.touch(book.id)
        return true, existing
    end
    local origin = Settings.server_url()
    local url = book.download_url or Origin.opds_download(origin, book.id)
    if Settings.has_tier2() and origin then
        url = origin .. "/api/v1/books/" .. tostring(book.id) .. "/download"
    end
    if not url then
        return false, "no download URL"
    end
    local dir = Settings.download_dir()
    Paths.ensure(dir)
    local ext = book.file_type or "epub"
    ext = tostring(ext):gsub("^%.", ""):lower()
    if ext == "" then ext = "epub" end
    local dest = dir .. "/" .. Paths.library_filename(book, ext)
    local staged = dir .. "/.hansel-" .. tostring(book.id)
    local opts = {}
    if Settings.has_tier2() then
        local Session = require("lib.session")
        local ok, code, path_or_err, headers = Session.with_bearer(function(token)
            opts.headers = { Authorization = "Bearer " .. token }
            return Http.download_file(url, staged, opts)
        end)
        if not ok then
            pcall(os.remove, staged)
            pcall(os.remove, staged .. ".part")
            return false, path_or_err or ("HTTP " .. tostring(code))
        end
        opts._downloaded = { code = code, path = path_or_err, headers = headers }
    else
        local user, password = t1_creds()
        if origin and not Origin.same_origin(origin, url) then
            user, password = nil, nil
        end
        opts.user, opts.password = user, password
    end
    local ok, code, path_or_err, headers
    if opts._downloaded then
        ok, code, path_or_err, headers = true, opts._downloaded.code,
            opts._downloaded.path, opts._downloaded.headers
    else
        ok, code, path_or_err, headers = Http.download_file(url, staged, opts)
    end
    if not ok then
        pcall(os.remove, staged)
        pcall(os.remove, staged .. ".part")
        return false, path_or_err or ("HTTP " .. tostring(code))
    end
    local cd = headers and (headers["content-disposition"] or headers["Content-Disposition"])
    if type(cd) == "string" then
        local fn = cd:match('filename="([^"]+)"') or cd:match("filename=([^;]+)")
        if fn then book.filename = fn:gsub("^%s+", ""):gsub("%s+$", "") end
        dest = dir .. "/" .. Paths.library_filename(book, ext)
    end
    local new_hash = CacheMap.file_hash(staged)
    local function exists(p)
        return lfs.attributes(p) ~= nil
    end
    if exists(dest) then
        if new_hash and CacheMap.file_hash(dest) == new_hash then
            pcall(os.remove, staged)
            CacheMap.record_seen(book.id, dest)
            Catalog.upsert_book({ id = book.id, local_path = dest, file_type = ext })
            snap = nil
            return true, dest
        end
        dest = dir .. "/" .. (Paths.sanitize_filename(book.title) or "book")
            .. " (" .. tostring(book.id) .. ")." .. ext
    end
    os.remove(dest)
    if not os.rename(staged, dest) then
        pcall(os.remove, staged)
        return false, "rename failed"
    end
    local info = lfs.attributes(dest)
    local bytes = (type(info) == "table" and tonumber(info.size)) or tonumber(info) or 0
    if bytes == 0 then
        pcall(os.remove, dest)
        return false, "empty download"
    end
    CacheMap.record_download(book.id, dest, bytes, { owned = true, hash = new_hash })
    Catalog.upsert_book({ id = book.id, local_path = dest, file_type = ext, file_size = bytes })
    snap = nil
    return true, dest
end

return Library
