--[[--
Just enough KOReader to run the hansel UI off-device.

The stubs are deliberately strict: every coordinate that reaches the fake
blitbuffer is asserted to be a finite number, so a layout bug shows up here as
a failed assertion instead of a blank screen on an e-reader.
]]

local Stub = {}
local settings_files = {}
local reader_settings = {}

local function num(v, what)
    assert(type(v) == "number", (what or "value") .. " is not a number: " .. tostring(v))
    assert(v == v, (what or "value") .. " is NaN")
    assert(v ~= math.huge and v ~= -math.huge, (what or "value") .. " is infinite")
    return v
end

-- ---------- blitbuffer ----------

local BB = {}
BB.__index = BB

function BB.new(w, h)
    return setmetatable({ w = w, h = h, calls = 0, out_of_bounds = 0 }, BB)
end

function BB:_bounds(x, y, w, h)
    if x < 0 or y < 0 or x + w > self.w or y + h > self.h then
        self.out_of_bounds = self.out_of_bounds + 1
        self.last_overflow = string.format("%dx%d at %d,%d (screen %dx%d)", w, h, x, y, self.w, self.h)
    end
end
function BB:paintRect(x, y, w, h, c)
    num(x, "rect x") num(y, "rect y") num(w, "rect w") num(h, "rect h")
    assert(c ~= nil, "rect colour is nil")
    self:_bounds(x, y, w, h)
    self.calls = self.calls + 1
end
function BB:paintBorder(x, y, w, h, t, c)
    num(x, "border x") num(y, "border y") num(w, "border w") num(h, "border h")
    num(t, "border thickness")
    assert(c ~= nil, "border colour is nil")
    self:_bounds(x, y, w, h)
    self.calls = self.calls + 1
end
function BB:invertRect(x, y, w, h)
    num(x) num(y) num(w) num(h)
    self.calls = self.calls + 1
end
function BB:free() end

Stub.BB = BB

-- ---------- module table ----------

local Screen = {
    getWidth = function() return 1072 end,
    getHeight = function() return 1448 end,
    scaleBySize = function(_, v) return math.floor(v * 2) end,
    getSize = function() return { x = 0, y = 0, w = 1072, h = 1448 } end,
}

local Blitbuffer = {
    COLOR_BLACK = "black",
    COLOR_WHITE = "white",
    COLOR_GRAY = "gray",
    COLOR_GRAY_3 = "gray3",
    COLOR_LIGHT_GRAY = "light",
    COLOR_DARK_GRAY = "dark",
}

local Geom = {}
Geom.__index = Geom
function Geom:new(o)
    o = o or {}
    return setmetatable(o, Geom)
end
function Geom:copy() return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h } end

local Widget = {}
Widget.__index = Widget
function Widget:extend(subclass)
    subclass = subclass or {}
    subclass.__index = subclass
    return setmetatable(subclass, { __index = self })
end
function Widget:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if o._init then o:_init() end
    if o.init then o:init() end
    return o
end
function Widget:free() end
function Widget:paintTo() end
function Widget:getSize() return Geom:new{ w = 0, h = 0 } end

