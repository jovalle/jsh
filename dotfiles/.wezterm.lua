local wezterm = require("wezterm")
local config = wezterm.config_builder()

config.color_scheme = "Dark+"
config.enable_kitty_keyboard = true
config.enable_tab_bar = false
config.font = wezterm.font("JetBrains Mono", { weight = "Bold" })
config.font_size = 12
config.keys = {
  {
    action = wezterm.action.CloseCurrentTab({ confirm = false }),
    key = "w",
    mods = "CMD",
  },
}
config.window_close_confirmation = "NeverPrompt"
config.window_decorations = "RESIZE"

return config
