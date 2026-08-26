package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
Stub.install()

local UIManager = require("ui/uimanager")
local delayed = {}
function UIManager:scheduleIn(delay, fn)
    if type(delay) == "number" and delay >= 1 then
        delayed[#delayed + 1] = fn
        return
    end
    table.insert(self.queue, fn)
end

local Background = require("lib.background")
Background.reset()

function Background.run(task, done)
    UIManager:nextTick(function()
        local ok, value = pcall(task)
        if done then done(ok, value) end
    end)
end

local checks = 0
local function eq(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, ("FAIL %s: %s ~= %s"):format(message,
        tostring(actual), tostring(expected)))
end

local blockers = 0
local function block()
    blockers = blockers + 1
    return "block"
end
Background.submit({ key = "b1", priority = 100, task = block, done = function() end })
Background.submit({ key = "b2", priority = 100, task = block, done = function() end })
local order = {}
Background.submit({
    key = "low",
    priority = 1,
    task = function() return "low" end,
    done = function(ok, value)
        assert(ok)
        order[#order + 1] = value
    end,
})
Background.submit({
    key = "high",
    priority = 10,
    task = function() return "high" end,
    done = function(ok, value)
        assert(ok)
        order[#order + 1] = value
    end,
})
UIManager:run_next()
UIManager:run_next()
eq(blockers, 2, "slots filled by blockers")
eq(#order, 0, "queued work waits")
UIManager:drain()
eq(order[1], "high", "higher priority runs first after a slot frees")
eq(order[2], "low", "lower priority follows")

Background.reset()
delayed = {}
local first, second
Background.submit({
    key = "same",
    task = function() return "old" end,
    done = function(_, value) first = value end,
})
Background.submit({
    key = "same",
    task = function() return "new" end,
    done = function(_, value) second = value end,
})
UIManager:drain()
eq(first, nil, "replaced job does not call done")
eq(second, "new", "newer same-key job wins")

Background.reset()
delayed = {}
local kept, dropped
Background.submit({
    key = "keep",
    task = function() return "keep" end,
    done = function(_, value) kept = value end,
})
Background.submit({
    key = "drop",
    task = function() return "drop" end,
    done = function(_, value) dropped = value end,
})
Background.cancel_stale({ "keep" })
UIManager:drain()
eq(kept, "keep", "kept key still finishes")
eq(dropped, nil, "stale key is cancelled")

Background.reset()
delayed = {}
local timed
Background.submit({
    key = "slow",
    timeout = 5,
    task = function() return "too late" end,
    done = function(ok, value)
        timed = { ok = ok, value = value }
    end,
})
eq(#delayed, 1, "timeout scheduled")
delayed[1]()
UIManager:drain()
eq(timed.ok, false, "timeout fails")
eq(timed.value, "timeout", "timeout reason")

Background.reset()
print("background: " .. checks .. " ok")
