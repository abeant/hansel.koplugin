local _ = require("gettext")
return {
    -- KEEP `name` equal to the .koplugin directory id ("hansel").
    -- PluginLoader loads a DISABLED plugin from _meta.lua, not main.lua,
    -- and the enable toggle keys plugins_disabled by that name.
    name = "hansel",
    fullname = _("Hansel"),
    description = _([[A server-first home screen for KOReader. Grimmory is the library; the device holds a cache.]]),
    version = "0.3.0",
    repository = "abeant/hansel.koplugin",
}
