// User-editable settings, read once at launch from
// ~/.config/wallpaper-overlay/config.json. Every key is optional; missing
// keys fall back to the defaults below. See config.example.json.
import Foundation

struct OverlayConfig: Decodable {
    var name = "YOUR NAME"
    var subtitle = "A SHORT DESCRIPTION"
    var nixieNumber = "20.260101"           // digits and one "." (max 12 characters)
    var nameFont = "Didot"
    var subtitleFont = "Baskerville-SemiBold"
    var wallpaperVideo: String?             // stacked video from scripts/make-wallpaper.sh

    var wallpaperVideoURL: URL {
        guard let path = wallpaperVideo, !path.isEmpty else {
            return OVERLAY_DIR.appendingPathComponent("wallpaper-stacked.mp4")
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = OverlayConfig()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? fallback.name
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? fallback.subtitle
        nixieNumber = try c.decodeIfPresent(String.self, forKey: .nixieNumber) ?? fallback.nixieNumber
        nameFont = try c.decodeIfPresent(String.self, forKey: .nameFont) ?? fallback.nameFont
        subtitleFont = try c.decodeIfPresent(String.self, forKey: .subtitleFont) ?? fallback.subtitleFont
        wallpaperVideo = try c.decodeIfPresent(String.self, forKey: .wallpaperVideo)
    }

    private enum CodingKeys: String, CodingKey {
        case name, subtitle, nixieNumber, nameFont, subtitleFont, wallpaperVideo
    }

    // A broken config must never stop the wallpaper from starting
    static func load(from url: URL = OVERLAY_DIR.appendingPathComponent("config.json")) -> OverlayConfig {
        guard let data = try? Data(contentsOf: url) else { return OverlayConfig() }
        do {
            return try JSONDecoder().decode(OverlayConfig.self, from: data)
        } catch {
            NSLog("wallpaper-overlay: config.json ignored (%@); using defaults", "\(error)")
            return OverlayConfig()
        }
    }
}

let CONFIG = OverlayConfig.load()
