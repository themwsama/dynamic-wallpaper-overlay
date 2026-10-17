# Dynamic Wallpaper Overlay

A live video wallpaper for macOS with an iOS-style glass look, your name in
the corner, a settings gear, and a Spotify-reactive glow with fire sparks and
time-synced lyrics. It's one small native app (Swift + Metal) with no
third-party wallpaper app needed.

- **Any video as your wallpaper**, looping seamlessly, in two looks (original
  and frosted glass) with animated transitions between them
- **Your name and a short description**, crisp at any resolution and anchored
  to every display's corner
- **A gear button** opening a glass control center: clock, wallpaper look,
  transition style, glow, lyrics, romaji
- **Spotify:** the glow pulses with the real beat, colored by the song's genre;
  sparks fly at the song's tempo; lyrics animate in the lower-left
- **Light on resources:** about 200 MB, pauses when the screen sleeps or is
  covered, and caps at 30 fps in Low Power Mode

## Requirements

macOS 26 or newer, Xcode or Command Line Tools (`xcode-select --install`),
and ffmpeg (`brew install ffmpeg`). Spotify desktop is optional.

## Install

```sh
git clone https://github.com/themwsama/dynamic-wallpaper-overlay && cd dynamic-wallpaper-overlay

# Use your own video...
scripts/install.sh --name "YOUR NAME" --subtitle "WHAT YOU DO" --video ~/Movies/loop.mp4 --set-desktop
# ...or start with the generated sample
scripts/install.sh --name "YOUR NAME" --subtitle "WHAT YOU DO" --sample
```

Add `DRY_RUN=1` in front to preview.

**What to expect:** the first install takes 2-3 minutes at high CPU while it
encodes the wallpaper. The encoded wallpaper is about 25 MB. The app build takes
about 15 seconds. The app has no Dock icon; it runs in the background.

macOS will ask for:

- **System Audio Recording Only:** lets the glow follow the beat. Only Spotify
  is listened to, and nothing is recorded.
- **Control Spotify:** reads the current song and its position, so lyrics stay
  in sync.

### Check it's running

```sh
launchctl print gui/$(id -u)/local.wallpaper-overlay | grep state
tail ~/Library/Logs/wallpaper-overlay.log
```

### Using an AI agent?

Point it at [`AGENTS.md`](AGENTS.md). It covers setup questions, install,
permissions, architecture, customization and troubleshooting, written for any
model.

## Customize

- **Text and fonts:** edit `~/.config/wallpaper-overlay/config.json` (see `config.example.json`)
- **Wallpaper:** `scripts/make-wallpaper.sh path/to/video.mp4`
- **Visuals:** `~/.config/wallpaper-overlay/Transition.metal` (live-editable shader)

Then restart with `launchctl kickstart -k gui/$(id -u)/local.wallpaper-overlay`.

## Uninstall

```sh
scripts/uninstall.sh            # add --keep-config to keep your config and wallpaper
```

Other flags: `--yes` skips the confirmation, and `--reset-desktop` resets the
desktop picture if it is the overlay's still frame. Uninstall also removes the
app's preferences file.

## Privacy

Audio never leaves your Mac. What leaves it, and where:

- **iTunes Search** (genre): artist and title.
- **LRCLIB** (lyrics): artist, title, album and duration, plus a User-Agent header.
- **Spotify** (genre, only with keys): the track and artist IDs.
- **Gemini** (genre, only with a key): artist, title and album.
- **Every request** reveals your IP address to the service it goes to.

Song names are written to the local log, which is trimmed automatically. Keys
live in your Keychain.

## License

MIT. Bring your own videos: only use media you have the rights to.
