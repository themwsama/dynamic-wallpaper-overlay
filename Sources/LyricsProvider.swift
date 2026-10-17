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
// Bumped to 2 when get-without-synced started falling through to search; bumped to 3
// when search results started being checked against the title and artist, since
// earlier entries may hold another song's lyrics; bumped to 4 when plain-only songs
// started getting estimated timing, so ones cached as "none" are asked about again.
// Older entries are ignored.
let LYRICS_CACHE_VERSION = 4
// Waits before the 2nd and 3rd attempt of a request that failed transiently
let LYRICS_RETRY_DELAYS: [TimeInterval] = [1.5, 4]
let LYRICS_CACHE_NAME_MAX = 80
// Estimated timing for plain (untimed) lyrics: lines are spread over the song between
// an intro and an outro margin, each slot weighted by the line's length
let LYRICS_ESTIMATE_INTRO_MAX: TimeInterval = 12
let LYRICS_ESTIMATE_INTRO_SHARE = 0.08
let LYRICS_ESTIMATE_OUTRO_MAX: TimeInterval = 10
let LYRICS_ESTIMATE_OUTRO_SHARE = 0.06
let LYRICS_ESTIMATE_MIN_WEIGHT = 8  // characters; shorter lines count as this many
let LYRICS_ESTIMATE_MAX_LINES = 120
let LYRICS_ESTIMATE_UNKNOWN_DURATION_LINE: TimeInterval = 3.5

struct LyricWord: Codable, Equatable { let start: TimeInterval; let text: String }

struct LyricLine: Codable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String  // "" marks an instrumental gap
    let words: [LyricWord]?
}

struct TimedLyrics: Codable, Equatable {
    let lines: [LyricLine]
    // True when the timing was guessed from plain lyrics, so lines are only roughly in step
    let isEstimated: Bool

    init(lines: [LyricLine], isEstimated: Bool = false) {
        self.lines = lines
        self.isEstimated = isEstimated
    }

    // Entries written before the field existed decode as exact timing
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decode([LyricLine].self, forKey: .lines)
        isEstimated = try container.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }

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
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?
    let plainLyrics: String?
}

// Nonisolated and Sendable: built on the URLSession queue, consumed on main
nonisolated private enum HTTPResult: Sendable {
    case ok(Data), notFound, failed
    case retryable  // 5xx, 429, timeouts and other transport errors
}

private enum ExactOutcome {
    case found(TimedLyrics), instrumental, failed
    // `plainFallback` is the get result's plain text with estimated timing, used only if
    // search finds nothing better
    case needsSearch(plainFallback: TimedLyrics?)
}

// `failed` is transient (network, LRCLIB overloaded): ask again later, it's not an answer
enum LookupOutcome {
    case found(TimedLyrics), none, failed
}

// One track's lookup chain (get, search, retries). Cancelling stops the running task and the
// retry timer; callbacks of a cancelled fetch that still arrive are dropped.
private final class Fetch {
    private(set) var isCancelled = false
    var task: URLSessionDataTask?
    var retryTimer: DispatchWorkItem?

    func cancel() {
        isCancelled = true
        task?.cancel()
        retryTimer?.cancel()
        task = nil
        retryTimer = nil
    }
}

