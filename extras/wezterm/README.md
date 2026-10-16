# Optional: matching glass terminal (WezTerm)

A WezTerm config with the same frosted-glass look as the wallpaper: macOS
window blur, a dimmed looping background, and the same blue/purple gradient
tint the overlay uses.

1. Install WezTerm: `brew install --cask wezterm`
2. Make a small looping GIF from any clip (WezTerm can't play video):
   ```sh
   mkdir -p ~/.config/wezterm/backgrounds
   ffmpeg -i your-clip.mp4 -t 8 -vf "fps=15,scale=1280:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
     ~/.config/wezterm/backgrounds/background.gif
   ```
3. Copy the config (back up any existing one first): `cp wezterm.lua ~/.wezterm.lua`

`Cmd+,` opens the config from inside WezTerm.
