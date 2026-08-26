-- One-release rename of on-disk dork.* plugin data to hansel.*.
-- Existing installs keep working: files, Start with, and gesture action names.

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Migrate = {}

local FILES = {
    { "dork_settings.lua", "hansel_settings.lua" },
    { "dork_catalog.lua", "hansel_catalog.lua" },
    { "dork_cache_map.lua", "hansel_cache_map.lua" },
    { "dork_sync_queue.lua", "hansel_sync_queue.lua" },
}

local function mode_of(path)
    local ok, attr = pcall(lfs.attributes, path, "mode")
    if ok and attr then
        return attr
    end
    return nil
end

local function rename_if_needed(old, new)
    if not old or old == new then
        return
    end
    if mode_of(new) then
        return
    end
    if not mode_of(old) then
        return
    end
    os.rename(old, new)
end

function Migrate.data_files()
    local ok, dir = pcall(function()
        return DataStorage:getSettingsDir()
    end)
    if not ok or type(dir) ~= "string" or dir == "" then
        return
    end
    for i = 1, #FILES do
        local pair = FILES[i]
        rename_if_needed(dir .. "/" .. pair[1], dir .. "/" .. pair[2])
        rename_if_needed(dir .. "/" .. pair[1] .. ".old", dir .. "/" .. pair[2] .. ".old")
    end
    rename_if_needed(dir .. "/dork", dir .. "/hansel")
end

function Migrate.start_with()
    if not G_reader_settings or not G_reader_settings.readSetting then
        return
    end
    if G_reader_settings:readSetting("start_with") ~= "dork" then
        return
    end
    G_reader_settings:saveSetting("start_with", "hansel")
    if G_reader_settings.flush then
        G_reader_settings:flush()
    end
end

function Migrate.all()
    Migrate.data_files()
    Migrate.start_with()
end

return Migrate