// Everything is touched on the main queue only, so no locks are needed.
final class LyricsProvider {
    private let cacheDirectory: URL
    private let session: URLSession
    private let now: () -> Date
    private let retryDelays: [TimeInterval]
    private var waiters: [String: [(LookupOutcome) -> Void]] = [:]
    // The network work behind each track's waiters, so it can be cancelled by track ID
    private var fetches: [String: Fetch] = [:]

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
        if let cached = cachedLyrics(trackID: key) { return completion(cached) }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]
        let fetch = Fetch()
        fetches[key] = fetch
        fetchExact(key: key, fetch: fetch, artist: artist, title: title, album: album, duration: duration)
    }

    // A usable cache entry as an outcome (found, or a still-fresh "none"), nil when the
    // network is needed. Cheap: one small file read, no network, no callbacks.
    func cachedLyrics(trackID: String) -> LookupOutcome? {
        let key = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return LookupOutcome.none }
        guard let entry = readCache(key) else { return nil }
        if let lyrics = entry.lyrics { return .found(lyrics) }
        return now().timeIntervalSince(entry.fetchedAt) < LYRICS_NEGATIVE_CACHE_TTL ? LookupOutcome.none : nil
    }

    // Drops the lookup for this track: stops its in-flight URLSessionTask and pending retry
    // timer, and forgets its waiters without calling them. Nothing is cached (a cancelled
    // request is not an answer) and no other track is touched.
    func cancel(trackID: String) {
        let key = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        waiters.removeValue(forKey: key)
        fetches.removeValue(forKey: key)?.cancel()
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

    // MARK: Estimated timing

    // Plain lyrics carry no times, so lines are spread over the song: after an intro,
    // before an outro, each slot as long as its share of the characters (short lines
    // count as LYRICS_ESTIMATE_MIN_WEIGHT so they don't flash by). Slots touch, so there
    // are no gap lines. Without a duration every line gets a fixed slot. Beyond
    // LYRICS_ESTIMATE_MAX_LINES only the first lines are kept, spread over the whole song.
    static func estimateTiming(plain: String, duration: TimeInterval?) -> TimedLyrics? {
        let texts = plain.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(LYRICS_ESTIMATE_MAX_LINES)
        guard !texts.isEmpty else { return nil }
        guard let duration, duration > 0, duration.isFinite else {
            let lines = texts.enumerated().map { index, text in
                LyricLine(start: Double(index) * LYRICS_ESTIMATE_UNKNOWN_DURATION_LINE,
                          end: Double(index + 1) * LYRICS_ESTIMATE_UNKNOWN_DURATION_LINE, text: text, words: nil)
            }
            return TimedLyrics(lines: lines, isEstimated: true)
        }
        let intro = min(LYRICS_ESTIMATE_INTRO_MAX, duration * LYRICS_ESTIMATE_INTRO_SHARE)
        let outro = min(LYRICS_ESTIMATE_OUTRO_MAX, duration * LYRICS_ESTIMATE_OUTRO_SHARE)
        let span = duration - intro - outro
        let weights = texts.map { Double(max(LYRICS_ESTIMATE_MIN_WEIGHT, $0.count)) }
        let totalWeight = weights.reduce(0, +)
        var elapsed = 0.0
        var lines: [LyricLine] = []
        for (text, weight) in zip(texts, weights) {
            let start = intro + span * elapsed / totalWeight
            elapsed += weight
            let end = intro + span * elapsed / totalWeight
            lines.append(LyricLine(start: start, end: end, text: text, words: nil))
        }
        return TimedLyrics(lines: lines, isEstimated: true)
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
        // Some files put a space between stamps: "[00:12.00] [00:15.00] text"
        while true {
            let trimmed = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { break }
            let content = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
            guard let stamp = parseTimestamp(content) else {
                // Tag lines like [ar:x] carry no stamps; a bracket after a stamp is lyric text
                if stamps.isEmpty { rest = trimmed[trimmed.index(after: close)...]; continue }
                break
            }
            stamps.append(stamp)
            rest = trimmed[trimmed.index(after: close)...]
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

    private func fetchExact(key: String, fetch: Fetch, artist: String, title: String, album: String,
                            duration: TimeInterval?) {
        var query = [("artist_name", artist), ("track_name", title), ("album_name", album)]
        if let duration { query.append(("duration", String(Int(duration.rounded())))) }
        guard let url = Self.url(path: "get", query: query) else { return finish(key, .failed) }
        request(url, label: "lyrics get", fetch: fetch) { [self] result in
            switch result {
            case .ok(let data):
                switch Self.outcome(fromExact: data, duration: duration) {
                case .found(let lyrics): finish(key, .found(lyrics))
                case .instrumental: finish(key, .none)
                case .needsSearch(let plainFallback):
                    fetchSearch(key: key, fetch: fetch, artist: artist, title: title, duration: duration,
                                plainFallback: plainFallback)
                case .failed: finish(key, .failed)
                }
            case .notFound:
                fetchSearch(key: key, fetch: fetch, artist: artist, title: title, duration: duration, plainFallback: nil)
            case .failed, .retryable: finish(key, .failed)
            }
        }
    }

    // Reached only after get gave no synced lyrics; a 200 here with nothing usable is the
    // one definitive miss that gets a negative cache entry. Synced lyrics from search beat
    // get's plain text; with neither, the plain text (if any) is used.
    private func fetchSearch(key: String, fetch: Fetch, artist: String, title: String, duration: TimeInterval?,
                             plainFallback: TimedLyrics?) {
        guard let url = Self.url(path: "search", query: [("track_name", title), ("artist_name", artist)]) else {
            return finish(key, .failed)
        }
        request(url, label: "lyrics search", fetch: fetch) { [self] result in
            switch result {
            case .ok(let data):
                let found = Self.outcome(fromSearch: data, artist: artist, title: title, duration: duration)
                finish(key, Self.preferringFallback(found, plainFallback))
            case .notFound: finish(key, plainFallback.map { .found($0) } ?? .none)
            case .failed, .retryable: finish(key, .failed)
            }
        }
    }

    // Search's estimated lyrics lose to get's (an exact-signature match); a miss falls back
    private static func preferringFallback(_ outcome: LookupOutcome, _ fallback: TimedLyrics?) -> LookupOutcome {
        guard let fallback else { return outcome }
        switch outcome {
        case .found(let lyrics) where !lyrics.isEstimated: return outcome
        case .found, .none: return .found(fallback)
        case .failed: return .failed
        }
    }

    // Only instrumental: true ends the chain; plain-only or empty goes on to search,
    // carrying the plain text along as a fallback
    private static func outcome(fromExact data: Data, duration: TimeInterval?) -> ExactOutcome {
        guard let track = try? JSONDecoder().decode(LRCLibTrack.self, from: data) else {
            NSLog("wallpaper-overlay: lyrics get response was not understood")
            return .failed
        }
        if track.instrumental == true { return .instrumental }
        let length = duration ?? track.duration
        if let synced = track.syncedLyrics, !synced.isEmpty, let lyrics = parseLRC(synced, duration: length) {
            return .found(lyrics)
        }
        let plain = track.plainLyrics.flatMap { estimateTiming(plain: $0, duration: length) }
        return .needsSearch(plainFallback: plain)
    }

    // A search hit is trusted only when it is the same song: the title must match after
    // normalizing, and then either the artist matches too or the length is within
    // tolerance (covers "A & B" vs "A", romanized vs native artist names). Nothing
    // acceptable is a definitive .none; never fall back to whatever came first.
    private static func outcome(fromSearch data: Data, artist: String, title: String,
                                duration: TimeInterval?) -> LookupOutcome {
        guard let tracks = try? JSONDecoder().decode([LRCLibTrack].self, from: data) else {
            NSLog("wallpaper-overlay: lyrics search response was not understood")
            return .failed
        }
        let wantedTitle = normalizedMatchKey(title)
        let wantedArtist = normalizedMatchKey(artist)
        guard !wantedTitle.isEmpty else { return .none }
        let candidates = tracks.filter { track in
            guard track.instrumental != true, normalizedMatchKey(track.trackName ?? "") == wantedTitle else { return false }
            return isSameArtist(track, wantedArtist) || isCloseInLength(track, duration)
        }
        // Synced beats plain among acceptable results; plain only if nothing synced parses
        let synced = candidates.filter { !($0.syncedLyrics ?? "").isEmpty }
        if let pick = bestMatch(synced, wantedArtist: wantedArtist, duration: duration),
           let lyrics = parseLRC(pick.syncedLyrics ?? "", duration: duration ?? pick.duration) {
            return .found(lyrics)
        }
        let plain = candidates.filter { !($0.plainLyrics ?? "").isEmpty }
        if let pick = bestMatch(plain, wantedArtist: wantedArtist, duration: duration),
           let lyrics = estimateTiming(plain: pick.plainLyrics ?? "", duration: duration ?? pick.duration) {
            return .found(lyrics)
        }
        return .none
    }

    // Same-artist results beat length-only matches; with a known duration the closest
    // length within tolerance wins, otherwise the first acceptable result
    private static func bestMatch(_ candidates: [LRCLibTrack], wantedArtist: String,
                                  duration: TimeInterval?) -> LRCLibTrack? {
        let sameArtist = candidates.filter { isSameArtist($0, wantedArtist) }
        let pool = sameArtist.isEmpty ? candidates : sameArtist
        guard let duration else { return pool.first }
        let close = pool
            .compactMap { track in track.duration.map { (track, abs($0 - duration)) } }
            .filter { $0.1 <= LYRICS_DURATION_TOLERANCE }
            .min { $0.1 < $1.1 }
        return close?.0 ?? pool.first
    }

    private static func isSameArtist(_ track: LRCLibTrack, _ wanted: String) -> Bool {
        !wanted.isEmpty && normalizedMatchKey(track.artistName ?? "") == wanted
    }

    private static func isCloseInLength(_ track: LRCLibTrack, _ duration: TimeInterval?) -> Bool {
        guard let duration, let length = track.duration else { return false }
        return abs(length - duration) <= LYRICS_DURATION_TOLERANCE
    }

    // Suffixes that name a release, not a different song: "- Remastered 2011", "- TV Size"
    private static let releaseSuffix = try! NSRegularExpression(
        pattern: #"\s+[-–—]\s+.*\b(remaster(ed)?|version|ver\.?|edit|mix|mono|stereo|size|feat\.?|ft\.?|deluxe|bonus|single|radio)\b.*$"#,
        options: [.caseInsensitive])
    private static let parenthetical = try! NSRegularExpression(pattern: #"[(\[（［][^)\]）］]*[)\]）］]"#)

    // Lowercase letters and digits only. NFKC first so full-width and half-width forms
    // (Ａ/A, ｶﾀｶﾅ/カタカナ) agree; then "(feat. X)", "[Live]" and "- Remastered" are dropped.
    // If dropping them would leave nothing (a title that is only "(Intro)"), keep them.
    static func normalizedMatchKey(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
        let stripped = removeMatches(releaseSuffix, in: removeMatches(parenthetical, in: folded))
        let key = alphanumericKey(stripped)
        return key.isEmpty ? alphanumericKey(folded) : key
    }

    private static func removeMatches(_ regex: NSRegularExpression, in text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func alphanumericKey(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }))
    }

    private func finish(_ key: String, _ outcome: LookupOutcome) {
        fetches.removeValue(forKey: key)
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
    // is .failed. A cancelled fetch (see cancel(trackID:)) never calls back.
    private func request(_ url: URL, label: String, fetch: Fetch, attempt: Int = 0,
                         completion: @escaping (HTTPResult) -> Void) {
        guard !fetch.isCancelled else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = LYRICS_REQUEST_TIMEOUT
        request.setValue(LRCLIB_USER_AGENT, forHTTPHeaderField: "User-Agent")
        // Built here on the main actor and only ever called there; the session's
        // completion (its own queue) interprets the response and hops back with it
        let deliver: @MainActor @Sendable (HTTPResult) -> Void = { [self] result in
            guard !fetch.isCancelled else { return }
            guard case .retryable = result else { return completion(result) }
            guard attempt < retryDelays.count else { return completion(.failed) }
            NSLog("wallpaper-overlay: \(label) retry \(attempt + 1) in \(retryDelays[attempt])s")
            let timer = DispatchWorkItem { [self] in
                self.request(url, label: label, fetch: fetch, attempt: attempt + 1, completion: completion)
            }
            fetch.retryTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelays[attempt], execute: timer)
        }
        let task = session.dataTask(with: request) { data, response, error in
            let result = Self.interpret(data, response, error, label: label)
            DispatchQueue.main.async { deliver(result) }
        }
        fetch.task = task
        task.resume()
    }

    // Nonisolated: runs on the URLSession delegate queue
    nonisolated private static func interpret(_ data: Data?, _ response: URLResponse?, _ error: Error?,
                                              label: String) -> HTTPResult {
        if let error {
            // Our own cancel(trackID:) lands here too; it is dropped by the cancelled fetch
            if (error as? URLError)?.code != .cancelled {
                NSLog("wallpaper-overlay: \(label) request failed: \(error.localizedDescription)")
            }
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
