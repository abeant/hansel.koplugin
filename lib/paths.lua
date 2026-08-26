local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Paths = {}

local function mkdir_p(path)
    if not path or path == "" then return false end
    if lfs.attributes(path, "mode") == "directory" then return true end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= path then
        mkdir_p(parent)
    end
    return lfs.mkdir(path) == true or lfs.attributes(path, "mode") == "directory"
end

function Paths.plugin_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    local dir = src:match("^(.*)/lib/paths%.lua$")
    return dir
end

function Paths.data_dir()
    return DataStorage:getSettingsDir() .. "/hansel"
end

function Paths.covers_dir()
    return Paths.data_dir() .. "/covers"
end

function Paths.cover_path(book_id, scope)
    local dir = Paths.covers_dir()
    local id = tostring(book_id):gsub("[^%w_.-]", "_")
    if type(scope) == "string" and scope ~= "" then
        scope = scope:gsub("[^%w_-]", "_")
        id = scope .. "-" .. id
    end
    for _, ext in ipairs({ ".jpg", ".jpeg", ".png", ".gif", ".img" }) do
        local path = dir .. "/" .. id .. ext
        if lfs.attributes(path, "mode") == "file" then
            return path
        end
    end
    return dir .. "/" .. id .. ".jpg"
end

function Paths.settings_file()
    return DataStorage:getSettingsDir() .. "/hansel_settings.lua"
end

function Paths.catalog_file()
    return DataStorage:getSettingsDir() .. "/hansel_catalog.lua"
end

function Paths.cache_map_file()
    return DataStorage:getSettingsDir() .. "/hansel_cache_map.lua"
end

function Paths.sync_queue_file()
    return DataStorage:getSettingsDir() .. "/hansel_sync_queue.lua"
end

function Paths.home_dir()
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if type(home) == "string" and home ~= "" then
        return home:gsub("/+$", "")
    end
    return DataStorage:getDataDir()
end

--- Downloads land in KOReader Home, same as any other book.
function Paths.default_download_dir()
    return Paths.home_dir()
end

function Paths.legacy_download_dirs()
    local dirs = {
        Paths.data_dir() .. "/books",
        DataStorage:getDataDir() .. "/dork/books",
        DataStorage:getDataDir() .. "/hansel/books",
    }
    local home = Paths.home_dir()
    dirs[#dirs + 1] = home .. "/dork"
    dirs[#dirs + 1] = home .. "/dork-cache"
    dirs[#dirs + 1] = home .. "/hansel"
    dirs[#dirs + 1] = home .. "/hansel-cache"
    return dirs
end

function Paths.sanitize_filename(name)
    name = tostring(name or "")
    name = name:gsub("[/\\:*?\"<>|]", "")
    name = name:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    if #name > 80 then name = name:sub(1, 80) end
    return name
end

function Paths.library_filename(book, ext)
    ext = tostring(ext or "epub"):gsub("^%.", ""):lower()
    if ext == "" then ext = "epub" end
    local raw = book and (book.filename or book.file_name)
    if type(raw) == "string" and raw ~= "" then
        raw = raw:match("([^/\\]+)$") or raw
        local stem = raw:gsub("%.[%w]+$", "")
        local from_name = Paths.sanitize_filename(stem)
        if from_name then return from_name .. "." .. ext end
    end
    local base = Paths.sanitize_filename(book and book.title)
        or ("book-" .. tostring(book and book.id or "file"))
    return base .. "." .. ext
end

local function is_dir(path)
    local ok, attr = pcall(lfs.attributes, path)
    if ok and type(attr) == "table" then return attr.mode == "directory" end
    local ok2, mode = pcall(lfs.attributes, path, "mode")
    return ok2 and mode == "directory"
end

local function move_tree(src, dest)
    if not src or src == dest then return end
    os.rename(src, dest)
    if is_dir(dest) or (lfs.attributes(dest) ~= nil) then return true end
    local inf = io.open(src, "rb")
    if not inf then return false end
    local data = inf:read("*a")
    inf:close()
    local out = io.open(dest, "wb")
    if not out then return false end
    out:write(data or "")
    out:close()
    pcall(os.remove, src)
    return true
end

--- Move leftover plugin-cache files into KOReader Home, named by title.
function Paths.migrate_into_library()
    local dest_dir = Paths.home_dir()
    local Catalog = require("lib.catalog")
    local moved = {}
    for _, src_dir in ipairs(Paths.legacy_download_dirs()) do
        if src_dir ~= dest_dir and is_dir(src_dir) then
            for name in lfs.dir(src_dir) do
                if name ~= "." and name ~= ".." and not name:match("%.sdr$") then
                    local id, ext = name:match("^(%d+)%.(%w+)$")
                    local book = id and Catalog.get_book(id)
                    local dest_name = (book and Paths.library_filename(book, ext or "epub")) or name
                    local from = src_dir .. "/" .. name
                    local to = dest_dir .. "/" .. dest_name
                    if to ~= from then
                        move_tree(from, to)
                        local sdr_from = from:gsub("%.[^%.]+$", "") .. ".sdr"
                        local sdr_to = to:gsub("%.[^%.]+$", "") .. ".sdr"
                        if is_dir(sdr_from) then move_tree(sdr_from, sdr_to) end
                        if id then moved[id] = to end
                    end
                end
            end
            local leftover
            for name in lfs.dir(src_dir) do
                if name ~= "." and name ~= ".." then leftover = true break end
            end
            if not leftover then pcall(lfs.rmdir, src_dir) end
        end
    end
    return dest_dir, moved
end

function Paths.ensure_data_dirs()
    pcall(function()
        require("lib.migrate").all()
    end)
    mkdir_p(Paths.data_dir())
    mkdir_p(Paths.covers_dir())
end

function Paths.ensure(dir)
    return mkdir_p(dir)
end

Paths.mkdir_p = mkdir_p

return Paths
