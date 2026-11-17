// The mini TV's video list, kept in mini-tv-playlist.json in the overlay
// folder so videos can be added and removed at runtime. Values are immutable:
// adding/removing returns a new playlist.
import Foundation

nonisolated struct MiniTVVideo: Codable, Equatable, Sendable {
    let file: String         // a bare file name inside the overlay folder
    let title: String
    let youtubeID: String?   // set for videos added from a YouTube link
}

nonisolated struct MiniTVPlaylist: Codable, Equatable, Sendable {
    static let fileName = "mini-tv-playlist.json"
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    let videos: [MiniTVVideo]

    // Only plain names of playable files: no paths, no hidden files
    static func isSafeFileName(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        return !name.contains("/") && !name.hasPrefix(".") && !stem.isEmpty
            && videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func title(fromFileName name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    // Missing file: start from `seed`. Unreadable or undecodable file: move it
    // aside as `.broken-<time>` (so a later save can't destroy it) and start
    // from `seed`. Earlier `.broken` copies are never overwritten.
    static func load(from directory: URL, seed: [String]) -> MiniTVPlaylist {
        let url = directory.appendingPathComponent(fileName)
        let seeded = MiniTVPlaylist(videos: seed.filter(isSafeFileName).map {
            MiniTVVideo(file: $0, title: title(fromFileName: $0), youtubeID: nil)
        })
        guard FileManager.default.fileExists(atPath: url.path) else { return seeded }
        do {
            let decoded = try JSONDecoder().decode(MiniTVPlaylist.self, from: Data(contentsOf: url))
            let safe = decoded.videos.filter { isSafeFileName($0.file) }
            decoded.videos.filter { !isSafeFileName($0.file) }.forEach {
                NSLog("wallpaper-overlay: skipping mini TV entry %@ (not a plain .mp4/.mov/.m4v name)", $0.file)
            }
            return MiniTVPlaylist(videos: safe)
        } catch {
            setAside(url, in: directory, reason: error)
            return seeded
        }
    }

    private static func setAside(_ url: URL, in directory: URL, reason: Error) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let suffix = UUID().uuidString.prefix(4)
        let broken = directory.appendingPathComponent("\(fileName).broken-\(stamp)-\(suffix)")
        NSLog("wallpaper-overlay: %@ is unreadable (%@); moved to %@", url.path, "\(reason)", broken.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: url, to: broken)
        } catch {
            NSLog("wallpaper-overlay: couldn't move the broken playlist aside: %@", "\(error)")
        }
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    // An entry for an existing file replaces it in place; otherwise appends
    func adding(_ video: MiniTVVideo) -> MiniTVPlaylist {
        guard let index = videos.firstIndex(where: { $0.file == video.file }) else {
            return MiniTVPlaylist(videos: videos + [video])
        }
        return MiniTVPlaylist(videos: videos.enumerated().map { $0.offset == index ? video : $0.element })
    }

    func removing(file: String) -> MiniTVPlaylist {
        MiniTVPlaylist(videos: videos.filter { $0.file != file })
    }

    func contains(youtubeID: String) -> Bool {
        videos.contains { $0.youtubeID == youtubeID }
    }

    func urls(in directory: URL) -> [URL] {
        videos.map { directory.appendingPathComponent($0.file) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
