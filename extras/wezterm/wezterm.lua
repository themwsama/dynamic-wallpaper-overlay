-- WezTerm config: iOS-style frosted glass look
local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- Glass effect: macOS blur shows through the translucent layers below
config.macos_window_background_blur = 40

-- Layered background (replaces window_background_opacity/gradient, which
-- WezTerm ignores once config.background is set):
--   1. animated video loop, dimmed so text stays readable
--   2. the soft blue/purple gradient as a frosted tint on top
-- WezTerm can't play video, so convert a clip to a GIF first (see README.md here)
config.background = {
  {
    source = { File = wezterm.home_dir .. "/.config/wezterm/backgrounds/background.gif" },
    width = "Cover",
    height = "Cover",
    horizontal_align = "Center",
    vertical_align = "Middle",
    opacity = 0.25,
    hsb = { brightness = 0.45, saturation = 0.9 },
  },
  {
    source = {
      Gradient = {
        orientation = { Linear = { angle = -45.0 } },
        colors = { "#1c2340", "#2a1f3d", "#1a2a3a" },
        interpolation = "CatmullRom",
        blend = "Oklab",
      },
    },
    width = "100%",
    height = "100%",
    opacity = 0.55,
  },
}

-- Keep the window's pixel size fixed when the DPI/font size changes. The
-- built-in Retina display (2x) and the external monitor (1x) have different
-- scales; without this, dragging the window between them makes WezTerm resize
-- it to keep rows/cols, which pushes it back across the edge and loops
config.adjust_window_size_when_changing_font_size = false

-- Clean, rounded-feeling chrome
config.window_decorations = "RESIZE|INTEGRATED_BUTTONS"
config.window_padding = { left = 18, right = 18, top = 14, bottom = 10 }
config.use_fancy_tab_bar = true
-- Keep tab bar visible: INTEGRATED_BUTTONS draws the traffic lights inside it,
-- so hiding it makes the buttons overlap the terminal text
config.hide_tab_bar_if_only_one_tab = false
config.window_frame = {
  font = wezterm.font({ family = "Helvetica Neue", weight = "Medium" }),
  font_size = 12.0,
  active_titlebar_bg = "#1c2340",
  inactive_titlebar_bg = "#1c2340",
}

-- Text
config.font = wezterm.font_with_fallback({ "JetBrains Mono", "Menlo" })
config.font_size = 14.0
config.color_scheme = "Catppuccin Mocha"
config.colors = {
  cursor_bg = "#a6c8ff",
  cursor_border = "#a6c8ff",
  selection_bg = "rgba(120, 160, 255, 0.35)",
}
config.default_cursor_style = "BlinkingBar"

-- Quick access to this config file
local function open_config(window, pane)
  window:perform_action(
    wezterm.action.SpawnCommandInNewTab({ args = { "/usr/bin/nano", wezterm.config_file } }),
    pane
  )
end

-- Right-click the "+" tab button to open the config
wezterm.on("new-tab-button-click", function(window, pane, button)
  if button == "Right" then
    open_config(window, pane)
    return false
  end
end)

-- Also listed in the command palette (Cmd+Shift+P)
wezterm.on("augment-command-palette", function()
  return {
    { brief = "Open WezTerm config", icon = "md_cog", action = wezterm.action_callback(open_config) },
  }
end)

-- Cmd+, opens the config, like Settings in other macOS apps
config.keys = {
  { key = ",", mods = "CMD", action = wezterm.action_callback(open_config) },
  -- Cmd+Shift+T opens a new tab running Claude Code; quitting Claude
  -- leaves a normal shell in the tab instead of closing it
  {
    key = "t",
    mods = "CMD|SHIFT",
    action = wezterm.action.SpawnCommandInNewTab({
      args = { os.getenv("SHELL") or "/bin/zsh", "-lic", "claude; exec $SHELL -l" },
    }),
  },
}

return config
