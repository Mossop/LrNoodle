return {
  LrSdkVersion = 16.0,
  LrSdkMinimumVersion = 16.0,

  LrToolkitIdentifier = "org.pixelbin.lrnoodle-dev",

  LrPluginName = LOC("$$$/LrNoodle/PluginName=LrNoodle-Dev"),
  LrPluginInfoUrl = "https://pixelbin.org",

  LrPluginInfoProvider = "PluginInfo.lua",

  LrExportServiceProvider = {
    title = LOC("$$$/LrNoodle/ServiceTitle=Noodle Gallery"),
    file = "Provider.lua",
  },

  VERSION = { major = 0, minor = 1, revision = 0, build = 0 },
}
