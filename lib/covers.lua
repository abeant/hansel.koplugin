local Http = require("lib.http")
local Origin = require("lib.origin")
local Paths = require("lib.paths")
local Settings = require("lib.settings")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

local Covers = {}

local _queue = {}
local _token = 0
local _busy = false
local _on_done = nil
local _hits = {}

function Covers.scope()
    local identity = Settings.account_key()
    local ok, sha2 = pcall(require, "ffi/sha2")
    local digest = ok and sha2 and sha2.md5 and sha2.md5(identity)
    if type(digest) == "string" and digest ~= "" then
        digest = digest:gsub("[^%w]", "")
        if digest ~= "" then return digest:sub(1, 16) end
    end
    -- Deterministic fallback for unusual builds without ffi/sha2.
    local hash = 5381
    for index = 1, #identity do
        hash = (hash * 33 + identity:byte(index)) % 2147483647
    end
    return string.format("%08x", hash)
end

function Covers.path(book_id)
    return Paths.cover_path(book_id, Covers.scope())
end

function Covers.cached(book_id)
    local id = tostring(book_id or "")
    if _hits[id] then return _hits[id] end
    local path = Covers.path(book_id)
    if lfs.attributes(path, "mode") == "file" then
        _hits[id] = path
        return path
    end
    -- Adopt a pre-v0.2 unscoped cover into the account active during upgrade.
    local legacy = Paths.cover_path(book_id)
    if lfs.attributes(legacy, "mode") == "file" then
        local ext = legacy:match("(%.[^./]+)$") or ".jpg"
        local target = path:gsub("%.[^./]+$", ext)
        if os.rename(legacy, target) then return target end
    end
    return nil
end

local function creds()
    local origin = Settings.server_url()
    return {
        user = Settings.get("t1_username"),
        password = Settings.t1_password(),
        url = origin,
    }
end

local function usage_bytes()
    local dir = Paths.covers_dir()
    local total = 0
    if lfs.attributes(dir, "mode") ~= "directory" then return 0 end
    local files = {}
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local p = dir .. "/" .. name
            local a = lfs.attributes(p)
            if a and a.mode == "file" then
                files[#files + 1] = { path = p, size = a.size or 0, access = a.access or 0 }
                total = total + (a.size or 0)
            end
        end
    end
    return total, files
end

local function evict_covers(needed)
    local budget = Settings.cover_budget()
    local total, files = usage_bytes()
    if total + needed <= budget then return end
    table.sort(files, function(a, b) return a.access < b.access end)
    for _, f in ipairs(files) do
        if total + needed <= budget then break end
        pcall(os.remove, f.path)
        total = total - f.size
    end
end

function Covers.fetch_one(book, cred)
    if not book or not book.id then return nil end
    local existing = Covers.cached(book.id)
    if existing then return existing end
    local url = book.cover_url or Origin.opds_cover(Settings.server_url(), book.id)
    if not url then return nil end
    cred = cred or creds()
    if cred.url and not Origin.same_origin(cred.url, url) then
        cred = { user = nil, password = nil }
    end
    Paths.ensure(Paths.covers_dir())
    local dest = Covers.path(book.id)
    evict_covers(200 * 1024)
    local request_opts = {
        user = cred.user,
        password = cred.password,
        timeout_block = 5,
        timeout_total = 10,
    }
    local ok
    if Settings.has_tier2() and Origin.same_origin(Settings.server_url(), url) then
        local Session = require("lib.session")
        local bearer = Session.peek_token and Session.peek_token()
        if not bearer then return nil end
        request_opts.user, request_opts.password = nil, nil
        request_opts.headers = { Authorization = "Bearer " .. bearer }
        ok = Http.download_file(url, dest, request_opts)
    else
        ok = Http.download_file(url, dest, request_opts)
    end
    if ok then
        _hits[tostring(book.id)] = dest
        return dest
    end
    pcall(os.remove, dest)
    pcall(os.remove, dest .. ".part")
    return nil
end

local function can_fetch_covers()
    if not Settings.has_tier2() then return true end
    local ok, Session = pcall(require, "lib.session")
    if not ok or not Session then return false end
    if Session.peek_token and Session.peek_token() then return true end
    if Session.should_probe and Session.should_probe() then return true end
    return false
end

local function pump(on_done)
    if _busy then return end
    _busy = true
    local token = _token
    local function step()
        if token ~= _token then
            _busy = false
            return
        end
        if not can_fetch_covers() then
            _busy = false
            return
        end
        local book = table.remove(_queue, 1)
        while book and Covers.cached(book.id) do
            book = table.remove(_queue, 1)
        end
        if book then
            local path = Covers.fetch_one(book)
            if path and on_done then
                on_done(book.id, path)
            end
            if token == _token and #_queue > 0 then
                UIManager:scheduleIn(0.05, step)
                return
            end
        end
        _busy = false
    end
    UIManager:scheduleIn(0.05, step)
end

local function enqueue(books)
    for _, book in ipairs(books or {}) do
        if book and book.id and not Covers.cached(book.id) and (book.cover_url or Settings.server_url()) then
            _queue[#_queue + 1] = book
        end
    end
end

function Covers.fetch_visible(books, on_done)
    _token = _token + 1
    _queue = {}
    _on_done = on_done
    enqueue(books)
    _busy = false
    pump(_on_done)
end

function Covers.prefetch_next(books, token)
    if not Settings.get("prefetch_next_page_covers") then return end
    if token ~= nil and token ~= _token then return end
    enqueue(books)
    pump(_on_done)
end

function Covers.cancel()
    _token = _token + 1
    _queue = {}
    _busy = false
    _on_done = nil
end

function Covers.usage_bytes()
    local total = usage_bytes()
    return total
end

return Covers
