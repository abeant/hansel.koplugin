-- Grimmory OPDS 1.x (Atom) parser. Identity is the Grimmory book id taken
-- from /api/v1/opds/{id}/download or /cover — never filename or title.

local Origin = require("lib.origin")

local OPDS = {}

local TYPE_EXT = {
    ["application/epub+zip"] = "epub",
    ["application/epub"] = "epub",
    ["application/pdf"] = "pdf",
    ["application/x-mobipocket-ebook"] = "mobi",
    ["application/vnd.amazon.ebook"] = "azw3",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/x-cbz"] = "cbz",
    ["application/vnd.comicbook-rar"] = "cbr",
    ["application/fb2"] = "fb2",
    ["application/x-fictionbook+xml"] = "fb2",
    ["application/zip"] = "zip",
}
OPDS.TYPE_EXT = TYPE_EXT

local function unescape(s)
    if type(s) ~= "string" then return s end
    s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'")
    s = s:gsub("&#(%d+);", function(n)
        n = tonumber(n)
        if n and n >= 32 and n < 128 then return string.char(n) end
        return ""
    end)
    s = s:gsub("&amp;", "&")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function strip_tags(s)
    if type(s) ~= "string" then return s end
    s = s:gsub("<[^>]+>", " ")
    return unescape(s)
end

local function attr(tag, name)
    local v = tag:match(name .. '="([^"]*)"')
        or tag:match(name .. "='([^']*)'")
    return v
end

function OPDS.extract_book_id(href, atom_id)
    if type(href) == "string" then
        local id = href:match("/opds/(%d+)/download")
            or href:match("/opds/(%d+)/cover")
            or href:match("/books/(%d+)/download")
            or href:match("/media/book/(%d+)/")
        if id then return id end
    end
    if type(atom_id) == "string" then
        local id = atom_id:match("/opds/(%d+)") or atom_id:match(":(%d+)$") or atom_id:match("(%d+)$")
        if id then return id end
    end
    return nil
end

