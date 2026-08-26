local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Origin = require("lib.origin")

local Import = {}

function Import.list()
    local path = DataStorage:getSettingsDir() .. "/opds.lua"
    local ok, settings = pcall(LuaSettings.open, LuaSettings, path)
    if not ok or not settings then return {} end
    local servers = settings:readSetting("servers") or {}
    local out = {}
    for _, s in ipairs(servers) do
        if type(s) == "table" and type(s.url) == "string" then
            out[#out + 1] = {
                title = s.title or s.url,
                url = s.url,
                username = s.username,
                password = s.password,
                looks_grimmory = Import.looks_grimmory(s.url),
            }
        end
    end
    return out
end

function Import.looks_grimmory(url)
    if type(url) ~= "string" then return false end
    url = url:lower()
    return url:find("/api/v1/opds", 1, true) ~= nil
        or url:find("grimmory", 1, true) ~= nil
        or url:find(":6060", 1, true) ~= nil
end

function Import.origin_of(url)
    return Origin.from_any(url)
end

return Import
