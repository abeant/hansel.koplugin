--[[--
Base for every hansel surface.

Subclasses implement `build(draw)` and nothing else: lay out in absolute
screen coordinates, register tap rects, done. This class owns the draw list,
tap dispatch with a press flash, and the e-ink refresh choices.
]]

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Draw = require("ui.paint")

local Screen = Device.screen

local Base = InputContainer:extend{
    name = "hansel_surface",
    -- Full-screen surfaces paint every pixel; overlays leave the page behind.
    covers_fullscreen = true,
    -- Overlays set this to the panel rect so only that area is repainted.
    panel = nil,
}

function Base:init()
    -- setup() runs first: overlays work out their panel rect there, and dimen
    -- has to be that rect or UIManager repaints the wrong region.
    if self.setup then self:setup() end
    self.dimen = self.panel or Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = full } },
    }
    if self.wants_swipe then
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = full } }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
        if self.wants_paging then
            self.key_events.NextPage = { { "RPgFwd" }, { "Right" } }
            self.key_events.PrevPage = { { "RPgBack" }, { "Left" } }
        end
    end
    self:rebuild()
end

--- Subclasses override.
function Base:build(draw) end -- luacheck: ignore

function Base:rebuild(refresh)
    if self._closed then return end
    local old = self._draw
    local draw = Draw.new()
    local ok, err = pcall(self.build, self, draw)
    if not ok then
        draw:free()
        if old then self._draw = old end
        require("logger").warn("[hansel] layout failed:", err)
        return
    end
    self._draw = draw
    if old then old:free() end
    if refresh then
        UIManager:setDirty(self, refresh)
    end
end

--- A cover landed: swap that tile's image on the retained list. No full rebuild.
function Base:coverArrived(id, path, region)
    if self._closed then return end
    local draw = self._draw
    local box = region
    if type(box) ~= "table" or not box.w then
        box = self._tile_rects and self._tile_rects[tostring(id)]
    end
    if type(box) ~= "table" or not box.w or not box.h then
        box = nil
    end
    if draw and path and box and draw.image then
        local ix = draw:image(path, box.x, box.y, box.w, box.h)
        if ix then
            UIManager:setDirty(self, "ui", Geom:new{
                x = box.x, y = box.y, w = box.w, h = box.h,
            })
            return true
        end
    end
    self:rebuild()
    if box then
        UIManager:setDirty(self, "ui", Geom:new{
            x = box.x, y = box.y, w = box.w, h = box.h,
        })
    else
        UIManager:setDirty(self, "ui")
    end
    return false
end

function Base:paintTo(bb, x, y)
    if self._draw then
        self._draw:paint(bb, x, y, self._pressed)
    end
end

function Base:onTap(_, ges)
    local hit = self._draw and self._draw:hit(ges and ges.pos)
    if not hit then
        self:onTapOutside(ges)
        return true
    end
    if not hit.invert then
        hit.callback()
        return true
    end
    local region = self._draw:region(hit)
    self._pressed = hit
    UIManager:setDirty(self, "fast", region)
    UIManager:scheduleIn(0.07, function()
        self._pressed = nil
        if not self._closed then
            UIManager:setDirty(self, "fast", region)
        end
        hit.callback()
    end)
    return true
end

--- Taps that miss every target. Overlays close; full screens swallow.
function Base:onTapOutside()
    return true
end

--- Page-turn-sized change: let the panel do a real full refresh.
function Base:flash()
    UIManager:setDirty(self, "full")
end

function Base:onClose()
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

function Base:onCloseWidget()
    self._closed = true
    if self._draw then
        self._draw:free()
        self._draw = nil
    end
end

function Base:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function Base:free()
    if self._draw then
        self._draw:free()
        self._draw = nil
    end
end

return Base
