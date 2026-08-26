local Search = {}

local function hay(book)
    local parts = {
        tostring(book.title or ""),
        tostring(book.series or ""),
        tostring(book.filename or ""),
    }
    local authors = book.authors
    if type(authors) == "table" then
        for _, a in ipairs(authors) do
            if type(a) == "string" then
                parts[#parts + 1] = a
            elseif type(a) == "table" then
                parts[#parts + 1] = tostring(a.name or a.title or "")
            end
        end
    else
        parts[#parts + 1] = tostring(authors or "")
    end
    for _, key in ipairs({ "tags", "genres", "categories" }) do
        local list = book[key]
        if type(list) == "table" then
            for _, t in ipairs(list) do
                parts[#parts + 1] = tostring(t)
            end
        elseif type(list) == "string" then
            parts[#parts + 1] = list
        end
    end
    local path = book.local_path
    if not path and book.id then
        local ok, CacheMap = pcall(require, "lib.cache_map")
        if ok and CacheMap.local_path then path = CacheMap.local_path(book.id) end
    end
    if path then parts[#parts + 1] = path end
    return table.concat(parts, " "):lower()
end

function Search.query(q, books)
    q = tostring(q or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return {} end
    local src = books
    if not src then
        local ok, Catalog = pcall(require, "lib.catalog")
        src = (ok and Catalog.all_books and Catalog.all_books()) or {}
    end
    local out = {}
    for _, book in ipairs(src or {}) do
        if hay(book):find(q, 1, true) then
            out[#out + 1] = book
        end
    end
    return out
end

return Search
