local CacheMap = require("lib.cache_map")
local Catalog = require("lib.catalog")

local Books = {}
local _status = {}

local function sidecar_mtime(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return 0 end
    local attr = lfs.attributes(path)
    if attr and attr.modification then return attr.modification end
    local dir = path:match("^(.*)%.[^.]+$")
    if dir then
        attr = lfs.attributes(dir .. ".sdr")
        if attr and attr.modification then return attr.modification end
    end
    return 0
end

function Books.invalidate_status(path)
    if path then _status[path] = nil end
end

--- Reading state, from whatever the device actually knows.
--- Grimmory's own status is Tier 2 only, so this reads KOReader's sidecar for
--- books we have downloaded and falls back to "have we ever opened it".
function Books.read_status(book)
    if not book or not book.id then return "unread" end
    local path = book.local_path or CacheMap.local_path(book.id)
    if path then
        local mtime = sidecar_mtime(path)
        local hit = _status[path]
        if hit and hit.mtime == mtime then return hit.status end
        local ok, status = pcall(function()
            local DocSettings = require("docsettings")
            if not DocSettings:hasSidecarFile(path) then return nil end
            local ds = DocSettings:open(path)
            local summary = ds:readSetting("summary")
            if type(summary) == "table" and summary.status == "complete" then
                return "finished"
            end
            local pct = tonumber(ds:readSetting("percent_finished")) or 0
            if pct > 0 then return "reading" end
            return nil
        end)
        if ok and status then
            _status[path] = { mtime = mtime, status = status }
            return status
        end
    end
    local entry = CacheMap.get(book.id)
    if entry and entry.last_opened then return "reading" end
    local remote = tostring(book.read_status or ""):lower()
    if remote == "read" or remote == "finished" or remote == "complete" then return "finished" end
    if remote == "reading" then return "reading" end
    return "unread"
end

function Books.author_line(book)
    if not book then return "" end
    local a = book.authors
    if type(a) == "table" then
        return table.concat(a, ", ")
    end
    return tostring(a or "")
end

function Books.hydrate(book, opts)
    if not book or not book.id then return book end
    book.id = tostring(book.id)
    local cached = Catalog.get_book(book.id)
    if cached then
        for k, v in pairs(cached) do
            if book[k] == nil then book[k] = v end
        end
    end
    -- Snapshot/filter path: trust the cache map. Stat the disk only for the
    -- visible page - 700 lfs.attributes calls is the 5–10s boot hang.
    if opts and opts.disk == false then
        if not book.state then
            local e = CacheMap.get(book.id)
            if e and e.path then
                book.local_path = e.path
                book.state = e.pinned and "pinned" or "cached"
            else
                book.state = "remote"
            end
        end
        return book
    end
    local path = CacheMap.local_path(book.id)
    book.local_path = path
    book.state = CacheMap.state(book.id)
    return book
end

function Books.hydrate_list(list, opts)
    local out = {}
    for i = 1, #(list or {}) do
        out[i] = Books.hydrate(list[i], opts)
    end
    return out
end

return Books
