-- Grimmory URL helpers. Pure: no KOReader requires.

local Origin = {}

function Origin.normalize(url)
    if type(url) ~= "string" then return nil end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return nil end
    local scheme = url:match("^(%a[%w+.-]*)://")
    if not scheme then
        url = "http://" .. url
    else
        url = scheme:lower() .. url:sub(#scheme + 1)
    end
    return url:gsub("/+$", "")
end

function Origin.from_any(url)
    url = Origin.normalize(url)
    if not url then return nil end
    local scheme, authority = url:match("^(https?)://([^/%?#]+)")
    if not scheme or not authority or authority:find("@", 1, true) then return nil end

    local host, port, rendered_host
    if authority:sub(1, 1) == "[" then
        host, port = authority:match("^%[([^%]]+)%]:?(%d*)$")
        if not host then return nil end
        rendered_host = "[" .. host:lower() .. "]"
    else
        host, port = authority:match("^([^:]+):(%d+)$")
        if not host then
            if authority:find(":", 1, true) then return nil end
            host, port = authority, ""
        end
        rendered_host = host:lower()
    end
    if rendered_host == "" then return nil end

    if port ~= "" then
        port = tostring(tonumber(port))
        if not port then return nil end
    end
    if (scheme == "http" and port == "80") or (scheme == "https" and port == "443") then
        port = ""
    end
    return scheme .. "://" .. rendered_host .. (port ~= "" and (":" .. port) or "")
end

function Origin.opds_root(origin)
    origin = Origin.from_any(origin)
    if not origin then return nil end
    return origin .. "/api/v1/opds"
end

function Origin.opds_catalog(origin, page, size)
    origin = Origin.from_any(origin)
    if not origin then return nil end
    page = tonumber(page) or 1
    size = tonumber(size) or 50
    if size > 100 then size = 100 end
    if size < 1 then size = 1 end
    if page < 1 then page = 1 end
    return string.format("%s/api/v1/opds/catalog?page=%d&size=%d", origin, page, size)
end

function Origin.opds_cover(origin, book_id)
    origin = Origin.from_any(origin)
    if not origin or not book_id then return nil end
    return origin .. "/api/v1/opds/" .. tostring(book_id) .. "/cover"
end

function Origin.opds_nav(origin, kind)
    origin = Origin.from_any(origin)
    if not origin or not kind then return nil end
    return origin .. "/api/v1/opds/" .. kind
end

function Origin.opds_download(origin, book_id)
    origin = Origin.from_any(origin)
    if not origin or not book_id then return nil end
    return origin .. "/api/v1/opds/" .. tostring(book_id) .. "/download"
end

function Origin.koreader_sync(origin)
    origin = Origin.from_any(origin)
    if not origin then return nil end
    return origin .. "/api/koreader"
end

function Origin.login(origin)
    origin = Origin.from_any(origin)
    if not origin then return nil end
    return origin .. "/api/v1/auth/login"
end

function Origin.version(origin)
    origin = Origin.from_any(origin)
    if not origin then return nil end
    return origin .. "/api/v1/version"
end

local DEFAULT_PORT = { http = "80", https = "443" }

function Origin.origin_of(url)
    local canonical = Origin.from_any(url)
    if not canonical then return nil end
    local scheme, authority = canonical:match("^(https?)://(.+)$")
    local host, port
    if authority:sub(1, 1) == "[" then
        host, port = authority:match("^%[([^%]]+)%]:?(%d*)$")
    else
        host, port = authority:match("^([^:]+):(%d+)$")
        if not host then host, port = authority, "" end
    end
    if not host then return nil end
    return scheme, host, port ~= "" and port or DEFAULT_PORT[scheme]
end

function Origin.same_origin(url_a, url_b)
    local sa, ha, pa = Origin.origin_of(url_a)
    local sb, hb, pb = Origin.origin_of(url_b)
    if not sa or not sb then return false end
    return sa == sb and ha == hb and pa == pb
end

function Origin.same_host(url_a, url_b)
    local _, ha = Origin.origin_of(url_a)
    local _, hb = Origin.origin_of(url_b)
    if not ha or not hb then return false end
    return ha == hb
end

function Origin.absolute(base, href)
    if type(href) ~= "string" or href == "" then return nil end
    if href:match("^%a[%w+.-]*:") then return href end
    local scheme = base and base:match("^(%a[%w+.-]*):")
    if not scheme then return href end
    if href:sub(1, 2) == "//" then return scheme .. ":" .. href end
    local root = base:match("^(%a[%w+.-]*://[^/]+)")
    if href:sub(1, 1) == "/" then
        return (root or "") .. href
    end
    local dir = base:match("^(.*/)")
    if root and (not dir or #dir <= #root) then
        dir = root .. "/"
    end
    return (dir or (base .. "/")) .. href
end

function Origin.host_matches_kosync(origin, custom_server)
    origin = Origin.from_any(origin)
    custom_server = Origin.from_any(custom_server)
    if not origin or not custom_server then return false end
    return Origin.same_origin(origin, custom_server)
end

return Origin
