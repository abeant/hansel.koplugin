--[[--
hansel.koplugin — server-first home screen for KOReader.

Registers Start with → Hansel, takes over the File Manager on launch when
configured, and talks to Grimmory over OPDS (Tier 1) plus optional login
(Tier 2).
]]

local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local CacheMap = require("lib.cache_map")
local Migrate = require("lib.migrate")
local Paths = require("lib.paths")
local ProgressSync = require("lib.progress_sync")
local Settings = require("lib.settings")

local START_WITH = "hansel"

local Hansel = WidgetContainer:extend{
    name = "hansel",
    is_doc_only = false,
}

local _live
local _did_initial_takeover = false

local function close_touch_menu(touchmenu_instance)
    if touchmenu_instance and touchmenu_instance.closeMenu then
        touchmenu_instance:closeMenu()
    end
end

local function wants_start_with()
    local value = G_reader_settings:readSetting("start_with")
    return value == START_WITH or value == "dork"
end

function Hansel:init()
    Migrate.all()
    Paths.ensure_data_dirs()
    Settings.load()
    UIManager:nextTick(function()
        pcall(function()
            local _, moved = Paths.migrate_into_library()
            if type(moved) == "table" then
                for id, path in pairs(moved) do
                    CacheMap.record_download(id, path, nil, { owned = true })
                end
            end
            CacheMap.rebuild_by_hash()
        end)
        if Settings.get("auto_sync_enabled") then
            ProgressSync.on_network_connected()
        end
    end)

    self:_registerStartWithMenu()
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
    self:onDispatcherRegisterActions()

    if wants_start_with()
            and not (self.ui and self.ui.document)
            and not _did_initial_takeover then
        _did_initial_takeover = true
        UIManager:nextTick(function()
            self:show()
        end)
    end
end

function Hansel:_registerStartWithMenu()
    local plugin = self
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu then
        logger.dbg("[hansel] FileManagerMenu not available")
        return
    end
    if type(FMMenu.getStartWithMenuTable) ~= "function" then
        logger.dbg("[hansel] getStartWithMenuTable missing")
        return
    end
    if FMMenu._hansel_patched then return end
    FMMenu._hansel_patched = true
    local orig_fn = FMMenu.getStartWithMenuTable
    FMMenu.getStartWithMenuTable = function(self_fm)
        local result = orig_fn(self_fm)
        if type(result) ~= "table" or type(result.sub_item_table) ~= "table" then
            return result
        end
        for i, entry in ipairs(result.sub_item_table) do
            local orig_cb = entry.callback
            entry.callback = function(touchmenu_instance, ...)
                if orig_cb then orig_cb(touchmenu_instance, ...) end
                if _live and UIManager:isWidgetShown(_live) then
                    UIManager:close(_live)
                    close_touch_menu(touchmenu_instance)
                end
            end
        end
        local already
        for i, entry in ipairs(result.sub_item_table) do
            if entry.text == _("Hansel") or entry._hansel then
                already = true
                break
            end
        end
        if not already then
            table.insert(result.sub_item_table, {
                _hansel = true,
                text = _("Hansel"),
                radio = true,
                checked_func = function()
                    return wants_start_with()
                end,
                callback = function(touchmenu_instance)
                    G_reader_settings:saveSetting("start_with", START_WITH)
                    G_reader_settings:flush()
                    close_touch_menu(touchmenu_instance)
                    if plugin.show then plugin:show() end
                end,
            })
        end
        local orig_text_func = result.text_func
        result.text_func = function()
            if wants_start_with() then
                return T(_("Start with: %1"), _("Hansel"))
            end
            return orig_text_func and orig_text_func() or ""
        end
        return result
    end
end

function Hansel:onDispatcherRegisterActions()
    Dispatcher:registerAction("hansel_show", {
        category = "none",
        event = "ShowHansel",
        title = _("Show Hansel"),
        general = true,
        filemanager = true,
    })
    -- One-release alias so existing dork_show gesture mappings keep working.
    -- Not listed in Gesture Manager (no general/filemanager flags).
    Dispatcher:registerAction("dork_show", {
        category = "none",
        event = "ShowHansel",
        title = _("Show Hansel"),
    })
end

function Hansel:onShowHansel()
    self:show()
    return true
end

function Hansel:onDorkShow()
    return self:onShowHansel()
end

function Hansel:addToMainMenu(menu_items)
    menu_items.hansel = {
        text = _("Hansel"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                {
                    text = _("Show library"),
                    callback = function()
                        self:show()
                    end,
                },
                {
                    text = _("Dashboard"),
                    radio = true,
                    checked_func = function()
                        return _live and _live.view == "dashboard"
                    end,
                    callback = function()
                        self:show()
                        if _live then _live:set_view("dashboard") end
                    end,
                },
                {
                    text = _("All Books"),
                    radio = true,
                    checked_func = function()
                        return _live and (_live.view == "all" or not _live.view)
                    end,
                    callback = function()
                        self:show()
                        if _live then _live:set_view("all") end
                    end,
                },
                {
                    text = _("Hansel settings"),
                    callback = function()
                        self:show()
                        require("ui.settings").show(_live)
                    end,
                },
                {
                    text = _("Close Hansel"),
                    callback = function()
                        if _live then _live:onClose() end
                    end,
                },
            }
        end,
    }
end

function Hansel:show()
    if _live and UIManager:isWidgetShown(_live) then
        self._widget = _live
        return
    end
    local Home = require("ui.home")
    local widget
    widget = Home:new{
        plugin = self,
        _on_close = function()
            if _live == widget then _live = nil end
            self._widget = nil
        end,
    }
    self._widget = widget
    _live = widget
    UIManager:show(widget)
    if not Settings.can_browse() then
        UIManager:nextTick(function()
            require("ui.setup").confirm_if_needed(function()
                if _live then _live:reload() end
            end, _live)
        end)
    end
end

function Hansel:open_book(book, path)
    if not path then return end
    CacheMap.set_open_path(path)
    if book and book.id then
        CacheMap.mark_opened(book.id, path)
    end
    if _live then
        UIManager:close(_live)
    end
    local FileManager = require("apps/filemanager/filemanager")
    local ReaderUI = require("apps/reader/readerui")
    if self.ui and self.ui.document then
        self.ui:switchDocument(path)
    elseif FileManager.instance and FileManager.instance.openFile then
        FileManager.instance:openFile(path)
    else
        ReaderUI:showReader(path)
    end
end

function Hansel:onReaderReady()
    ProgressSync.on_reader_ready(self.ui)
end

function Hansel:onPageUpdate(page)
    ProgressSync.on_page_update(page)
end

function Hansel:onSuspend()
    ProgressSync.on_suspend()
end

function Hansel:onNetworkConnected()
    ProgressSync.on_network_connected()
end

function Hansel:onCloseDocument()
    ProgressSync.on_close_document()
    CacheMap.set_open_path(nil)
    if wants_start_with() then
        UIManager:nextTick(function()
            self:show()
        end)
    end
end

function Hansel:onShow()
    if not wants_start_with() then return end
    if self.ui and self.ui.document then return end
    if _live and UIManager:isWidgetShown(_live) then return end
    self:show()
end

return Hansel
