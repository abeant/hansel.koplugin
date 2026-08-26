local Library = require("lib.library")

local Center = {
    items = {},
}

local function find(id)
    id = tostring(id)
    for _, item in ipairs(Center.items) do
        if tostring(item.book.id) == id then return item end
    end
end

function Center.list()
    return Center.items
end

function Center.enqueue(book, opts)
    opts = opts or {}
    if not book or not book.id then return false end
    local item = find(book.id)
    if not item then
        item = { book = book, status = "queued" }
        Center.items[#Center.items + 1] = item
    end
    item.status = "downloading"
    item.error = nil
    local ok, err = Library.download(book)
    if ok then
        item.status = "done"
        item.path = err
    else
        item.status = "failed"
        item.error = err
    end
    if opts.on_done then opts.on_done(ok, err) end
    return ok and true or false
end

function Center.add(book, opts)
    return Center.enqueue(book, opts)
end

function Center.retry(id)
    local item = find(id)
    if not item then return false end
    return Center.enqueue(item.book, {})
end

function Center.cancel(id)
    local item = find(id)
    if item and item.status == "queued" then
        item.status = "cancelled"
        return true
    end
    return false
end

return Center
