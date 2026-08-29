--[[--
Grimmory custom SVG icons, cached under hansel/icons.

Lucide names stay as names and are painted from ui/icon.lua. CUSTOM_SVG
icons are files Grimmory stores; GET /api/v1/icons/{name}/content returns
the markup. KOReader's ImageWidget can blit an .svg the same way the
drawer lockup does.
]]

local API = require("lib.api")
local Paths = require("lib.paths")
local logger = require("logger")

local Icons = {}

local function urlencode(s)
    return (tostring(s or ""):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function safe_name(name)
    name = tostring(name or ""):gsub("[^%w%.%-_]", "_")
    if name == "" or name == "." or name == ".." then return nil end
    return name
end

function Icons.dir()
    return Paths.icons_dir()
end

function Icons.path(name)
    local safe = safe_name(name)
    if not safe then return nil end
    return Icons.dir() .. "/" .. safe .. ".svg"
end

function Icons.cached(name)
    local path = Icons.path(name)
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    f:close()
    return path
end

local function looks_like_svg(body)
    if type(body) ~= "string" then return false end
    return body:find("<svg", 1, true) ~= nil and body:find("</svg>", 1, true) ~= nil
end

--- Fetch one custom SVG if it is not already on disk. Skip from paint paths.
function Icons.fetch(name)
    local cached = Icons.cached(name)
    if cached then return cached end
    if type(name) ~= "string" or name == "" then return nil end
    local ok, _, body = API.rest_get("/api/v1/icons/" .. urlencode(name) .. "/content", {
        timeout_block = 2,
        timeout_total = 3,
    })
    if not ok or not looks_like_svg(body) then return nil end
    Paths.ensure(Icons.dir())
    local path = Icons.path(name)
    if not path then return nil end
    local f, err = io.open(path, "wb")
    if not f then
        logger.dbg("[hansel] svg icon write failed", name, err)
        return nil
    end
    f:write(body)
    f:close()
    return path
end

return Icons
