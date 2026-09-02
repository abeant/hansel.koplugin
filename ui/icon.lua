--[[--
The wireframe icon set, drawn straight into the blitbuffer.

Same 24-unit box and same paths as the prototype's inline SVGs. Drawing them
ourselves keeps the plugin off KOReader's icon assets, which change names
between releases and do not carry a funnel or a pin.
]]

local Icon = {}

-- Every shape lives in a 0..24 box. `lines` are polylines, `boxes` are stroked
-- rectangles {x,y,w,h}, `discs` are filled, `rings` are stroked.
local SHAPES = {
    menu    = { lines = {{3,6, 21,6}, {3,12, 21,12}, {3,18, 21,18}} },
    filter  = { lines = {{3,5, 21,5, 14,13, 14,19, 10,21, 10,13, 3,5}} },
    grid    = { boxes = {{3,3,7,7}, {14,3,7,7}, {3,14,7,7}, {14,14,7,7}} },
    left    = { lines = {{15,4, 7,12, 15,20}} },
    right   = { lines = {{9,4, 17,12, 9,20}} },
    up      = { lines = {{12,19, 12,5}, {6,11, 12,5, 18,11}} },
    down    = { lines = {{12,5, 12,19}, {6,13, 12,19, 18,13}} },
    chev_up = { lines = {{7,15, 12,9, 17,15}} },
    chev_down = { lines = {{7,9, 12,15, 17,9}} },
    chev_right = { lines = {{10,7, 16,12, 10,17}} },
    close   = { lines = {{5,5, 19,19}, {19,5, 5,19}} },
    check   = { lines = {{4,12, 9,18, 20,5}} },
    dot     = { discs = {{12,12,6}} },
    pin     = { lines = {{12,17, 12,22}, {8,3, 16,3, 15,9, 18,12, 18,14, 6,14, 6,12, 9,9, 8,3}} },
    more    = { discs = {{5,12,1.7}, {12,12,1.7}, {19,12,1.7}} },
    book    = { lines = {{4,4, 17,4, 20,7, 20,20, 7,20, 4,17, 4,4}, {4,17, 7,14, 20,14}} },
    layers  = { lines = {{12,3, 21,8, 12,13, 3,8, 12,3}, {3,14, 12,19, 21,14}} },
    person  = { rings = {{12,8,4}}, lines = {{4,21, 5.5,17.5, 9,15.5, 15,15.5, 18.5,17.5, 20,21}} },
    home    = { lines = {{3,11, 12,4, 21,11}, {6,10, 6,20, 18,20, 18,10}} },
    star    = { lines = {{12,3, 14.7,8.8, 21,9.6, 16.4,13.9, 17.6,20, 12,17, 6.4,20, 7.6,13.9, 3,9.6, 9.3,8.8, 12,3}} },
    tray    = { boxes = {{3,5,18,14}}, lines = {{3,13, 8,13, 9,16, 15,16, 16,13, 21,13}} },
    spark   = { lines = {{12,3, 14,9, 20,11, 14,13, 12,19, 10,13, 4,11, 10,9, 12,3}} },
    gear    = { rings = {{12,12,3.5}},
                lines = {{12,2, 12,5}, {12,19, 12,22}, {2,12, 5,12}, {19,12, 22,12},
                         {5,5, 7.5,7.5}, {16.5,16.5, 19,19}, {19,5, 16.5,7.5}, {7.5,16.5, 5,19}} },
    hash    = { lines = {{9,3, 6,21}, {18,3, 15,21}, {3,8, 21,8}, {3,16, 21,16}} },
    folder  = { lines = {{3,7, 3,20, 21,20, 21,7, 11,7, 9,4, 3,4, 3,7}} },
    -- Lucide `shapes`: triangle, square, circle: kinds, not a folder.
    shapes  = { lines = {{12,2, 6,13, 18,13, 12,2}}, boxes = {{3,14,8,8}},
                rings = {{18,18,4}} },
    library = { boxes = {{3,7,5,14}, {10,4,5,17}, {17,9,4,12}} },
    tag     = { lines = {{3,12, 12,3, 21,3, 21,12, 12,21, 3,12}}, discs = {{16,7,1.5}} },
    sliders = { lines = {{4,7, 20,7}, {4,12, 20,12}, {4,17, 20,17}},
                discs = {{8,7,2.2}, {16,12,2.2}, {11,17,2.2}} },
    search  = { rings = {{10,10,6.2}}, lines = {{14.8,14.8, 20.5,20.5}} },
    heart   = { lines = {{12,20, 3,11, 3,7, 7,4, 10,4, 12,7, 14,4, 17,4, 21,7, 21,11, 12,20}} },
    ["book-open"] = { lines = {{12,6, 4,9, 4,19, 12,16}, {12,6, 20,9, 20,19, 12,16}, {12,6, 12,16}} },
}

