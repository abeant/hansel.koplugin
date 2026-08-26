local Catalog = require("lib.catalog")
local Background = require("lib.background")
local Origin = require("lib.origin")
local Settings = require("lib.settings")
local logger = require("logger")

local Manifest = {}

local PAGE = 100
local FRESH = 20 * 60
local GAP = 0.25

local _gen = 0
local _busy = false

function Manifest.busy()
    return _busy
end

function Manifest.cancel()
    _gen = _gen + 1
    _busy = false
end

local function online()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr and NetworkMgr.isOnline and NetworkMgr:isOnline()
end

function Manifest.fresh()
    local meta = Catalog.manifest()
    local at = tonumber(meta.fetched_at) or 0
    local total = tonumber(meta.total) or 0
    local count = Catalog.book_count()
    if total < 1 then return false end
    if count < total then return false end
    return (os.time() - at) < FRESH
end

function Manifest.ensure()
    if _busy then return end
    if not Settings.can_browse() then return end
    if not online() then return end
    local bearer_token
    if Settings.has_tier2() then
        bearer_token = require("lib.session").peek_token()
        if not bearer_token then return end
    end
    if Manifest.fresh() then return end
    _busy = true
    _gen = _gen + 1
    local gen = _gen
    local identity = Settings.account_key()
    local origin = Settings.server_url()
    local tier2 = Settings.has_tier2()
    local page = 1
    local UIManager = require("ui/uimanager")

    local function account_unchanged()
        return gen == _gen and Settings.account_key() == identity
    end

    local function step()
        if not account_unchanged() then
            if gen == _gen then _busy = false end
            return
        end
        local Library = require("lib.library")
        if not origin then
            _busy = false
            return
        end
        local feed_url = tier2
            and (origin .. "/api/v1/books/page")
            or Origin.opds_catalog(origin, page, PAGE)
        Background.run(function()
            return Library.fetch_feed(feed_url, page, PAGE, {
                cache_key = "manifest",
                no_cache = true,
                bearer_token = bearer_token,
            })
        end, function(ok_worker, result)
            if not account_unchanged() then
                if gen == _gen then _busy = false end
                return
            end
            if not ok_worker or not result or result.unavailable then
                _busy = false
                logger.dbg("[hansel] manifest stop", page)
                return
            end
            local total = tonumber(result.total) or 0
            for _, book in ipairs(result.books or {}) do
                Catalog.upsert_book(book)
            end
            Catalog.set_manifest(total, os.time())
            if total > 0 then Settings.set_library_total(total) end
            local got = result.books and #result.books or 0
            if got < PAGE or (page * PAGE) >= total then
                _busy = false
                logger.dbg("[hansel] manifest done", Catalog.book_count(), total)
                return
            end
            page = page + 1
            UIManager:scheduleIn(GAP, step)
        end)
    end

    UIManager:scheduleIn(GAP, step)
end

return Manifest
