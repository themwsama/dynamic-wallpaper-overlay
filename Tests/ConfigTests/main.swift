// Config parsing (per-key tolerance, validation, path resolution), the
// overlay-dir env override and subtitle fitting. Uses temp files only, never
// the real config.
import AppKit

var failed = false
func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failed = true }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("config-tests-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }

let dir = URL(fileURLWithPath: "/tmp/overlay-dir-under-test", isDirectory: true)
let installedFonts: Set<String> = ["Didot", "Baskerville-SemiBold", "Menlo-Regular"]

func parse(_ json: String) -> (config: OverlayConfig, warnings: [String]) {
    var warnings: [String] = []
    let config = OverlayConfig.parse(Data(json.utf8), overlayDir: dir,
                                     fontIsInstalled: { installedFonts.contains($0) },
                                     warn: { warnings.append($0) })
    return (config, warnings)
}
let defaults = OverlayConfig(overlayDir: dir)

// defaults
do {
    let r = parse("{}")
    check("empty object: defaults", r.config.name == defaults.name && r.config.nixieNumber == defaults.nixieNumber && r.warnings.isEmpty)
    check("default video lives in the overlay dir", defaults.wallpaperVideoURL.path == "/tmp/overlay-dir-under-test/wallpaper-stacked.mp4")
}

// good config
do {
    let r = parse(#"{"name":"ADA","subtitle":"ENGINEER","nixieNumber":"18.151210","nameFont":"Menlo-Regular","subtitleFont":"Didot","wallpaperVideo":"/abs/v.mp4"}"#)
    check("full valid config: no warnings", r.warnings.isEmpty)
    check("full valid config: values", r.config.name == "ADA" && r.config.subtitle == "ENGINEER"
          && r.config.nixieNumber == "18.151210" && r.config.nameFont == "Menlo-Regular"
          && r.config.subtitleFont == "Didot" && r.config.wallpaperVideoURL.path == "/abs/v.mp4")
}

// per-key tolerance
do {
    let r = parse(#"{"name":42,"subtitle":"KEPT","nixieNumber":true,"wallpaperVideo":["x"]}"#)
    check("bad name type: default kept", r.config.name == defaults.name)
    check("bad name type: other keys survive", r.config.subtitle == "KEPT")
    check("bad name type: message", r.warnings.contains(#"config: ignoring "name" (expected string)"#))
    check("bad nixie type: message", r.warnings.contains(#"config: ignoring "nixieNumber" (expected string)"#))
    check("bad nixie type: default", r.config.nixieNumber == defaults.nixieNumber)
    check("bad video type: message and default", r.warnings.contains(#"config: ignoring "wallpaperVideo" (expected string)"#)
          && r.config.wallpaperVideoURL == defaults.wallpaperVideoURL)
    let n = parse(#"{"name":null,"subtitle":"S"}"#)
    check("null counts as bad type", n.config.name == defaults.name && n.config.subtitle == "S"
          && n.warnings.contains(#"config: ignoring "name" (expected string)"#))
}

// unknown keys
do {
    let r = parse(#"{"subtitel":"typo","name":"OK"}"#)
    check("unknown key warned", r.warnings.contains { $0.contains(#"unknown key "subtitel""#) })
    check("unknown key does not break known", r.config.name == "OK" && r.config.subtitle == defaults.subtitle)
}

// fonts
do {
    let r = parse(#"{"nameFont":"NoSuchFont","subtitleFont":"AlsoMissing"}"#)
    check("missing nameFont falls back", r.config.nameFont == defaults.nameFont)
    check("missing subtitleFont falls back", r.config.subtitleFont == defaults.subtitleFont)
    check("missing font warned", r.warnings.filter { $0.contains("is not installed") }.count == 2)
    check("real system lookup: Helvetica installed", OverlayConfig.isInstalledFont("Helvetica"))
    check("real system lookup: nonsense not installed", !OverlayConfig.isInstalledFont("Definitely-Not-A-Font-123"))
}

// nixieNumber
do {
    for good in ["0", "20.260101", "123456789012", "1.", ".5", "12345678901."] {
        check("nixie accepts \(good)", OverlayConfig.isValidNixieNumber(good))
    }
    for bad in ["", "1234567890123", "1.2.3", "abc", "12 34", "-5", "١٢٣", "1e5", "½", "1,5", "123456789012."] {
        check("nixie rejects \(bad.debugDescription)", !OverlayConfig.isValidNixieNumber(bad))
    }
    let r = parse(#"{"nixieNumber":"1.2.3"}"#)
    check("bad nixie: default and warning", r.config.nixieNumber == defaults.nixieNumber
          && r.warnings.contains { $0.hasPrefix(#"config: ignoring "nixieNumber""#) })
}

// wallpaperVideo resolution
do {
    check("relative video resolves against overlay dir",
          parse(#"{"wallpaperVideo":"clips/a.mp4"}"#).config.wallpaperVideoURL.path == "/tmp/overlay-dir-under-test/clips/a.mp4")
    check("tilde video expands",
          parse(#"{"wallpaperVideo":"~/v.mp4"}"#).config.wallpaperVideoURL.path == NSHomeDirectory() + "/v.mp4")
    check("absolute video untouched",
          parse(#"{"wallpaperVideo":"/Volumes/x/v.mp4"}"#).config.wallpaperVideoURL.path == "/Volumes/x/v.mp4")
    let e = parse(#"{"wallpaperVideo":""}"#)
    check("empty video path: default and warning", e.config.wallpaperVideoURL == defaults.wallpaperVideoURL && !e.warnings.isEmpty)
}

// malformed input
do {
    let bad = parse("{ not json")
    check("invalid JSON: defaults and warning", bad.config.name == defaults.name && bad.warnings.count == 1)
    let arr = parse("[1,2]")
    check("non-object root: defaults and warning", arr.config.name == defaults.name && arr.warnings.count == 1)
}

// load from files
do {
    var warnings: [String] = []
    let missing = OverlayConfig.load(from: root.appendingPathComponent("absent.json"), overlayDir: dir,
                                     fontIsInstalled: { _ in true }, warn: { warnings.append($0) })
    check("missing file: defaults, silent", missing.name == defaults.name && warnings.isEmpty)

    let file = root.appendingPathComponent("config.json")
    try! #"{"name":"FROM FILE","subtitle":5,"wallpaperVideo":"v.mp4"}"#.write(to: file, atomically: true, encoding: .utf8)
    let loaded = OverlayConfig.load(from: file, overlayDir: root, fontIsInstalled: { _ in true }, warn: { warnings.append($0) })
    check("file: good keys applied", loaded.name == "FROM FILE")
    check("file: bad key ignored with message", loaded.subtitle == defaults.subtitle
          && warnings == [#"config: ignoring "subtitle" (expected string)"#])
    check("file: relative video against given dir", loaded.wallpaperVideoURL.path == root.appendingPathComponent("v.mp4").path)
}

// OVERLAY_DIR from the environment
do {
    check("overlay dir default", resolveOverlayDir(env: [:]).path == NSHomeDirectory() + "/.config/wallpaper-overlay")
    check("overlay dir empty env uses default", resolveOverlayDir(env: ["WALLPAPER_OVERLAY_DIR": ""]).path == NSHomeDirectory() + "/.config/wallpaper-overlay")
    check("overlay dir absolute", resolveOverlayDir(env: ["WALLPAPER_OVERLAY_DIR": "/opt/overlay"]).path == "/opt/overlay")
    check("overlay dir tilde expanded", resolveOverlayDir(env: ["WALLPAPER_OVERLAY_DIR": "~/custom"]).path == NSHomeDirectory() + "/custom")
}

// subtitle fitting
do {
    let font = NSFont.systemFont(ofSize: 29)
    func plain(_ t: String, _ f: NSFont) -> CGFloat { tracked(t, font: f, tracking: 0, color: .white).size().width }

    let short = subtitleLayout(text: "HELLO", font: font, available: 400)
    check("short subtitle: spaced out, not shrunk", short.tracking > 0 && !short.isShrunk && !short.overflows)
    check("short subtitle: spans the width",
          abs(plain("HELLO", short.font) + short.tracking * 4 - 400) < 0.5)

    let single = subtitleLayout(text: "A", font: font, available: 400)
    check("one character: no tracking, no crash", single.tracking == 0)
    let none = subtitleLayout(text: "", font: font, available: 400)
    check("empty text: no tracking, no crash", none.tracking == 0 && !none.overflows)

    let text = "A MUCH LONGER SUBTITLE THAT DOES NOT FIT"
    let natural = plain(text, font)
    let mild = subtitleLayout(text: text, font: font, available: natural * 0.8)
    check("slightly too wide: shrinks to fit", mild.isShrunk && !mild.overflows && mild.tracking >= 0
          && mild.font.pointSize < font.pointSize && mild.font.pointSize >= font.pointSize * SUB_MIN_FONT_SCALE)
    let extreme = subtitleLayout(text: text, font: font, available: natural * 0.3)
    check("far too wide: stops at 60% and overflows", extreme.overflows && extreme.tracking == 0
          && abs(extreme.font.pointSize - font.pointSize * SUB_MIN_FONT_SCALE) < 0.01)
    let negative = subtitleLayout(text: text, font: font, available: -50)
    check("negative width: tracking clamped to zero", negative.tracking == 0 && negative.overflows)
}

if failed { exit(1) }
print("ALL PASS")
