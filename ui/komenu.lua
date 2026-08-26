local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Komenu = {}

local function host(home)
    if home and home.plugin and home.plugin.ui then
        return home.plugin.ui
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok_fm and FileManager and FileManager.instance then
        return FileManager.instance
    end
    local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_r and ReaderUI and ReaderUI.instance then
        return ReaderUI.instance
    end
    return nil
end

--- Open KOReader's own menu on top of hansel. Same path File Manager uses:
--- the live UI widget handles a ShowMenu event.
function Komenu.show(home)
    local ui = host(home)
    if not ui then
        logger.warn("[hansel] KOReader menu: no File Manager")
        UIManager:show(InfoMessage:new{
            text = _("Open File Manager to use the KOReader menu."),
            timeout = 3,
        })
        return false
    end
    UIManager:nextTick(function()
        local ok, err = pcall(function()
            if ui.menu and ui.menu.onShowMenu then
                ui.menu:onShowMenu()
                return
            end
            local Event = require("ui/event")
            if ui.handleEvent then
                ui:handleEvent(Event:new("ShowMenu"))
            end
        end)
        if not ok then
            logger.warn("[hansel] KOReader menu:", err)
        end
    end)
    return true
end

return Komenu