-- Grimmory libraries/shelves use Lucide names (and optional custom SVGs).
local ALIAS = {
    ["book-open"] = "book-open",
    ["book-marked"] = "book",
    bookmark = "pin",
    ["book-copy"] = "book",
    ["book-plus"] = "book",
    ["book-text"] = "book",
    heart = "heart",
    ["heart-off"] = "heart",
    star = "star",
    sparkles = "spark",
    sparkle = "spark",
    tag = "tag",
    tags = "tag",
    library = "library",
    inbox = "tray",
    package = "tray",
    ["package-open"] = "tray",
    archive = "tray",
    folder = "folder",
    ["folder-open"] = "folder",
    shapes = "shapes",
    genre = "shapes",
    genres = "shapes",
    category = "shapes",
    categories = "shapes",
    user = "person",
    users = "person",
    settings = "gear",
    cog = "gear",
    search = "search",
    pin = "pin",
    home = "home",
    house = "home",
    layers = "layers",
    grid = "grid",
    filter = "filter",
    sliders = "sliders",
    ["sliders-horizontal"] = "sliders",
    ["notebook-pen"] = "book",
    notebook = "book",
    pen = "hash",
    pencil = "hash",
    hash = "hash",
    more = "more",
    menu = "menu",
    book = "book",
    spark = "spark",
    tray = "tray",
    person = "person",
    gear = "gear",
}

function Icon.alias(name)
    if type(name) ~= "string" or name == "" then return nil end
    name = string.lower(name)
    if SHAPES[name] then return name end
    local mapped = ALIAS[name]
    if mapped and SHAPES[mapped] then return mapped end
    local compact = name:gsub("%-", "")
    if SHAPES[compact] then return compact end
    return nil
end

local function round(v)
    return math.floor(v + 0.5)
end

--- Square-capped straight stroke.
local function stroke(bb, x0, y0, x1, y1, t, c)
    x0, y0, x1, y1 = round(x0), round(y0), round(x1), round(y1)
    local half = math.floor(t / 2)
    if y0 == y1 then
        local x, w = math.min(x0, x1), math.abs(x1 - x0) + t
        bb:paintRect(x - half, y0 - half, w, t, c)
        return
    end
    if x0 == x1 then
        local y, h = math.min(y0, y1), math.abs(y1 - y0) + t
        bb:paintRect(x0 - half, y - half, t, h, c)
        return
    end
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy))
    for i = 0, steps do
        bb:paintRect(x0 + round(dx * i / steps) - half,
                     y0 + round(dy * i / steps) - half, t, t, c)
    end
end

local function disc(bb, cx, cy, r, c)
    local ri = math.max(1, round(r))
    for dy = -ri, ri do
        local dx = math.floor(math.sqrt(math.max(0, ri * ri - dy * dy)) + 0.5)
        if dx > 0 then
            bb:paintRect(round(cx) - dx, round(cy) + dy, dx * 2 + 1, 1, c)
        end
    end
end

local function ring(bb, cx, cy, r, t, c)
    local steps = math.max(24, round(r * 8))
    local half = math.floor(t / 2)
    for i = 0, steps do
        local a = i * 2 * math.pi / steps
        bb:paintRect(round(cx + r * math.cos(a)) - half,
                     round(cy + r * math.sin(a)) - half, t, t, c)
    end
end

--- Paint `name` into a size×size box whose top-left is (x, y).
function Icon.paint(bb, name, x, y, size, color, thickness)
    name = Icon.alias(name) or name
    local shape = SHAPES[name]
    if not shape then return end
    local k = size / 24
    local t = thickness or math.max(2, round(size / 10))
    local function px(v) return x + v * k end
    local function py(v) return y + v * k end

    for _, poly in ipairs(shape.lines or {}) do
        for i = 1, #poly - 3, 2 do
            stroke(bb, px(poly[i]), py(poly[i + 1]), px(poly[i + 2]), py(poly[i + 3]), t, color)
        end
    end
    for _, b in ipairs(shape.boxes or {}) do
        bb:paintBorder(round(px(b[1])), round(py(b[2])),
            round(b[3] * k), round(b[4] * k), t, color)
    end
    for _, d in ipairs(shape.discs or {}) do
        disc(bb, px(d[1]), py(d[2]), d[3] * k, color)
    end
    for _, r in ipairs(shape.rings or {}) do
        ring(bb, px(r[1]), py(r[2]), r[3] * k, t, color)
    end
end

function Icon.has(name)
    return Icon.alias(name) ~= nil
end

--- Map a Grimmory library/shelf icon (Lucide name or custom SVG) to a
--- shape we can paint. CUSTOM_SVG files are blitted separately; this is
--- the fallback glyph (selected rows, missing file, unknown Lucide name).
function Icon.from_grimmory(name, kind, fallback)
    kind = string.upper(tostring(kind or "LUCIDE"))
    if kind ~= "CUSTOM_SVG" then
        return Icon.alias(name) or Icon.alias(fallback) or fallback or "library"
    end
    return Icon.alias(fallback) or fallback or "library"
end

return Icon
