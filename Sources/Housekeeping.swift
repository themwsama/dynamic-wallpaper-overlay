// Periodic cleanup of the two files the overlay grows forever: the lyrics cache and the launchd log.
import Foundation

let HOUSEKEEPING_INTERVAL: TimeInterval = 6 * 3600
let LYRICS_CACHE_MAX_AGE: TimeInterval = 60 * 24 * 3600
let LYRICS_CACHE_MAX_FILES = 400
let LOG_MAX_BYTES = 2_000_000
let LOG_KEEP_BYTES = 500_000

let LOG_PATH_ENV = "WALLPAPER_OVERLAY_LOG"
let DEFAULT_LOG_PATH = "~/Library/Logs/wallpaper-overlay.log"

// Same path the LaunchAgent's StandardErrorPath points at (install.sh exports it)
func resolveLogURL(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    let raw = env[LOG_PATH_ENV].flatMap { $0.isEmpty ? nil : $0 } ?? DEFAULT_LOG_PATH
    return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
}

enum Housekeeping {
    static let cacheDirectory = OVERLAY_DIR.appendingPathComponent("lyrics-cache", isDirectory: true)
    static let logURL = resolveLogURL()

    // Returns the number of files deleted
    static func pruneCache(directory: URL, maxAge: TimeInterval, maxFiles: Int, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }

        var entries: [(url: URL, modified: Date)] = []
        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            entries.append((url, modified))
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        let expired = entries.filter { $0.modified < cutoff }
        let survivors = entries.filter { $0.modified >= cutoff }.sorted { $0.modified > $1.modified }
        let overflow = survivors.dropFirst(max(0, maxFiles))

        var deleted = 0
        for entry in expired + Array(overflow) {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { deleted += 1 }
        }
        return deleted
    }

    // Truncates in place: launchd holds an append-mode descriptor, so a rename would orphan it
    static func trimLog(at url: URL, maxBytes: Int, keepBytes: Int) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        do {
            let size = Int(try handle.seekToEnd())
            guard size > maxBytes else { return false }
            let start = max(0, size - max(0, keepBytes))
            try handle.seek(toOffset: UInt64(start))
            let tail = try handle.readToEnd() ?? Data()
            // Drop the partial first line; no newline at all means nothing safe to keep
            let kept = tail.firstIndex(of: 0x0A).map { Data(tail[tail.index(after: $0)...]) } ?? Data()
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: kept)
            return true
        } catch {
            NSLog("wallpaper-overlay: housekeeping log trim failed: %@", error.localizedDescription)
            return false
        }
    }

    static func runAll() {
        let deleted = pruneCache(directory: cacheDirectory, maxAge: LYRICS_CACHE_MAX_AGE, maxFiles: LYRICS_CACHE_MAX_FILES)
        let trimmed = trimLog(at: logURL, maxBytes: LOG_MAX_BYTES, keepBytes: LOG_KEEP_BYTES)
        guard deleted > 0 || trimmed else { return }
        NSLog("wallpaper-overlay: housekeeping removed %d cache files, log trimmed: %@", deleted, trimmed ? "yes" : "no")
    }

    static func schedule() -> Timer {
        runAll()
        let timer = Timer(timeInterval: HOUSEKEEPING_INTERVAL, repeats: true) { _ in runAll() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
