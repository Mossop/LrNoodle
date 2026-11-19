local LrPrefs = import("LrPrefs")
local LrView = import("LrView")

local bind = LrView.bind

local PluginInfo = {}

---@param f LrViewFactory
---@param propertyTable table
---@return table[]
function PluginInfo.sectionsForTopOfDialog(f, propertyTable) -- luacheck: ignore propertyTable
  local prefs = LrPrefs.prefsForPlugin()

  return {
    {
      title = LOC("$$$/LrNoodle/PluginInfo/Title=Noodle Gallery"),

      f:row({
        bind_to_object = prefs,

        f:checkbox({
          title = LOC("$$$/LrNoodle/PluginInfo/DebugLogging=Enable debug logging"),
          tooltip = LOC(
            "$$$/LrNoodle/PluginInfo/DebugLogging/Tooltip=Log details of every publish to help diagnose problems. "
              .. "Otherwise only warnings and errors are logged."
          ),
          value = bind("debugLogging"),
          checked_value = true,
          unchecked_value = false,
        }),
      }),
    },
  }
end

return PluginInfo
