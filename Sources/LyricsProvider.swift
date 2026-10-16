// Fetches time-synced lyrics from LRCLIB (free, no key) and caches them on disk,
// one JSON file per track ID. Only artist, title, album and duration are sent.
// Nothing here is ever logged except status codes and error descriptions.
import Foundation

let LRCLIB_BASE_URL = "https://lrclib.net/api"
let LRCLIB_USER_AGENT = "Dynamic Wallpaper Overlay/1.0 (personal desktop wallpaper)"
let LYRICS_REQUEST_TIMEOUT: TimeInterval = 8
// "Not found" is remembered this long, then asked again
let LYRICS_NEGATIVE_CACHE_TTL: TimeInterval = 7 * 24 * 3600
// A search hit counts as the same recording when its length is this close
let LYRICS_DURATION_TOLERANCE: TimeInterval = 3
let LYRICS_LAST_LINE_FALLBACK_LENGTH: TimeInterval = 5
// Bumped to 2 when get-without-synced started falling through to search; version 1
// negative entries may be wrong and are ignored
let LYRICS_CACHE_VERSION = 2
// Waits before the 2nd and 3rd attempt of a request that failed transiently
let LYRICS_RETRY_DELAYS: [TimeInterval] = [1.5, 4]
let LYRICS_CACHE_NAME_MAX = 80

struct LyricWord: Codable, Equatable { let start: TimeInterval; let text: String }

struct LyricLine: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String  // "" marks an instrumental gap
    let words: [LyricWord]?
}

struct TimedLyrics: Codable, Equatable {
    let lines: [LyricLine]

    // Index of the line whose [start, end) holds the position; nil before the
    // first line, after the last, or in a hole
    func lineIndex(at position: TimeInterval) -> Int? {
        var low = 0
        var high = lines.count  // first line that starts after position
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].start <= position { low = mid + 1 } else { high = mid }
        }
        let index = low - 1
        guard index >= 0, position < lines[index].end else { return nil }
        return index
    }
}

private struct LyricsCacheEntry: Codable {
    let version: Int
    let fetchedAt: Date
    let lyrics: TimedLyrics?  // nil = looked up, nothing available
}

private struct LRCLibTrack: Decodable {
    let artistName: String?
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?
    let plainLyrics: String?
}

private enum HTTPResult {
    case ok(Data), notFound, failed
    case retryable  // 5xx, 429, timeouts and other transport errors
}

private enum ExactOutcome {
    case found(TimedLyrics), instrumental, needsSearch, failed
}

// `failed` is transient (network, LRCLIB overloaded): ask again later, it's not an answer
enum LookupOutcome {
    case found(TimedLyrics), none, failed
}

// Everything is touched on the main queue only, so no locks are needed.
final class LyricsProvider {
    private let cacheDirectory: URL
    private let session: URLSession
    private let now: () -> Date
    private let retryDelays: [TimeInterval]
    private var waiters: [String: [(LookupOutcome) -> Void]] = [:]

    // `now` is injectable so tests can expire the negative cache
    init(cacheDirectory: URL, session: URLSession = .shared, now: @escaping () -> Date = { Date() },
         retryDelays: [TimeInterval] = LYRICS_RETRY_DELAYS) {
        self.cacheDirectory = cacheDirectory
        self.session = session
        self.now = now
        self.retryDelays = retryDelays
    }

    // MARK: Public