local function text_width(text, face)
    return math.ceil(#tostring(text) * (face and face.size or 12) * 0.55)
end

local TextWidget = Widget:extend{}
function TextWidget:init()
    assert(self.face, "TextWidget without a face")
    assert(self.text ~= nil, "TextWidget without text")
    local w = text_width(self.text, self.face)
    if self.max_width then w = math.min(w, self.max_width) end
    self._size = Geom:new{ w = w, h = math.ceil(self.face.size * 1.3) }
end
function TextWidget:getSize() return self._size end
function TextWidget:paintTo(bb, x, y)
    num(x, "text x") num(y, "text y")
    bb.calls = bb.calls + 1
end

local TextBoxWidget = Widget:extend{}
function TextBoxWidget:init()
    assert(self.face, "TextBoxWidget without a face")
    assert(self.width and self.width > 0, "TextBoxWidget without a width")
    local line = math.ceil(self.face.size * 1.3)
    local lines = math.max(1, math.ceil(text_width(self.text, self.face) / self.width))
    local h = lines * line
    if self.height then h = math.min(h, self.height) end
    self._size = Geom:new{ w = self.width, h = h }
end
function TextBoxWidget:getSize() return self._size end
function TextBoxWidget:paintTo(bb, x, y)
    num(x, "para x") num(y, "para y")
    bb.calls = bb.calls + 1
end

local ImageWidget = Widget:extend{}
function ImageWidget:init()
    assert(self.file, "ImageWidget without a file")
    self._size = Geom:new{ w = self.width or 10, h = self.height or 10 }
end
function ImageWidget:getSize() return self._size end
function ImageWidget:paintTo(bb, x, y)
    num(x, "image x") num(y, "image y")
    bb.calls = bb.calls + 1
end

local UIManager = {
    stack = {},
    queue = {},
    bb = BB.new(1072, 1448),
}
function UIManager:show(widget)
    table.insert(self.stack, widget)
    if widget.paintTo then widget:paintTo(self.bb, 0, 0) end
    return widget
end
function UIManager:close(widget)
    for i = #self.stack, 1, -1 do
        if self.stack[i] == widget then table.remove(self.stack, i) end
    end
    if widget and widget.onCloseWidget then widget:onCloseWidget() end
end
function UIManager:isWidgetShown(widget)
    for _, w in ipairs(self.stack) do if w == widget then return true end end
    return false
end
function UIManager:setDirty(widget, _, region)
    if region then
        num(region.x, "dirty x") num(region.y, "dirty y")
        num(region.w, "dirty w") num(region.h, "dirty h")
    end
    if widget and widget ~= "all" and type(widget) == "table" and widget.paintTo then
        widget:paintTo(self.bb, 0, 0)
    end
end
function UIManager:nextTick(fn) table.insert(self.queue, fn) end
function UIManager:scheduleIn(_, fn) table.insert(self.queue, fn) end
function UIManager:unschedule(fn)
    for i = #self.queue, 1, -1 do
        if self.queue[i] == fn then table.remove(self.queue, i) end
    end
end
function UIManager:run_next()
    local fn = table.remove(self.queue, 1)
    if fn then fn() end
    return fn ~= nil
end
function UIManager:drain()
    local guard = 0
    while #self.queue > 0 do
        guard = guard + 1
        assert(guard < 500, "scheduler did not settle")
        self:run_next()
    end
end

local InputContainer = Widget:extend{}
function InputContainer:_init() end
function InputContainer:paintTo(bb, x, y)
    if self[1] and self[1].paintTo then self[1]:paintTo(bb, x, y) end
end

local Trapper = {}
function Trapper:wrap(fn) fn() end
function Trapper:info() return true end
function Trapper:clear() end
function Trapper:setPausedText() end

local function noop_widget()
    local W = Widget:extend{}
    function W:init() end
    return W
end

local NetworkMgr = {
    online = false,
    wifi_on = false,
    isOnline = function(self) return self.online end,
    isWifiOn = function(self) return self.wifi_on end,
    willRerunWhenOnline = function() return false end,
}

local function fake_digest(value)
    local hash = 2166136261
    for i = 1, #tostring(value) do
        hash = (hash * 16777619 + tostring(value):byte(i)) % 4294967296
    end
    return ("%08x"):format(hash):rep(4)
end

local preload = {
    ["ffi/blitbuffer"] = Blitbuffer,
    ["ffi/util"] = { template = function(fmt, ...)
        local args = { ... }
        return (tostring(fmt):gsub("%%(%d)", function(i)
            return tostring(args[tonumber(i)])
        end))
    end },
    ["ffi/sha2"] = { sha256 = fake_digest, md5 = fake_digest },
    ["gettext"] = setmetatable({}, { __call = function(_, s) return s end }),
    ["logger"] = { dbg = function() end, info = function() end, warn = function() end,
                   err = function() end },
    ["device"] = {
        model = "Test Reader",
        screen = Screen,
        hasKeys = function() return true end,
        input = { group = { Back = { "Back" } } },
        isAndroid = function() return false end,
    },
    ["ui/geometry"] = Geom,
    ["ui/gesturerange"] = { new = function(_, o) return o end },
    ["ui/size"] = {
        border = { default = 2, thick = 3 },
        padding = { fullscreen = 15, default = 5, large = 10, small = 2 },
        span = { horizontal_small = 5, horizontal_default = 10 },
        item = { height_default = 30, height_big = 40 },
    },
    ["ui/font"] = {
        sizemap = {
            tfont = 26, infofont = 24, cfont = 22, smallinfofont = 22, x_smallinfofont = 20,
        },
        getFace = function(_, name, size)
            return { hash = tostring(name) .. tostring(size or 24), size = size or 24, orig_size = size or 24 }
        end,
    },
    ["ui/event"] = { new = function(_, name, ...)
        return { name = name, args = { ... } }
    end },
    ["ui/uimanager"] = UIManager,
    ["ui/trapper"] = Trapper,
    ["ui/widget/textwidget"] = TextWidget,
    ["ui/widget/textboxwidget"] = TextBoxWidget,
    ["ui/widget/imagewidget"] = ImageWidget,
    ["ui/widget/container/inputcontainer"] = InputContainer,
    ["ui/widget/container/widgetcontainer"] = InputContainer,
    ["ui/widget/buttondialog"] = noop_widget(),
    ["ui/widget/confirmbox"] = noop_widget(),
    ["ui/widget/infomessage"] = noop_widget(),
    ["ui/widget/inputdialog"] = noop_widget(),
    ["ui/widget/multiinputdialog"] = noop_widget(),
    ["ui/network/manager"] = NetworkMgr,
    ["datastorage"] = {
        getDataDir = function() return "/tmp/hansel-test" end,
        getSettingsDir = function() return "/tmp/hansel-test/settings" end,
        getFullDataDir = function() return "/tmp/hansel-test" end,
    },
    ["docsettings"] = { hasSidecarFile = function() return false end },
    ["libs/libkoreader-lfs"] = {
        attributes = function() return nil end,
        dir = function() return function() return nil end end,
        mkdir = function() return true end,
    },
    ["pluginloader"] = { isPluginLoaded = function() return false end },
    ["util"] = { partialMD5 = function(path) return fake_digest(path) end },
    ["luasettings"] = {
        open = function(_, path)
            settings_files[path] = settings_files[path] or {}
            local store = settings_files[path]
            return {
                readSetting = function(_, k) return store[k] end,
                saveSetting = function(_, k, v) store[k] = v end,
                delSetting = function(_, k) store[k] = nil end,
                flush = function() end,
            }
        end,
    },
}

function Stub.install()
    UIManager.stack = {}
    UIManager.queue = {}
    UIManager.bb = BB.new(1072, 1448)
    NetworkMgr.online = false
    NetworkMgr.wifi_on = false
    _G.G_reader_settings = {
        readSetting = function(_, key) return reader_settings[key] end,
        saveSetting = function(_, key, value) reader_settings[key] = value end,
        delSetting = function(_, key) reader_settings[key] = nil end,
        flush = function() end,
    }
    for name, mod in pairs(preload) do
        package.loaded[name] = mod
        package.loaded[(name:gsub("/", "."))] = mod
    end
    return {
        Screen = Screen,
        UIManager = UIManager,
        Geom = Geom,
        bb = UIManager.bb,
        NetworkMgr = NetworkMgr,
        settings_files = settings_files,
        reader_settings = reader_settings,
    }
end

function Stub.reset_settings()
    for key in pairs(settings_files) do settings_files[key] = nil end
    for key in pairs(reader_settings) do reader_settings[key] = nil end
end

Stub.num = num

return Stub
