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

-- The walk upserts hundreds of books per page. Hold the catalog flush while
-- it runs and write every FLUSH_EVERY pages (and on every exit) instead of
-- rewriting the whole table once per page.
local FLUSH_EVERY = 5
local _release

local function release_catalog()
    if _release then
        local fn = _release
        _release = nil
        fn()
    end
end

function Manifest.busy()
    return _busy
end

function Manifest.cancel()
    _gen = _gen + 1
    _busy = false
    release_catalog()
end

-- Link-level, same signal as the rest of the plugin (never the DNS probe).
local function online()
    local ok, Session = pcall(require, "lib.session")
    if not ok or not Session or not Session.network_available then return true end
    return Session.network_available()
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

    local function stop()
        _busy = false
        release_catalog()
    end

    local function step()
        if not account_unchanged() then
            if gen == _gen then stop() end
            return
        end
        local Library = require("lib.library")
        if not origin then
            stop()
            return
        end
        if not _release and Catalog.hold_flush then
            _release = Catalog.hold_flush()
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
                if gen == _gen then stop() end
                return
            end
            if not ok_worker or not result or result.unavailable then
                stop()
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
                stop()
                logger.dbg("[hansel] manifest done", Catalog.book_count(), total)
                return
            end
            if page % FLUSH_EVERY == 0 then Catalog.flush() end
            page = page + 1
            UIManager:scheduleIn(GAP, step)
        end)
    end

    UIManager:scheduleIn(GAP, step)
end

return Manifest
