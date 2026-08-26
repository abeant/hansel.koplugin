local LuaSettings = require("luasettings")
local Paths = require("lib.paths")
local Settings = require("lib.settings")

local Queue = {}

local file
local data
local sequence = 0

local function open()
    if file then return end
    Paths.ensure_data_dirs()
    file = LuaSettings:open(Paths.sync_queue_file())
    data = file and file.readSetting and file:readSetting("queue") or nil
    if type(data) ~= "table" then data = { version = 1, accounts = {} } end
    data.version = 1
    if type(data.accounts) ~= "table" then data.accounts = {} end
end

local function account(account_key)
    open()
    account_key = account_key or Settings.account_key()
    data.accounts[account_key] = data.accounts[account_key] or { entries = {} }
    data.accounts[account_key].entries = data.accounts[account_key].entries or {}
    return data.accounts[account_key]
end

local function flush()
    if not file then return end
    file:saveSetting("queue", data)
    if file.flush then file:flush() end
end

function Queue.put(book_id, snapshot, account_key)
    if not book_id or type(snapshot) ~= "table" then return nil end
    local bucket = account(account_key)
    local key = tostring(book_id)
    local previous = bucket.entries[key]
    sequence = sequence + 1
    local copy = {}
    for field, value in pairs(snapshot) do copy[field] = value end
    copy.book_id = key
    copy.sequence = os.time() * 1000 + sequence
    copy.captured_at = copy.captured_at or os.time()
    if previous and previous.keep_device and copy.keep_device == nil then
        copy.keep_device = true
    end
    if previous and previous.blocked and not copy.keep_device then
        copy.blocked = true
        copy.remote = previous.remote
    else
        copy.blocked = false
    end
    bucket.entries[key] = copy
    flush()
    return copy
end

function Queue.get(book_id, account_key)
    return account(account_key).entries[tostring(book_id)]
end

function Queue.entries(account_key)
    local entries = {}
    for _, item in pairs(account(account_key).entries) do entries[#entries + 1] = item end
    table.sort(entries, function(a, b)
        return (tonumber(a.captured_at) or 0) < (tonumber(b.captured_at) or 0)
    end)
    return entries
end

function Queue.remove(book_id, expected_sequence, account_key)
    local bucket = account(account_key)
    local item = bucket.entries[tostring(book_id)]
    if not item then return false end
    if expected_sequence and item.sequence ~= expected_sequence then return false end
    bucket.entries[tostring(book_id)] = nil
    flush()
    return true
end

function Queue.mark_blocked(book_id, remote, account_key)
    local item = Queue.get(book_id, account_key)
    if not item then return false end
    item.blocked = true
    item.remote = remote
    item.keep_device = nil
    flush()
    return true
end

function Queue.unblock(book_id, account_key)
    local item = Queue.get(book_id, account_key)
    if not item then return false end
    item.blocked = false
    item.remote = nil
    flush()
    return true
end

function Queue.clear(account_key)
    local bucket = account(account_key)
    bucket.entries = {}
    flush()
end

function Queue.count(account_key)
    local count = 0
    for _ in pairs(account(account_key).entries) do count = count + 1 end
    return count
end

function Queue.pending_count(account_key)
    local count = 0
    for _, item in pairs(account(account_key).entries) do
        if type(item) == "table" and not item.blocked then count = count + 1 end
    end
    return count
end

return Queue
