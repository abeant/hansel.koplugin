local Device = require("device")
local Font = require("ui/font")
local logger = require("logger")

local Type = {}

local function plugin_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    return src:match("^(.*)/ui/type%.lua$")
end

local ROOT = plugin_dir()

local FILES = {
    mono = "NectoMono-Regular.otf",
    text = "OrticaLinear-Regular.otf",
    light = "OrticaLinear-Light.otf",
}

local SLOT = {
    title = "tfont",
    body = "smallinfofont",
    small = "smallinfofont",
        tiny = "smallinfofont",
}

local function file_for(kind)
    if not ROOT then return nil end
    return ROOT .. "/fonts/" .. FILES[kind]
end

local function slot_name(role)
    if role == nil or role == "body" then return SLOT.body end
    return SLOT[role] or role
end

--- Same orig size KOReader uses for `infofont` / `tfont` / etc.
--- Font:getFace scales that by the user's DPI. We do not invent sizes.
local function menu_size()
    local settings = rawget(_G, "G_reader_settings")
    if settings and settings.readSetting then
        local set = settings:readSetting("items_font_size")
        if set then return set end
        local perpage = settings:readSetting("items_per_page") or 14
        return math.floor(24 - ((perpage - 6) * (1 / 18)) * 10)
    end
    return 19
end

local function face(kind, role)
    local slot = slot_name(role)
    if slot == "smallinfofont" and (role == nil or role == "body" or role == "small") then
        return Font:getFace(slot, menu_size())
    end
    return Font:getFace(slot)
end

function Type.mono(role)
    return face("mono", role)
end

function Type.text(role)
    return face("text", role)
end

function Type.light(role)
    return face("light", role)
end

Type.display = Type.text
Type.display_light = Type.light

return Type