local function parse_entry_xml(entry_xml, feed_url)
    local title = unescape(entry_xml:match("<title[^>]*>(.-)</title>") or "")
    local atom_id = unescape(entry_xml:match("<id[^>]*>(.-)</id>") or "")
    local authors = {}
    for author_xml in entry_xml:gmatch("<author[^>]*>(.-)</author>") do
        local name = unescape(author_xml:match("<name[^>]*>(.-)</name>") or "")
        if name ~= "" then authors[#authors + 1] = name end
    end
    local summary = entry_xml:match("<summary[^>]*>(.-)</summary>")
        or entry_xml:match("<content[^>]*>(.-)</content>")
    summary = strip_tags(summary or "")
    local series = unescape(entry_xml:match("<[^>]*belongs%-to%-collection[^>]*>(.-)<") or "")
    if series == "" then
        series = unescape(entry_xml:match('scheme="[^"]*series[^"]*"[^>]*label="([^"]+)"') or "")
    end
    local series_index = entry_xml:match('group%-position[^>]*>([^<]+)')
        or entry_xml:match('series_index[^>]*>([^<]+)')
    local published = unescape(entry_xml:match("<dc:issued[^>]*>(.-)</dc:issued>")
        or entry_xml:match("<published[^>]*>(.-)</published>")
        or "")
    local updated = unescape(entry_xml:match("<updated[^>]*>(.-)</updated>") or "")
    local categories, tags, genres = {}, {}, {}
    for cat in entry_xml:gmatch("<category([^>]*)/?>") do
        local term = attr(cat, "label") or attr(cat, "term")
        if term then
            term = unescape(term)
            local scheme = string.lower(attr(cat, "scheme") or "")
            if scheme:find("tag", 1, true) or scheme:find("keyword", 1, true) then
                tags[#tags + 1] = term
            elseif scheme:find("genre", 1, true) then
                genres[#genres + 1] = term
            else
                categories[#categories + 1] = term
            end
        end
    end

    local cover_url, download_url, file_type, file_size, filename
    local function consider_link(tag)
        local rel = attr(tag, "rel") or ""
        local href = attr(tag, "href")
        local typ = attr(tag, "type") or ""
        if not href then return end
        href = Origin.absolute(feed_url, href)
        if rel:find("image/thumbnail", 1, true) or rel:find("/thumbnail", 1, true)
                or rel == "x-stanza-cover-image-thumbnail" then
            cover_url = cover_url or href
        elseif rel:find("opds-spec.org/image", 1, true) or rel:find("opds-spec.org/cover", 1, true)
                or rel == "x-stanza-cover-image" then
            cover_url = href
        elseif rel:find("opds-spec.org/acquisition", 1, true) or rel == "download" or rel == "enclosure" then
            if not rel:find("/sample") and not rel:find("/preview") and not rel:find("/borrow") then
                download_url = href
                file_type = TYPE_EXT[typ] or typ:match("/([%w+]+)$")
                if file_type then file_type = file_type:gsub("%+zip", ""):gsub("%+.*", "") end
                local len = attr(tag, "length") or attr(tag, "sz")
                file_size = tonumber(len)
                local link_title = attr(tag, "title")
                if link_title and link_title:find("%.", 1, true) then
                    filename = link_title:match("([^/\\]+)$")
                end
            end
        end
    end
    for tag in entry_xml:gmatch("<link([^>]+)/?>") do
        consider_link(tag)
    end

    local id = OPDS.extract_book_id(download_url, atom_id)
        or OPDS.extract_book_id(cover_url, atom_id)
    if not id then return nil end

    if not file_type and download_url then
        file_type = download_url:match("%.([%w]+)$")
    end

    return {
        id = tostring(id),
        title = title ~= "" and title or ("Book " .. id),
        authors = authors,
        series = series ~= "" and series or nil,
        series_index = tonumber(series_index),
        cover_url = cover_url,
        download_url = download_url,
        file_type = file_type,
        file_size = file_size,
        filename = filename,
        description = summary ~= "" and summary or nil,
        published_date = published ~= "" and published or nil,
        added_on = updated ~= "" and updated or nil,
        categories = categories,
        tags = tags,
        genres = genres,
        atom_id = atom_id,
    }
end

function OPDS.parse_feed(xml, feed_url)
    local result = { books = {}, total = nil, next_url = nil, title = nil }
    if type(xml) ~= "string" or xml == "" then
        return result
    end

    result.title = unescape(xml:match("<feed[^>]*>.-<title[^>]*>(.-)</title>") or "")
    local total = xml:match("<opensearch:totalResults[^>]*>(%d+)</opensearch:totalResults>")
        or xml:match("<totalResults[^>]*>(%d+)</totalResults>")
    result.total = tonumber(total)

    local head = xml:match("<feed[^>]*>(.-)<entry") or xml
    for tag in head:gmatch("<link([^>]+)/?>") do
        local rel = attr(tag, "rel") or ""
        if rel == "next" then
            local href = attr(tag, "href")
            result.next_url = Origin.absolute(feed_url, href)
        end
    end

    for entry_xml in xml:gmatch("<entry[^>]*>(.-)</entry>") do
        local book = parse_entry_xml(entry_xml, feed_url)
        if book then
            result.books[#result.books + 1] = book
        end
    end
    return result
end

function OPDS.parse_nav(xml, feed_url)
    local result = { items = {}, title = nil }
    if type(xml) ~= "string" or xml == "" then
        return result
    end
    result.title = unescape(xml:match("<feed[^>]*>.-<title[^>]*>(.-)</title>") or "")
    for entry_xml in xml:gmatch("<entry[^>]*>(.-)</entry>") do
        local title = unescape(entry_xml:match("<title[^>]*>(.-)</title>") or "")
        local href
        for tag in entry_xml:gmatch("<link([^>]+)/?>") do
            local rel = attr(tag, "rel") or ""
            local typ = attr(tag, "type") or ""
            local h = attr(tag, "href")
            if h and (rel == "subsection" or rel == "http://opds-spec.org/sort/new"
                    or typ:find("opds-catalog", 1, true) or typ:find("atom+xml", 1, true)
                    or rel == "alternate" or rel == "") then
                href = Origin.absolute(feed_url, h)
                if rel == "subsection" or typ:find("opds-catalog", 1, true) then
                    break
                end
            end
        end
        if title ~= "" and href then
            local count = tonumber(entry_xml:match("<opensearch:totalResults[^>]*>(%d+)"))
                or tonumber(entry_xml:match('count="(%d+)"'))
            result.items[#result.items + 1] = {
                title = title,
                href = href,
                count = count,
            }
        end
    end
    return result
end

function OPDS.parse(xml, feed_url)
    return OPDS.parse_feed(xml, feed_url)
end

return OPDS