    // Completion runs on the main queue
    func lyrics(trackID: String, artist: String, title: String, album: String, duration: TimeInterval?,
                completion: @escaping (LookupOutcome) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.lyrics(trackID: trackID, artist: artist, title: title, album: album,
                            duration: duration, completion: completion)
            }
            return
        }
        let key = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return completion(.none) }
        if let entry = readCache(key) {
            if let lyrics = entry.lyrics { return completion(.found(lyrics)) }
            if now().timeIntervalSince(entry.fetchedAt) < LYRICS_NEGATIVE_CACHE_TTL { return completion(.none) }
        }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]
        fetchExact(key: key, artist: artist, title: title, album: album, duration: duration)
    }

    // MARK: LRC parsing

    static func parseLRC(_ text: String, duration: TimeInterval?) -> TimedLyrics? {
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        let offset = parseOffset(rawLines)
        var parsed: [LyricLine] = []
        for raw in rawLines {
            parsed.append(contentsOf: parseLine(Substring(raw.trimmingCharacters(in: .whitespaces)), offset: offset))
        }
        guard !parsed.isEmpty else { return nil }
        // Stable: lines sharing a start keep file order
        let sorted = parsed.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        let lines = sorted.enumerated().map { index, line -> LyricLine in
            let end: TimeInterval
            if index + 1 < sorted.count {
                end = sorted[index + 1].start
            } else if let duration, duration > line.start {
                end = duration
            } else {
                end = line.start + LYRICS_LAST_LINE_FALLBACK_LENGTH
            }
            return LyricLine(start: line.start, end: end, text: line.text, words: line.words)
        }
        return TimedLyrics(lines: lines)
    }

    // Seconds to shift timing by; positive offset makes lyrics appear sooner
    private static func parseOffset(_ lines: [Substring]) -> TimeInterval {
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix("[offset:"), let close = line.firstIndex(of: "]") else { continue }
            let value = line[line.index(line.startIndex, offsetBy: 8)..<close]
                .trimmingCharacters(in: .whitespaces)
            let digits = value.hasPrefix("+") ? String(value.dropFirst()) : value
            if let millis = Double(digits) { return millis / 1000 }
        }
        return 0
    }

    // One source line can yield several LyricLines (several leading timestamps)
    private static func parseLine(_ line: Substring, offset: TimeInterval) -> [LyricLine] {
        var rest = line
        var stamps: [TimeInterval] = []
        while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let content = rest[rest.index(after: rest.startIndex)..<close]
            if let stamp = parseTimestamp(content) { stamps.append(stamp) }
            rest = rest[rest.index(after: close)...]
        }
        guard let first = stamps.first else { return [] }
        let body = parseBody(rest)
        return stamps.map { stamp in
            let shift = stamp - first - offset
            let words = body.words.map { word in
                LyricWord(start: max(0, word.start + shift), text: word.text)
            }
            return LyricLine(start: max(0, stamp - offset), end: 0, text: body.text,
                             words: words.isEmpty ? nil : words)
        }
    }

    // "mm:ss", "mm:ss.xx" or "mm:ss.xxx"; anything else (ar:, ti:, ...) is nil
    private static func parseTimestamp(_ text: Substring) -> TimeInterval? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
              let minutes = Double(parts[0]) else { return nil }
        let secondParts = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count <= 2, !secondParts[0].isEmpty,
              secondParts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              secondParts.count == 1 || !secondParts[1].isEmpty,
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }

    // Splits "<mm:ss.xx>word" markers out of the text. Word starts are relative
    // to the line's own stamp frame (absolute times from the file).
    private static func parseBody(_ text: Substring) -> (text: String, words: [LyricWord]) {
        var segments: [(start: TimeInterval?, text: String)] = [(nil, "")]
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "<", let close = text[index...].firstIndex(of: ">"),
               let stamp = parseTimestamp(text[text.index(after: index)..<close]) {
                segments.append((stamp, ""))
                index = text.index(after: close)
                continue
            }
            segments[segments.count - 1].text.append(char)
            index = text.index(after: index)
        }
        let plain = segments.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        let words = segments.compactMap { segment -> LyricWord? in
            guard let start = segment.start,
                  !segment.text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return LyricWord(start: start, text: segment.text)
        }
        return (plain, words)
    }

    // MARK: Romaji

    // Latin transcription of Japanese text, nil when there is no Japanese in it
    static func romaji(for text: String) -> String? {
        guard text.unicodeScalars.contains(where: isJapanese) else { return nil }
        let string = text as NSString
        let fullRange = CFRangeMake(0, string.length)
        let locale = CFLocaleCreate(nil, CFLocaleCreateCanonicalLocaleIdentifierFromString(nil, "ja" as CFString))
        let tokenizer = CFStringTokenizerCreate(nil, string as CFString, fullRange,
                                                kCFStringTokenizerUnitWord, locale)
        var pieces: [String] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            let piece = transcription ?? string.substring(with: NSRange(location: range.location, length: range.length))
            if !piece.isEmpty { pieces.append(piece) }
        }
        let joined = pieces.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF,  // hiragana, katakana, extensions
             0xFF66...0xFF9F,  // half-width katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF:  // kanji
            return true
        default:
            return false
        }
    }

    // MARK: Lookup chain

    private func fetchExact(key: String, artist: String, title: String, album: String, duration: TimeInterval?) {
        var query = [("artist_name", artist), ("track_name", title), ("album_name", album)]
        if let duration { query.append(("duration", String(Int(duration.rounded())))) }
        guard let url = Self.url(path: "get", query: query) else { return finish(key, .failed) }
        request(url, label: "lyrics get") { [self] result in
            switch result {
            case .ok(let data):
                switch Self.outcome(fromExact: data, duration: duration) {
                case .found(let lyrics): finish(key, .found(lyrics))
                case .instrumental: finish(key, .none)
                case .needsSearch: fetchSearch(key: key, artist: artist, title: title, duration: duration)
                case .failed: finish(key, .failed)
                }
            case .notFound: fetchSearch(key: key, artist: artist, title: title, duration: duration)
            case .failed, .retryable: finish(key, .failed)
            }
        }
    }

    // Reached only after get gave no usable lyrics; a 200 here with nothing usable is the
    // one definitive miss that gets a negative cache entry
    private func fetchSearch(key: String, artist: String, title: String, duration: TimeInterval?) {
        guard let url = Self.url(path: "search", query: [("track_name", title), ("artist_name", artist)]) else {
            return finish(key, .failed)
        }
        request(url, label: "lyrics search") { [self] result in
            switch result {
            case .ok(let data): finish(key, Self.outcome(fromSearch: data, artist: artist, duration: duration))
            case .notFound: finish(key, .none)
            case .failed, .retryable: finish(key, .failed)
            }
        }
    }

    // Only instrumental: true ends the chain; plain-only or empty goes on to search
    private static func outcome(fromExact data: Data, duration: TimeInterval?) -> ExactOutcome {
        guard let track = try? JSONDecoder().decode(LRCLibTrack.self, from: data) else {
            NSLog("wallpaper-overlay: lyrics get response was not understood")
            return .failed
        }
        if track.instrumental == true { return .instrumental }
        guard let synced = track.syncedLyrics, !synced.isEmpty,
              let lyrics = parseLRC(synced, duration: duration ?? track.duration) else { return .needsSearch }
        return .found(lyrics)
    }

    private static func outcome(fromSearch data: Data, artist: String, duration: TimeInterval?) -> LookupOutcome {
        guard let tracks = try? JSONDecoder().decode([LRCLibTrack].self, from: data) else {
            NSLog("wallpaper-overlay: lyrics search response was not understood")
            return .failed
        }
        var synced = tracks.filter { $0.instrumental != true && !($0.syncedLyrics ?? "").isEmpty }
        // Covers and other artists' songs are skipped, unless nothing matches at all
        let wanted = artist.trimmingCharacters(in: .whitespaces).lowercased()
        let sameArtist = synced.filter {
            $0.artistName?.trimmingCharacters(in: .whitespaces).lowercased() == wanted
        }
        if !sameArtist.isEmpty { synced = sameArtist }
        var pick = synced.first
        if let duration {
            // Closest length wins, if within tolerance; otherwise the first synced result
            let close = synced
                .compactMap { track in track.duration.map { (track, abs($0 - duration)) } }
                .filter { $0.1 <= LYRICS_DURATION_TOLERANCE }
                .min { $0.1 < $1.1 }
            pick = close?.0 ?? pick
        }
        guard let pick, let lyrics = parseLRC(pick.syncedLyrics ?? "", duration: duration ?? pick.duration)
        else { return .none }
        return .found(lyrics)
    }

    private func finish(_ key: String, _ outcome: LookupOutcome) {
        let pending = waiters.removeValue(forKey: key) ?? []
        switch outcome {
        case .found(let lyrics):
            writeCache(key, LyricsCacheEntry(version: LYRICS_CACHE_VERSION, fetchedAt: now(), lyrics: lyrics))
        case .none:
            writeCache(key, LyricsCacheEntry(version: LYRICS_CACHE_VERSION, fetchedAt: now(), lyrics: nil))
        case .failed:
            break  // Network trouble is not an answer; don't cache so it retries later
        }
        pending.forEach { $0(outcome) }
    }

    // MARK: Transport

    private static func url(path: String, query: [(String, String)]) -> URL? {
        let items = query.compactMap { name, value -> String? in
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else { return nil }
            return "\(name)=\(encoded)"
        }
        return URL(string: "\(LRCLIB_BASE_URL)/\(path)?\(items.joined(separator: "&"))")
    }

    // "&" and "+" would otherwise split or garble a value
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#")
        return allowed
    }()

    // Calls back on the main queue; logs the HTTP status, never bodies
    // Transient failures are retried after each of retryDelays; if all fail the result
    // is .failed
    private func request(_ url: URL, label: String, attempt: Int = 0,
                         completion: @escaping (HTTPResult) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = LYRICS_REQUEST_TIMEOUT
        request.setValue(LRCLIB_USER_AGENT, forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            let result = Self.interpret(data, response, error, label: label)
            DispatchQueue.main.async { [self] in
                guard case .retryable = result else { return completion(result) }
                guard attempt < retryDelays.count else { return completion(.failed) }
                NSLog("wallpaper-overlay: \(label) retry \(attempt + 1) in \(retryDelays[attempt])s")
                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelays[attempt]) { [self] in
                    self.request(url, label: label, attempt: attempt + 1, completion: completion)
                }
            }
        }.resume()
    }

    private static func interpret(_ data: Data?, _ response: URLResponse?, _ error: Error?,
                                  label: String) -> HTTPResult {
        if let error {
            NSLog("wallpaper-overlay: \(label) request failed: \(error.localizedDescription)")
            return .retryable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return .notFound }
        guard (200..<300).contains(status), let data else {
            NSLog("wallpaper-overlay: \(label) returned HTTP \(status)")
            return status == 429 || (500..<600).contains(status) ? .retryable : .failed
        }
        return .ok(data)
    }

    // MARK: Cache files

    // Readable name plus a hash of the exact ID, so "a:b" and "a_b" never collide
    static func cacheFileName(for trackID: String) -> String {
        let safe = String(trackID.unicodeScalars.map { scalar -> Character in
            let isSafe = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
            return isSafe ? Character(scalar) : "_"
        }.prefix(LYRICS_CACHE_NAME_MAX))
        var hash: UInt64 = 0xcbf29ce484222325  // FNV-1a
        for byte in trackID.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(safe)-\(String(hash, radix: 16)).json"
    }

    private func cacheURL(_ key: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.cacheFileName(for: key))
    }

    private func readCache(_ key: String) -> LyricsCacheEntry? {
        let url = cacheURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let entry = try decoder.decode(LyricsCacheEntry.self, from: Data(contentsOf: url))
            return entry.version == LYRICS_CACHE_VERSION ? entry : nil
        } catch {
            NSLog("wallpaper-overlay: lyrics cache ignored: \(error.localizedDescription)")
            return nil
        }
    }

    private func writeCache(_ key: String, _ entry: LyricsCacheEntry) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(entry).write(to: cacheURL(key), options: .atomic)
        } catch {
            NSLog("wallpaper-overlay: lyrics cache write failed: \(error.localizedDescription)")
        }
    }
}
