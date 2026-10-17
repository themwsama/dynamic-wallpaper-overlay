// Shared look and layout constants for the desktop overlay. Personal text
// and the wallpaper path come from config.json (see Config.swift).
import AppKit

let NAME_TEXT = CONFIG.name
let SUB_TEXT = CONFIG.subtitle
let NAME_FONT = NSFont(name: CONFIG.nameFont, size: 104) ?? .systemFont(ofSize: 104)
let NAME_TRACKING: CGFloat = 26
// Didot's hairlines break up at small sizes, so the subtitle uses Baskerville
let SUB_FONT = NSFont(name: CONFIG.subtitleFont, size: 29) ?? .systemFont(ofSize: 29)
let MARGIN_RIGHT: CGFloat = 96
let MARGIN_TOP: CGFloat = 64  // measured from below the menu bar
let RULE_GAP: CGFloat = 22
let RULE_WIDTH: CGFloat = 1.5
let SUB_GAP: CGFloat = 20
let BLOCK_PADDING: CGFloat = 30  // room around the text so the shadow blur isn't clipped
let TEXT_COLOR = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.93, alpha: 0.92)
let RULE_COLOR = TEXT_COLOR.withAlphaComponent(0.6)
let GLOW_COLOR = NSColor(srgbRed: 0.78, green: 0.84, blue: 1.0, alpha: 0.45)
let SHADOW_COLOR = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.12, alpha: 0.6)

// Clock widget
let CLOCK_GAP: CGFloat = 26  // between the subtitle and the glass card
let CLOCK_FADE_DURATION: TimeInterval = 0.25

// Gear button at the end of the subtitle row, and the control center it opens
let GEAR_SIZE: CGFloat = 30
let GEAR_GAP: CGFloat = 16  // between the subtitle text and the gear
let GEAR_CORNER_RADIUS: CGFloat = 9
let GEAR_SYMBOL_NAME = "gearshape"
let PANEL_GAP: CGFloat = 14  // between the subtitle row and the panel
let PANEL_COLUMNS = 4
let PANEL_PADDING: CGFloat = 16
let PANEL_HEADER_HEIGHT: CGFloat = 30
let PANEL_CORNER_RADIUS: CGFloat = 26
let PANEL_RISE: CGFloat = 10  // the panel settles up into place as it fades in
let PANEL_ANIMATION_DURATION: TimeInterval = 0.28
let PANEL_HEADER_FONT = NSFont(name: "Baskerville-SemiBold", size: 13) ?? .systemFont(ofSize: 13)
let TILE_SIZE = NSSize(width: 76, height: 80)
let TILE_GAP: CGFloat = 10
let TILE_CORNER_RADIUS: CGFloat = 18
let TILE_ICON_SIZE: CGFloat = 19
let TILE_LABEL_FONT = NSFont.systemFont(ofSize: 11, weight: .medium)
let TILE_ON_INK = NSColor(srgbRed: 0.11, green: 0.14, blue: 0.25, alpha: 1)

// Video backdrop: original animation and the glass version, with animated
// transitions between them (see Transition.metal)
let OVERLAY_DIR_ENV = "WALLPAPER_OVERLAY_DIR"
let DEFAULT_OVERLAY_DIR = "~/.config/wallpaper-overlay"

// The install script exports WALLPAPER_OVERLAY_DIR to the LaunchAgent when the
// user picked a non-default directory; unset or empty means the default
func resolveOverlayDir(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    let raw = env[OVERLAY_DIR_ENV].flatMap { $0.isEmpty ? nil : $0 } ?? DEFAULT_OVERLAY_DIR
    return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
}

let OVERLAY_DIR = resolveOverlayDir()
let BACKDROP_VIDEO_URL = CONFIG.wallpaperVideoURL
let TRANSITION_SHADER_URL = OVERLAY_DIR.appendingPathComponent("Transition.metal")
let VIDEO_SIZE = NSSize(width: 2560, height: 1440)  // one half of the stacked file
let CROSSFADE_DURATION: CFTimeInterval = 0.9
let STORM_REWIND_DURATION: CFTimeInterval = 1.8
let WORLD_LINE_SHIFT_DURATION: CFTimeInterval = 1.4
let WORLD_LINE_2_DURATION: CFTimeInterval = 3.3
let IDLE_FPS = 30  // the video's own frame rate
let TRANSITION_FPS = 60
// Shown on the nixie tubes in the world-line shift transition
let DIVERGENCE_TEXT = CONFIG.nixieNumber
let NIXIE_FONT = NSFont.systemFont(ofSize: 112, weight: .light)
let NIXIE_GLOW_SIGMA: Double = 7
let NIXIE_GLOW_GAIN = 2
let EFFECTS_SYMBOL_SIZE: CGFloat = 13  // SF Symbols in GlassButton (the gear)
let CLOCK_HEIGHT: CGFloat = 158
let CLOCK_CORNER_RADIUS: CGFloat = 24
let CLOCK_DIGIT_FONT = NSFont.monospacedDigitSystemFont(ofSize: 54, weight: .thin)
let CLOCK_LABEL_FONT = NSFont(name: "Baskerville-SemiBold", size: 12) ?? .systemFont(ofSize: 12)
let CLOCK_LABEL_TRACKING: CGFloat = 3
let CLOCK_FINISHED_COLOR = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.6, alpha: 0.95)
let CLOCK_TICK_INTERVAL: TimeInterval = 0.05
let TIMER_DEFAULT_MINUTES = 25
let TIMER_MAX_MINUTES = 99
let FINISH_SOUND_NAME = "Glass"
let FINISH_SOUND_REPEATS = 3

// Text sits above the video wallpaper (desktop level) but below the icons.
// The clock must take clicks, so it sits just above the icons (where macOS
// desktop widgets live) - still below every normal app window.
let TEXT_LEVEL = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 3)
// Our own video sits over dynamicwallpaper.app's, under the text
let BACKDROP_LEVEL = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 2)
let CLOCK_LEVEL = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
let PANEL_LEVEL = NSWindow.Level(rawValue: CLOCK_LEVEL.rawValue + 1)

func tracked(_ text: String, font: NSFont, tracking: CGFloat, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: font, .kern: tracking, .foregroundColor: color])
}

// Width without the trailing kern AppKit adds after the last character
func visibleWidth(_ s: NSAttributedString, tracking: CGFloat) -> CGFloat {
    s.size().width - tracking
}
