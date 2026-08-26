local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")
local Type = require("ui.type")

local Theme = {
    ink = Blitbuffer.COLOR_BLACK,
    graphite = Blitbuffer.COLOR_BLACK,
    ash = Blitbuffer.COLOR_BLACK,
    paper = Blitbuffer.COLOR_WHITE,
}

Theme.s = function(v)
    return require("device").screen:scaleBySize(v)
end

Theme.hair = Size.border.default
Theme.rule = Size.border.thick
Theme.pad = Size.padding.large
Theme.icon = Size.item.height_default
Theme.gap = Size.span.horizontal_default

Theme.mono = Type.mono
Theme.text = Type.text
Theme.light = Type.light

return Theme
