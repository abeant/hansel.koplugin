local Fmt = {}

function Fmt.bytes(n)
    n = tonumber(n) or 0
    if n >= 1024 * 1024 * 1024 then
        return string.format("%.1f GB", n / (1024 * 1024 * 1024))
    elseif n >= 1024 * 1024 then
        return string.format("%.1f MB", n / (1024 * 1024))
    elseif n >= 1024 then
        return string.format("%d KB", math.floor(n / 1024 + 0.5))
    end
    return string.format("%d B", n)
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

--- ISO 8601 (what OPDS <updated> carries) to "12 Mar 2026".
function Fmt.date(iso)
    if type(iso) ~= "string" then return "" end
    local y, m, d = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if not y then return "" end
    local month = MONTHS[tonumber(m)] or m
    return string.format("%d %s %s", tonumber(d), month, y)
end

function Fmt.authors(book)
    if not book then return "" end
    if type(book.authors) == "table" then
        return table.concat(book.authors, ", ")
    end
    return tostring(book.authors or "")
end

return Fmt
