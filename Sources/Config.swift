// User-editable settings, read once at launch from
// <overlay dir>/config.json (default ~/.config/wallpaper-overlay). Every key is
// optional and validated on its own: a bad value logs a warning and falls
// back to the default for that key only. See config.example.json.
import AppKit

let NIXIE_MAX_CHARACTERS = 12
let CONFIG_KNOWN_KEYS: Set<String> = ["name", "subtitle", "nixieNumber", "nameFont", "subtitleFont", "wallpaperVideo"]

struct OverlayConfig {
    var name = "YOUR NAME"
    var subtitle = "A SHORT DESCRIPTION"
    var nixieNumber = "20.260101"           // ASCII digits and at most one "." (max 12 characters)
    var nameFont = "Didot"
    var subtitleFont = "Baskerville-SemiBold"
    var wallpaperVideoURL: URL              // stacked video from scripts/make-wallpaper.sh

    init(overlayDir: URL = OVERLAY_DIR) {
        wallpaperVideoURL = overlayDir.appendingPathComponent("wallpaper-stacked.mp4")
    }

    static func isValidNixieNumber(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= NIXIE_MAX_CHARACTERS else { return false }
        guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return false }
        return text.filter { $0 == "." }.count <= 1
    }

    nonisolated static func isInstalledFont(_ postScriptName: String) -> Bool {
        NSFont(name: postScriptName, size: 12) != nil
    }

    // Absolute paths and "~" are used as given; relative ones live next to config.json
    static func resolveVideoURL(_ path: String, overlayDir: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return overlayDir.appendingPathComponent(expanded)
    }

    // Applies a decoded JSON object key by key. Never throws: a broken key
    // must not stop the wallpaper from starting
    static func apply(
        _ object: [String: Any], overlayDir: URL = OVERLAY_DIR,
        fontIsInstalled: (String) -> Bool = isInstalledFont,
        warn: (String) -> Void = { NSLog("wallpaper-overlay: %@", $0) }
    ) -> OverlayConfig {
        var config = OverlayConfig(overlayDir: overlayDir)

        for key in object.keys.sorted() where !CONFIG_KNOWN_KEYS.contains(key) {
            warn("config: unknown key \"\(key)\" (known: \(CONFIG_KNOWN_KEYS.sorted().joined(separator: ", ")))")
        }

        func string(_ key: String) -> String? {
            guard let raw = object[key] else { return nil }
            guard let value = raw as? String else {
                warn("config: ignoring \"\(key)\" (expected string)")
                return nil
            }
            return value
        }
        func font(_ key: String, fallback: String) -> String {
            guard let value = string(key) else { return fallback }
            guard fontIsInstalled(value) else {
                warn("config: ignoring \"\(key)\" (font \"\(value)\" is not installed; using \(fallback))")
                return fallback
            }
            return value
        }

        config.name = string("name") ?? config.name
        config.subtitle = string("subtitle") ?? config.subtitle
        config.nameFont = font("nameFont", fallback: config.nameFont)
        config.subtitleFont = font("subtitleFont", fallback: config.subtitleFont)
        if let number = string("nixieNumber") {
            if isValidNixieNumber(number) {
                config.nixieNumber = number
            } else {
                warn("config: ignoring \"nixieNumber\" (digits and at most one \".\", up to \(NIXIE_MAX_CHARACTERS) characters)")
            }
        }
        if let path = string("wallpaperVideo") {
            if path.isEmpty {
                warn("config: ignoring \"wallpaperVideo\" (empty path)")
            } else {
                config.wallpaperVideoURL = resolveVideoURL(path, overlayDir: overlayDir)
            }
        }
        return config
    }

    static func parse(
        _ data: Data, overlayDir: URL = OVERLAY_DIR,
        fontIsInstalled: (String) -> Bool = isInstalledFont,
        warn: (String) -> Void = { NSLog("wallpaper-overlay: %@", $0) }
    ) -> OverlayConfig {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            warn("config: config.json is not valid JSON; using defaults")
            return OverlayConfig(overlayDir: overlayDir)
        }
        guard let object = json as? [String: Any] else {
            warn("config: config.json must be a JSON object; using defaults")
            return OverlayConfig(overlayDir: overlayDir)
        }
        return apply(object, overlayDir: overlayDir, fontIsInstalled: fontIsInstalled, warn: warn)
    }

    // A missing file is normal (all defaults); an unreadable one is logged
    static func load(
        from url: URL = OVERLAY_DIR.appendingPathComponent("config.json"),
        overlayDir: URL = OVERLAY_DIR,
        fontIsInstalled: (String) -> Bool = isInstalledFont,
        warn: (String) -> Void = { NSLog("wallpaper-overlay: %@", $0) }
    ) -> OverlayConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return OverlayConfig(overlayDir: overlayDir) }
        guard let data = try? Data(contentsOf: url) else {
            warn("config: cannot read \(url.path); using defaults")
            return OverlayConfig(overlayDir: overlayDir)
        }
        return parse(data, overlayDir: overlayDir, fontIsInstalled: fontIsInstalled, warn: warn)
    }
}

let CONFIG = OverlayConfig.load()
