local LuaSettings = require("luasettings")
local Paths = require("lib.paths")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local CacheMap = {}

local _file
local _root
local _data
local _identity

local function current_identity()
    local ok, Settings = pcall(require, "lib.settings")
    if ok and Settings and Settings.account_key then return Settings.account_key() end
    return "local\nanonymous"
end

local function empty_bucket()
    return { books = {}, open_path = nil }
end

local function file_stat(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, attr = pcall(lfs.attributes, path)
    if ok and type(attr) == "table" then return attr end
    local ok_mode, mode = pcall(lfs.attributes, path, "mode")
    if ok_mode and type(mode) == "string" then
        local ok_size, size = pcall(lfs.attributes, path, "size")
        return { mode = mode, size = (ok_size and tonumber(size)) or 0 }
    end
    return nil
end

local function is_file(path)
    local attr = file_stat(path)
    if attr then return attr.mode == "file" end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function file_size(path)
    local attr = file_stat(path)
    if attr and tonumber(attr.size) then return tonumber(attr.size) end
    return 0
end

local function recover_path(id)
    id = tostring(id)
    local dirs = { Paths.default_download_dir() }
    local ok, Settings = pcall(require, "lib.settings")
    if ok and Settings and Settings.download_dir then
        dirs[#dirs + 1] = Settings.download_dir()
    end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if type(home) == "string" and home ~= "" then
        home = home:gsub("/+$", "")
        dirs[#dirs + 1] = home .. "/dork"
        dirs[#dirs + 1] = home .. "/dork-cache"
        dirs[#dirs + 1] = home .. "/hansel"
        dirs[#dirs + 1] = home .. "/hansel-cache"
    end
    local exts = { "epub", "pdf", "cbz", "fb2", "mobi", "azw3" }
    for _, dir in ipairs(dirs) do
        for _, ext in ipairs(exts) do
            local path = dir .. "/" .. id .. "." .. ext
            if is_file(path) then return path end
        end
    end
    return nil
end

local function open()
    local migrated = false
    if not _file then
        Paths.ensure_data_dirs()
        _file = LuaSettings:open(Paths.cache_map_file())
        local stored = _file:readSetting("cache")
        if type(stored) == "table" and type(stored.accounts) == "table" then
            _root = stored
        else
            _root = { version = 2, accounts = {} }
            if type(stored) == "table" then
                stored.books = stored.books or {}
                _root.accounts[current_identity()] = stored
                migrated = true
            end
        end
        _root.version = 2
        _root.accounts = _root.accounts or {}

        -- Older builds also wrote rows under a separate `entries` key.
        if not _root.legacy_entries_migrated then
            local legacy = _file:readSetting("entries")
            if type(legacy) == "table" then
                local id = current_identity()
                local bucket = _root.accounts[id] or empty_bucket()
                bucket.books = bucket.books or {}
                for book_id, row in pairs(legacy) do
                    if type(row) == "table" then
                        local dest = bucket.books[tostring(book_id)] or {}
                        for key, value in pairs(row) do
                            if dest[key] == nil then dest[key] = value end
                        end
                        bucket.books[tostring(book_id)] = dest
                    end
                end
                _root.accounts[id] = bucket
                _file:saveSetting("entries", nil)
            end
            _root.legacy_entries_migrated = true
            migrated = true
        end
    end

    local identity = current_identity()
    if _identity ~= identity or not _data then
        _identity = identity
        _root.accounts[identity] = _root.accounts[identity] or empty_bucket()
        _data = _root.accounts[identity]
        _data.books = _data.books or {}
    end
    if migrated then
        _file:saveSetting("cache", _root)
        _file:flush()
    end
end

function CacheMap.load()
    open()
    return _data
end

function CacheMap.flush()
    open()
    _file:saveSetting("cache", _root)
    _file:flush()
end

local function entry(id)
    open()
    id = tostring(id)
    _data.books[id] = _data.books[id] or {}
    return _data.books[id]
end

function CacheMap.get(id)
    open()
    if not id then return nil end
    return _data.books[tostring(id)]
end

function CacheMap.local_path(id)
    local e = CacheMap.get(id)
    if e and e.path and is_file(e.path) then
        return e.path
    end
    if e and e.path and not is_file(e.path) then
        e.path = nil
        CacheMap.flush()
    end
    return nil
end

function CacheMap.state(id)
    if CacheMap.local_path(id) then
        local e = CacheMap.get(id)
        if e and e.pinned then return "pinned" end
        return "cached"
    end
    return "remote"
end

local HASH_CHUNK = 65536

local function hash_cache()
    open()
    _root.hash_cache = _root.hash_cache or {}
    return _root.hash_cache
end

local function file_identity(path)
    local attr = file_stat(path)
    if attr then
        return tonumber(attr.size), attr.modification or attr.change
    end
    return nil, nil
end

local function stream_hash(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local ok, sha2 = pcall(require, "ffi/sha2")
    local first_byte
    local size = 0
    local acc = 5381
    while true do
        local chunk = f:read(HASH_CHUNK)
        if not chunk or chunk == "" then break end
        if not first_byte then first_byte = chunk:byte(1) or 0 end
        size = size + #chunk
        for i = 1, #chunk do
            acc = (acc * 33 + chunk:byte(i)) % 2147483647
        end
    end
    f:close()
    if ok and sha2 and sha2.sha256 then
        return sha2.sha256(string.format("%s:%d:%d:%d", path, size, first_byte or 0, acc))
    end
    return string.format("%d:%d:%d", size, first_byte or 0, acc)
end

local function file_hash(path)
    if type(path) ~= "string" or path == "" then return nil end
    local size, mtime = file_identity(path)
    local cache = hash_cache()
    local row = cache[path]
    if row and row.hash and size ~= nil and mtime ~= nil
        and row.size == size and row.mtime == mtime then
        return row.hash
    end
    local hash = stream_hash(path)
    if hash and size ~= nil and mtime ~= nil then
        cache[path] = { size = size, mtime = mtime, hash = hash }
    end
    return hash
end

function CacheMap.file_hash(path)
    return file_hash(path)
end

function CacheMap.record_download(id, path, bytes, opts)
    opts = opts or {}
    local e = entry(id)
    e.path = path
    e.bytes = tonumber(bytes) or file_size(path)
    e.last_access = os.time()
    e.owned = opts.owned ~= false
    e.hash = opts.hash or file_hash(path)
    CacheMap.flush()
end

function CacheMap.record_seen(id, path)
    local e = entry(id)
    e.path = path
    e.bytes = file_size(path)
    e.hash = file_hash(path)
    e.owned = false
    e.last_access = os.time()
    CacheMap.flush()
end

function CacheMap.touch(id)
    local e = CacheMap.get(id)
    if not e then return end
    e.last_access = os.time()
    CacheMap.flush()
end

function CacheMap.set_pinned(id, pinned)
    local e = entry(id)
    e.pinned = pinned and true or false
    CacheMap.flush()
end

function CacheMap.is_pinned(id)
    local e = CacheMap.get(id)
    return e and e.pinned == true
end

function CacheMap.set_open_path(path)
    open()
    _data.open_path = path
    CacheMap.flush()
end

function CacheMap.open_path()
    open()
    return _data.open_path
end

function CacheMap.rebuild_by_hash()
    open()
    local wanted = {}
    for id, e in pairs(_data.books) do
        if e.hash and (not e.path or not is_file(e.path)) then
            wanted[e.hash] = id
        end
    end
    if not next(wanted) then return end
    local home = Paths.home_dir()
    if not home then return end
    for name in lfs.dir(home) do
        if name ~= "." and name ~= ".." and not name:match("%.sdr$") then
            local path = home .. "/" .. name
            if is_file(path) then
                local h = file_hash(path)
                local id = h and wanted[h]
                if id then
                    local e = entry(id)
                    e.path = path
                    e.owned = false
                    e.bytes = file_size(path)
                end
            end
        end
    end
    CacheMap.flush()
end

function CacheMap.remove(id, delete_file)
    local e = CacheMap.get(id)
    if not e then return true end
    local path = e.path
    if delete_file and path and e.owned then
        if path == _data.open_path then
            return false, "open"
        end
        pcall(os.remove, path)
    end
    e.path = nil
    e.bytes = nil
    e.pinned = false
    CacheMap.flush()
    return true
end

function CacheMap.usage_bytes()
    open()
    local total = 0
    for _, e in pairs(_data.books) do
        if e.path and is_file(e.path) then
            total = total + (tonumber(e.bytes) or file_size(e.path))
        end
    end
    return total
end

function CacheMap.owned_cached()
    open()
    local list = {}
    for id, e in pairs(_data.books) do
        if e.owned and e.path and not e.pinned and e.path ~= _data.open_path then
            if is_file(e.path) then
                list[#list + 1] = {
                    id = id,
                    path = e.path,
                    bytes = tonumber(e.bytes) or 0,
                    last_access = tonumber(e.last_access) or 0,
                }
            end
        end
    end
    table.sort(list, function(a, b) return a.last_access < b.last_access end)
    return list
end

function CacheMap.on_device_ids()
    open()
    local ids = {}
    for id, e in pairs(_data.books) do
        local path = (e.path and is_file(e.path)) and e.path or recover_path(id)
        if path then
            if e.path ~= path then
                e.path = path
                CacheMap.flush()
            end
            ids[#ids + 1] = id
        end
    end
    return ids
end

function CacheMap.local_books()
    local Catalog = require("lib.catalog")
    local books = {}
    local changed = false
    for _, id in ipairs(CacheMap.on_device_ids()) do
        local book = Catalog.get_book(id)
        if not book then
            local e = CacheMap.get(id)
            local path = e and e.path
            local name = path and path:match("([^/]+)$") or ("Book " .. id)
            book = {
                id = tostring(id),
                title = name:gsub("%.[%w]+$", ""),
                file_type = path and path:match("%.([%w]+)$") or "epub",
                file_size = e and e.bytes,
            }
            Catalog.upsert_book(book)
            changed = true
        end
        books[#books + 1] = book
    end
    if changed then Catalog.flush() end
    return books
end

function CacheMap.id_for_path(path, allow_hash)
    if type(path) ~= "string" or path == "" then return nil end
    open()
    for id, e in pairs(_data.books) do
        if e.path == path and is_file(path) then return id end
    end
    if allow_hash == false then return nil end
    local hash = file_hash(path)
    if not hash then return nil end
    for id, e in pairs(_data.books) do
        if e.hash == hash then
            e.path = path
            e.bytes = file_size(path)
            CacheMap.flush()
            return id
        end
    end
    return nil
end

function CacheMap.continue_ids(limit)
    open()
    limit = limit or 8
    local list = {}
    for id, e in pairs(_data.books) do
        if e.path and e.last_opened then
            list[#list + 1] = { id = id, last_opened = e.last_opened }
        end
    end
    table.sort(list, function(a, b) return a.last_opened > b.last_opened end)
    local ids = {}
    for i = 1, math.min(limit, #list) do
        ids[i] = list[i].id
    end
    return ids
end

function CacheMap.mark_opened(id, path)
    local e = entry(id)
    e.last_opened = os.time()
    e.last_access = os.time()
    if path and is_file(path) then
        e.path = path
        e.bytes = file_size(path)
        if e.hash == nil then e.hash = file_hash(path) end
        if e.owned == nil then e.owned = false end
    end
    CacheMap.flush()
end

function CacheMap.relocate_to(dir)
    open()
    if not dir then return end
    for _, e in pairs(_data.books) do
        if e.path then
            local name = e.path:match("([^/]+)$")
            if name then
                local dest = dir .. "/" .. name
                if dest ~= e.path and is_file(dest) then
                    e.path = dest
                end
            end
        end
    end
    CacheMap.flush()
end

function CacheMap.rebuild_from_disk(dir)
    -- Recover a corrupted map: files we own are named `{id}.{ext}`.
    open()
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then return end
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local id = name:match("^(%d+)%.%w+$")
            if id then
                local path = dir .. "/" .. name
                local e = entry(id)
                e.path = path
                e.bytes = file_size(path)
                e.owned = true
                e.last_access = e.last_access or os.time()
            end
        end
    end
    CacheMap.flush()
    logger.dbg("[hansel] rebuilt cache map from", dir)
end

function CacheMap.free_unpinned()
    local n = 0
    for _, item in ipairs(CacheMap.owned_cached()) do
        local ok = CacheMap.remove(item.id, true)
        if ok then n = n + 1 end
    end
    return n
end

function CacheMap.evict_for(needed)
    needed = tonumber(needed) or 0
    if needed <= 0 then return true end
    local freed = 0
    for _, item in ipairs(CacheMap.owned_cached()) do
        if freed >= needed then break end
        local bytes = tonumber(item.bytes) or 0
        if CacheMap.remove(item.id, true) then
            freed = freed + bytes
        end
    end
    return freed >= needed
end

return CacheMap
