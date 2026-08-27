local Search = {}

local function label_of(value)
    if type(value) == "string" then return value end
    if type(value) == "table" then
        return tostring(value.name or value.title or value.label or value.tag or "")
    end
    return tostring(value or "")
end

local function add_names(parts, value)
    if type(value) == "table" and value[1] ~= nil then
        for i = 1, #value do
            local name = label_of(value[i])
            if name ~= "" then parts[#parts + 1] = name end
        end
    else
        local name = label_of(value)
        if name ~= "" then parts[#parts + 1] = name end
    end
end

local function author_names(book)
    local parts = {}
    add_names(parts, book.authors or book.author)
    return parts
end

local function tag_names(book)
    local parts = {}
    add_names(parts, book.tags)
    add_names(parts, book.tag)
    add_names(parts, book.genres)
    return parts
end

local function category_names(book)
    local parts = {}
    add_names(parts, book.categories)
    add_names(parts, book.category)
    add_names(parts, book.genres)
    return parts
end

local function contains(text, q)
    text = tostring(text or ""):lower()
    return q ~= "" and text:find(q, 1, true) ~= nil
end

function Search.why(book, q)
    q = tostring(q or ""):lower()
    if contains(book.title, q) then return "Title" end
    local authors = author_names(book)
    for i = 1, #authors do
        if contains(authors[i], q) then return "Author" end
    end
    local tags = tag_names(book)
    for i = 1, #tags do
        if contains(tags[i], q) then return "Tag" end
    end
    local cats = category_names(book)
    for i = 1, #cats do
        if contains(cats[i], q) then return "Category" end
    end
    if contains(book.series, q) then return "Series" end
    return "Book"
end

local function hay(book)
    local parts = {
        tostring(book.title or ""),
        tostring(book.series or ""),
        tostring(book.filename or ""),
    }
    add_names(parts, book.authors or book.author)
    add_names(parts, book.tags)
    add_names(parts, book.tag)
    add_names(parts, book.genres)
    add_names(parts, book.categories)
    add_names(parts, book.category)
    local path = book.local_path
    if not path and book.id then
        local ok, CacheMap = pcall(require, "lib.cache_map")
        if ok and CacheMap.get then
            local e = CacheMap.get(book.id)
            path = e and e.path
        end
    end
    if path then parts[#parts + 1] = path end
    return table.concat(parts, " "):lower()
end

function Search.corpus()
    local seen, out = {}, {}
    local function add(list)
        for i = 1, #(list or {}) do
            local book = list[i]
            local id = book.id or book.title
            if id and not seen[id] then
                seen[id] = true
                out[#out + 1] = book
            elseif not id then
                out[#out + 1] = book
            end
        end
    end
    local ok_c, Catalog = pcall(require, "lib.catalog")
    if ok_c and Catalog.all_books then add(Catalog.all_books()) end
    local ok_m, CacheMap = pcall(require, "lib.cache_map")
    if ok_m and CacheMap.local_books then add(CacheMap.local_books()) end
    return out
end

function Search.query(q, books)
    q = tostring(q or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return {} end
    local src = books or Search.corpus()
    local out = {}
    for i = 1, #(src or {}) do
        local book = src[i]
        if hay(book):find(q, 1, true) then
            out[#out + 1] = book
        end
    end
    return out
end

local function facet_items(kind)
    local items = {}
    local seen = {}
    local function push(title, extra)
        title = tostring(title or "")
        if title == "" or seen[title:lower()] then return end
        seen[title:lower()] = true
        extra = extra or {}
        extra.title = title
        extra.kind = kind
        items[#items + 1] = extra
    end
    local ok, Nav = pcall(require, "lib.nav")
    if ok and Nav.get then
        local nav_items = (Nav.get(kind).items or {})
        for i = 1, #nav_items do
            push(nav_items[i].title, nav_items[i])
        end
    end
    local corpus = Search.corpus()
    if kind == "authors" then
        for i = 1, #corpus do
            local names = author_names(corpus[i])
            for n = 1, #names do push(names[n]) end
        end
    elseif kind == "tags" then
        for i = 1, #corpus do
            local names = tag_names(corpus[i])
            for n = 1, #names do push(names[n]) end
        end
    elseif kind == "categories" then
        for i = 1, #corpus do
            local names = category_names(corpus[i])
            for n = 1, #names do push(names[n]) end
        end
    end
    table.sort(items, function(a, b) return a.title:lower() < b.title:lower() end)
    return items
end

function Search.find(q, kind)
    kind = kind or "books"
    q = tostring(q or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return {} end
    if kind == "books" then
        local out = {}
        local hits = Search.query(q)
        for i = 1, #hits do
            local book = hits[i]
            out[#out + 1] = {
                kind = "book",
                title = book.title or "",
                why = Search.why(book, q),
                book = book,
            }
        end
        return out
    end
    local out = {}
    local items = facet_items(kind)
    for i = 1, #items do
        local item = items[i]
        if contains(item.title, q) then
            out[#out + 1] = item
        end
    end
    return out
end

return Search
