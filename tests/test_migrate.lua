package.path = "./?.lua;./tests/?.lua;" .. package.path

local Stub = require("kostub")
local env = Stub.install()

local checks = 0
local function eq(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, ("FAIL %s: %s ~= %s"):format(message,
        tostring(actual), tostring(expected)))
end

env.reader_settings.start_with = "dork"
local Migrate = require("lib.migrate")
Migrate.start_with()
eq(env.reader_settings.start_with, "hansel", "start_with dork migrates to hansel")

local Paths = require("lib.paths")
local path = Paths.settings_file()
env.settings_files[path] = {
    dork = {
        server_url = "http://grimmory.test:6060",
        t2_username = "legacy-user",
        last_view = "all",
    },
}

package.loaded["lib.settings"] = nil
local Settings = require("lib.settings")
Settings.load()
eq(Settings.get("t2_username"), "legacy-user", "reads inner dork settings key")
eq(Settings.get("server_url"), "http://grimmory.test:6060", "legacy server url survives")

Settings.set("last_view", "dashboard")
local store = env.settings_files[path]
eq(store.hansel ~= nil, true, "flush writes hansel key")
eq(store.hansel.last_view, "dashboard", "new writes land in hansel key")
eq(store.dork, nil, "legacy dork key is cleared after flush")

print("migrate: " .. checks .. " ok")
