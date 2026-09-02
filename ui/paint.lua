--[[--
A tiny retained draw list.

Screens lay themselves out in absolute coordinates once, in `build`, and keep
an ordered list of paint closures plus a list of tap rectangles. That buys the
hairline-exact geometry the wireframe is drawn in without stacking twenty
nested containers per screen, and without a container ever ending up childless,
which is what took the filter sheet down.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Icon = require("ui.icon")
local Theme = require("ui.theme")

local Screen = Device.screen

local Draw = {}
Draw.__index = Draw

function Draw.new()
    return setmetatable({ ops = {}, hits = {}, owned = {} }, Draw)
end

function Draw:op(fn)
    self.ops[#self.ops + 1] = fn
    return self
end

function Draw:keep(widget)
    self.owned[#self.owned + 1] = widget
    return widget
end

-- ---------- primitives ----------

local function clip_box(x, y, w, h)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if x < 0 then w = w + x; x = 0 end
    if y < 0 then h = h + y; y = 0 end
    if x + w > sw then w = sw - x end
    if y + h > sh then h = sh - y end
    if w <= 0 or h <= 0 then return nil end
    return x, y, w, h
end

function Draw:fill(x, y, w, h, color)
    if w <= 0 or h <= 0 then return self end
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    x, y, w, h = clip_box(x, y, w, h)
    if not x then return self end
    color = color or Theme.ink
    return self:op(function(bb, ox, oy)
        bb:paintRect(x + ox, y + oy, w, h, color)
    end)
end

function Draw:border(x, y, w, h, thickness, color)
    if w <= 0 or h <= 0 then return self end
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    x, y, w, h = clip_box(x, y, w, h)
    if not x then return self end
    thickness = thickness or Theme.hair
    color = color or Theme.ink
    return self:op(function(bb, ox, oy)
        bb:paintBorder(x + ox, y + oy, w, h, thickness, color)
    end)
end

--- Dotted border, for the "nothing here" mark.
function Draw:dotted(x, y, w, h, thickness, color)
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    thickness = thickness or Theme.rule
    color = color or Theme.ink
    local step = thickness * 3
    return self:op(function(bb, ox, oy)
        for px = x, x + w - 1, step do
            local seg = math.min(thickness * 2, x + w - px)
            bb:paintRect(px + ox, y + oy, seg, thickness, color)
            bb:paintRect(px + ox, y + h - thickness + oy, seg, thickness, color)
        end
        for py = y, y + h - 1, step do
            local seg = math.min(thickness * 2, y + h - py)
            bb:paintRect(x + ox, py + oy, thickness, seg, color)
            bb:paintRect(x + w - thickness + ox, py + oy, thickness, seg, color)
        end
    end)
end

function Draw:rule(x, y, w, thickness, color)
    return self:fill(x, y, w, thickness or Theme.rule, color or Theme.ink)
end

function Draw:icon(name, x, y, size, color, thickness)
    x, y, size = math.floor(x), math.floor(y), math.floor(size)
    color = color or Theme.ink
    return self:op(function(bb, ox, oy)
        Icon.paint(bb, name, x + ox, y + oy, size, color, thickness)
    end)
end

-- ---------- text ----------

--- Build a single-line label without placing it. Returns widget, w, h.
function Draw:label(text, face, color, max_width)
    local widget = TextWidget:new{
        text = tostring(text or ""),
        face = face,
        fgcolor = color or Theme.ink,
        max_width = max_width,
        truncate_with_ellipsis = max_width ~= nil,
    }
    self:keep(widget)
    local size = widget:getSize()
    return widget, size.w, size.h
end

function Draw:place(widget, x, y)
    x, y = math.floor(x), math.floor(y)
    return self:op(function(bb, ox, oy)
        widget:paintTo(bb, x + ox, y + oy)
    end)
end

--- Place a label at (x, y). Returns its width and height.
function Draw:text(x, y, text, face, color, max_width)
    local widget, w, h = self:label(text, face, color, max_width)
    self:place(widget, x, y)
    return w, h
end

function Draw:text_right(right_x, y, text, face, color, max_width)
    local widget, w, h = self:label(text, face, color, max_width)
    self:place(widget, right_x - w, y)
    return w, h
end

function Draw:text_center(cx, y, text, face, color, max_width)
    local widget, w, h = self:label(text, face, color, max_width)
    self:place(widget, cx - math.floor(w / 2), y)
    return w, h
end

-- Line metrics only depend on the face, so measure each one once.
local box_line_cache = setmetatable({}, { __mode = "k" })
local text_line_cache = setmetatable({}, { __mode = "k" })

local function release(widget)
    if widget and widget.free then pcall(widget.free, widget) end
end

--- Height of one wrapped line in `face`.
function Draw:line_height(face)
    local cached = box_line_cache[face]
    if cached then return cached end
    local probe = TextBoxWidget:new{ text = "Ag", face = face, width = Theme.s(200), line_height = 0 }
    local h = probe:getSize().h
    release(probe)
    box_line_cache[face] = h
    return h
end

--- Height of a single-line label in `face`.
function Draw:label_height(face)
    local cached = text_line_cache[face]
    if cached then return cached end
    local probe = TextWidget:new{ text = "Ag", face = face }
    local h = probe:getSize().h
    release(probe)
    text_line_cache[face] = h
    return h
end

--- Wrapped text clamped to `max_lines`. Returns {widget, w, h, line}.
function Draw:para_box(text, face, width, max_lines, color, alignment)
    width = math.floor(width)
    local line = self:line_height(face)
    local function make(height)
        return TextBoxWidget:new{
            text = tostring(text or ""),
            face = face,
            width = width,
            height = height,
            height_overflow_show_ellipsis = height ~= nil,
            line_height = 0,
            fgcolor = color or Theme.ink,
            alignment = alignment or "left",
        }
    end
    local widget = make(nil)
    local h = widget:getSize().h
    if max_lines and h > line * max_lines + 1 then
        release(widget)
        widget = make(line * max_lines)
        h = line * max_lines
    end
    self:keep(widget)
    return { widget = widget, w = width, h = h, line = line }
end

--- Wrapped paragraph clamped to `height` (nil = as tall as it needs).
function Draw:para(x, y, text, face, width, height, color, alignment)
    local widget = TextBoxWidget:new{
        text = tostring(text or ""),
        face = face,
        width = math.floor(width),
        height = height and math.floor(height) or nil,
        fgcolor = color or Theme.ink,
        alignment = alignment or "left",
    }
    self:keep(widget)
    self:place(widget, x, y)
    return widget:getSize().h
end

-- ---------- images ----------

--- Fit the whole image inside the box (no crop). Returns x,y,w,h of the art.
function Draw:image(path, x, y, max_w, max_h, align)
    max_w, max_h = math.floor(max_w), math.floor(max_h)
    if max_w < 1 or max_h < 1 then return nil end
    local ok_probe, probe = pcall(function()
        return ImageWidget:new{ file = path, file_do_cache = true }
    end)
    if not ok_probe or not probe then return nil end
    local ok_nat, nat = pcall(probe.getSize, probe)
    if probe.free then pcall(probe.free, probe) end
    if not ok_nat or not nat or not nat.w or nat.w < 1 or nat.h < 1 then
        return nil
    end
    local scale = math.min(max_w / nat.w, max_h / nat.h)
    local iw = math.max(1, math.floor(nat.w * scale))
    local ih = math.max(1, math.floor(nat.h * scale))
    local ok, widget = pcall(function()
        return ImageWidget:new{
            file = path,
            width = iw,
            height = ih,
            scale_factor = 0,
            file_do_cache = true,
        }
    end)
    if not ok or not widget then return nil end
    self:keep(widget)
    local ix
    if align == "left" then
        ix = x
    elseif align == "right" then
        ix = x + max_w - iw
    else
        ix = math.floor(x + (max_w - iw) / 2)
    end
    local iy = math.floor(y + (max_h - ih) / 2)
    self:place(widget, ix, iy)
    return ix, iy, iw, ih
end

-- ---------- interaction ----------

--- Register a tap target. `invert` flashes the rect while the finger is down.
function Draw:tap(x, y, w, h, callback, invert)
    if not callback then return self end
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    local box_x, box_y, box_w, box_h = clip_box(x, y, w, h)
    if not box_x then return self end
    local flash = { x = box_x, y = box_y, w = box_w, h = box_h }
    if box_h < 40 then
        local extra = 40 - box_h
        box_y = box_y - math.floor(extra / 2)
        box_h = 40
    end
    if box_w < 40 then
        local extra = 40 - box_w
        box_x = box_x - math.floor(extra / 2)
        box_w = 40
    end
    self.hits[#self.hits + 1] = {
        x = box_x, y = box_y,
        w = box_w, h = box_h,
        flash = flash,
        callback = callback,
        invert = invert ~= false,
    }
    return self
end

function Draw:hit(pos)
    if not pos then return nil end
    for i = #self.hits, 1, -1 do
        local r = self.hits[i]
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then
            return r
        end
    end
    return nil
end

function Draw:region(r)
    local f = r.flash or r
    return Geom:new{ x = f.x, y = f.y, w = f.w, h = f.h }
end

-- ---------- output ----------

function Draw:paint(bb, ox, oy, pressed)
    ox, oy = ox or 0, oy or 0
    for i = 1, #self.ops do
        self.ops[i](bb, ox, oy)
    end
    if pressed then
        local f = pressed.flash or pressed
        bb:invertRect(f.x + ox, f.y + oy, f.w, f.h)
    end
end

function Draw:free()
    for i = 1, #self.owned do
        local w = self.owned[i]
        if w and w.free then
            pcall(w.free, w)
        end
    end
    self.owned = {}
    self.ops = {}
    self.hits = {}
end

Draw.Screen = Screen

return Draw
