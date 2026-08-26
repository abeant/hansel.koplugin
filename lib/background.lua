local UIManager = require("ui/uimanager")
local logger = require("logger")

local Background = {}

local MAX_INFLIGHT = 2
local DEFAULT_PRIORITY = 0

local seq = 0
local queued = {}
local inflight = {}
local by_key = {}

local function fallback(task, done)
    UIManager:nextTick(function()
        local ok, value = pcall(task)
        if done then done(ok, value) end
    end)
end

function Background.run(task, done)
    local ok_dev, Device = pcall(require, "device")
    if ok_dev and Device and Device.isAndroid and Device:isAndroid() then
        fallback(task, done)
        return
    end
    local ok_util, ffiutil = pcall(require, "ffi/util")
    if not ok_util or not ffiutil or not ffiutil.runInSubProcess
            or not ffiutil.writeToFD or not ffiutil.isSubProcessDone
            or not ffiutil.getNonBlockingReadSize or not ffiutil.readAllFromFD then
        fallback(task, done)
        return
    end

    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        local json = require("json")
        local ok, value = pcall(task)
        local encoded = json.encode({ ok = ok, value = ok and value or nil,
            error = ok and nil or tostring(value) })
        ffiutil.writeToFD(write_fd, encoded, true)
    end, true)
    if not pid then
        fallback(task, done)
        return
    end

    local interval = 0.125
    local function collect_later()
        if ffiutil.isSubProcessDone(pid) then return end
        UIManager:scheduleIn(1, collect_later)
    end
    local function poll()
        local finished = ffiutil.isSubProcessDone(pid)
        local available = read_fd and ffiutil.getNonBlockingReadSize(read_fd)
        local ready = available and available > 0
        if not finished and not ready then
            interval = math.min(1, interval * 1.25)
            UIManager:scheduleIn(interval, poll)
            return
        end
        local raw = read_fd and ffiutil.readAllFromFD(read_fd) or ""
        read_fd = nil
        if not finished then UIManager:scheduleIn(1, collect_later) end
        local ok_json, json = pcall(require, "json")
        local decoded
        if ok_json and json then
            local ok_decode, value = pcall(json.decode, raw or "")
            if ok_decode then decoded = value end
        end
        if not decoded then
            logger.warn("[hansel] background worker returned invalid data")
            if done then done(false, "invalid worker response") end
            return
        end
        if done then done(decoded.ok == true, decoded.ok and decoded.value or decoded.error) end
    end
    UIManager:scheduleIn(interval, poll)
end

local function inflight_count()
    local n = 0
    for _ in pairs(inflight) do n = n + 1 end
    return n
end

local function unschedule_timeout(job)
    if job.timeout_fn and UIManager.unschedule then
        UIManager:unschedule(job.timeout_fn)
    end
    job.timeout_fn = nil
end

local function finish(job, ok, value)
    if job.settled then return end
    job.settled = true
    unschedule_timeout(job)
    if by_key[job.key] == job then by_key[job.key] = nil end
    inflight[job.id] = nil
    if job.done and not job.suppress_done then
        job.done(ok, value)
    end
    Background.pump()
end

local function mark_stale(job, reason)
    if not job or job.settled then return end
    job.stale = true
    job.suppress_done = true
    unschedule_timeout(job)
    if job.running then return end
    finish(job, false, reason or "cancelled")
end

local function start(job)
    if job.settled or job.stale then return end
    job.running = true
    inflight[job.id] = job
    if job.timeout and job.timeout > 0 then
        job.timeout_fn = function()
            if job.settled then return end
            job.stale = true
            finish(job, false, "timeout")
        end
        UIManager:scheduleIn(job.timeout, job.timeout_fn)
    end
    Background.run(job.task, function(ok, value)
        finish(job, ok, value)
    end)
end

function Background.pump()
    table.sort(queued, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.id < b.id
    end)
    local remain = {}
    for _, job in ipairs(queued) do
        if not job.settled and not job.stale then
            if inflight_count() < MAX_INFLIGHT then
                start(job)
            else
                remain[#remain + 1] = job
            end
        end
    end
    queued = remain
end

function Background.submit(opts)
    opts = opts or {}
    seq = seq + 1
    local key = opts.key
    if key == nil or key == "" then key = "anon:" .. seq end
    local job = {
        id = seq,
        key = tostring(key),
        priority = tonumber(opts.priority) or DEFAULT_PRIORITY,
        timeout = tonumber(opts.timeout),
        task = opts.task,
        done = opts.done,
        stale = false,
        settled = false,
        running = false,
    }
    local prev = by_key[job.key]
    if prev then mark_stale(prev, "replaced") end
    by_key[job.key] = job
    queued[#queued + 1] = job
    Background.pump()
    return job.id
end

function Background.cancel(key_or_id)
    if key_or_id == nil then return end
    if type(key_or_id) == "number" then
        for _, job in ipairs(queued) do
            if job.id == key_or_id then mark_stale(job, "cancelled") end
        end
        local running = inflight[key_or_id]
        if running then mark_stale(running, "cancelled") end
        return
    end
    local job = by_key[tostring(key_or_id)]
    if job then mark_stale(job, "cancelled") end
end

function Background.cancel_stale(keep)
    local allowed = {}
    if type(keep) == "table" then
        if keep[1] ~= nil then
            for _, key in ipairs(keep) do allowed[tostring(key)] = true end
        else
            for key, yes in pairs(keep) do
                if yes then allowed[tostring(key)] = true end
            end
        end
    elseif keep ~= nil then
        allowed[tostring(keep)] = true
    end
    local seen = {}
    for _, job in ipairs(queued) do seen[job] = true end
    for _, job in pairs(inflight) do seen[job] = true end
    for job in pairs(seen) do
        if not allowed[job.key] then mark_stale(job, "stale") end
    end
end

function Background.reset()
    for _, job in ipairs(queued) do mark_stale(job, "reset") end
    for _, job in pairs(inflight) do mark_stale(job, "reset") end
    queued = {}
    inflight = {}
    by_key = {}
    seq = 0
end

return Background
