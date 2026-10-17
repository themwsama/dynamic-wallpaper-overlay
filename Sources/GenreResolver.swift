// Decides a playing track's genre bucket with as few API calls as possible:
// cache, then iTunes Search (no key), then Spotify artist genres, then a Gemini
// guess, then .defaultMix. Privacy: only the artist, track and album names (plus
// the Spotify IDs of that same track and artist) are ever sent anywhere.
// Secrets are never logged.
import Foundation
import Security

let GEMINI_MODEL = "gemini-2.5-flash-lite"
let GEMINI_ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/models/\(GEMINI_MODEL):generateContent"
let ITUNES_SEARCH_URL = "https://itunes.apple.com/search"
let ITUNES_RESULT_LIMIT = 5
let SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token"
let SPOTIFY_API_BASE = "https://api.spotify.com/v1"
let GENRE_REQUEST_TIMEOUT: TimeInterval = 8
let SPOTIFY_TOKEN_EXPIRY_MARGIN: TimeInterval = 60
// After a lookup finds nothing, don't re-ask for this long (it still retries later)
let GENRE_FAILURE_COOLDOWN: TimeInterval = 60
let GENRE_PROMPT_FIELD_MAX = 200
nonisolated let GENRE_KEYCHAIN_SERVICE = "wallpaper-overlay"
// Bump when the cache file layout or key meaning changes; older files are ignored
let GENRE_CACHE_VERSION = 2

enum GenreBucket: String, CaseIterable, Codable {
    case lofiChill, pop, hipHopRnb, electronic, rockMetal, classical, jazzSoul, animeJpopGame, worshipGospel, defaultMix
}

enum GenreSource: String {
    case cache, itunes, spotify, gemini, fallback
    var sourceName: String { rawValue }
}

struct TrackInfo {
    let trackID: String  // like "spotify:track:abc"
    let name: String
    let artist: String
    let album: String
}

// Apple's own genre names; same first-match-wins idea. "R&B/Soul" must hit hip hop
// before the plain "soul" rule, and anime/video game before "Soundtrack".
let ITUNES_GENRE_RULES: [(bucket: GenreBucket, keywords: [String])] = [
    (.animeJpopGame, ["anime", "j-pop", "jpop", "japanese pop", "video game"]),
    (.worshipGospel, ["christian", "gospel", "inspirational", "worship", "ccm"]),
    (.hipHopRnb, ["hip-hop", "hip hop", "rap", "r&b"]),
    (.jazzSoul, ["jazz", "soul", "blues"]),
    (.lofiChill, ["lo-fi", "lofi", "ambient", "chill", "new age"]),
    (.electronic, ["electronic", "dance", "house", "techno"]),
    (.rockMetal, ["rock", "metal", "alternative", "punk"]),
    (.classical, ["classical", "soundtrack", "opera"]),
    (.pop, ["pop"]),
]

// First rule that matches a genre string wins, so specific buckets come before
// generic ones ("lo-fi hip hop" is lofi, "pop rap" is hip hop, "jazz rap" is jazz).
// The same order breaks ties between buckets with equal votes.
let GENRE_KEYWORD_RULES: [(bucket: GenreBucket, keywords: [String])] = [
    (.animeJpopGame, ["anime", "j-pop", "jpop", "j-rock", "jrock", "japanese", "vocaloid",
                      "video game", "vgm", "game music", "chiptune", "otacore", "utaite", "touhou"]),
    // Before lofi, pop and rock so "christian pop" and "christian rock" land here
    (.worshipGospel, ["christian", "gospel", "worship", "ccm", "praise"]),
    (.lofiChill, ["lo-fi", "lofi", "chill", "ambient", "study", "sleep", "relax", "meditation",
                  "new age", "downtempo", "bedroom"]),
    (.classical, ["classical", "orchestra", "symphon", "baroque", "opera", "chamber",
                  "choral", "romantic era", "romanticism"]),
    (.jazzSoul, ["jazz", "soul", "funk", "blues", "motown", "bossa", "swing"]),
    (.electronic, ["edm", "house", "techno", "dubstep", "electronic", "electro", "trance",
                   "drum and bass", "dnb", "synthwave", "future bass", "hardstyle",
                   "breakbeat", "idm", "eurodance"]),
    (.rockMetal, ["rock", "metal", "punk", "grunge", "emo", "screamo", "shoegaze"]),
    (.hipHopRnb, ["hip hop", "hip-hop", "rap", "r&b", "rnb", "trap", "drill", "grime",
                  "boom bap", "phonk"]),
    (.pop, ["pop", "boy band", "girl group", "idol", "top 40"]),
]

private extension GenreBucket {
    // Tells Gemini what each bucket means so its single pick is consistent
    var promptHint: String {
        switch self {
        case .lofiChill: return "lo-fi, chill, ambient, study or sleep music"
        case .pop: return "mainstream pop and K-pop"
        case .hipHopRnb: return "hip hop, rap, trap and R&B"
        case .electronic: return "EDM, house, techno, dubstep, drum and bass"
        case .rockMetal: return "rock, indie rock, punk, metal"
        case .classical: return "classical, orchestral, opera, film scores"
        case .jazzSoul: return "jazz, soul, funk, blues"
        case .animeJpopGame: return "anime, J-pop, vocaloid, video game music"
        case .worshipGospel: return "worship, gospel, contemporary Christian music"
        case .defaultMix: return "anything that fits none of the others"
        }
    }
}

// Nonisolated and Sendable: loaded from the Keychain on a background queue
nonisolated struct GenreCredentials: Sendable {
    let spotifyClientID: String?
    let spotifyClientSecret: String?
    let geminiAPIKey: String?

    static func fromKeychain() -> GenreCredentials {
        GenreCredentials(
            spotifyClientID: readSecret(account: "spotify-client-id"),
            spotifyClientSecret: readSecret(account: "spotify-client-secret"),
            geminiAPIKey: readSecret(account: "gemini-api-key"))
    }

    // Missing or unreadable items are simply nil; only the status code is logged
    private static func readSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GENRE_KEYCHAIN_SERVICE,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                NSLog("wallpaper-overlay: keychain read for \(account) failed (status \(status))")
            }
            return nil
        }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

private struct SpotifyToken {
    let value: String
    let expiresAt: Date
}

private struct SpotifyTokenResponse: Decodable {
    let access_token: String
    let expires_in: TimeInterval
}

private struct SpotifyTrackResponse: Decodable {
    struct Artist: Decodable { let id: String? }
    let artists: [Artist]?
}

private struct SpotifyArtistResponse: Decodable {
    let genres: [String]?
}

private struct ITunesResponse: Decodable {
    struct Item: Decodable {
        let artistName: String?
        let primaryGenreName: String?
    }
    let results: [Item]?
}

private struct GenreCacheFile: Codable {
    let version: Int
    let tracks: [String: String]  // Spotify track URI -> bucket raw value
}

private struct GeminiResponse: Decodable {
    struct Part: Decodable { let text: String? }
    struct Content: Decodable { let parts: [Part]? }
    struct Candidate: Decodable { let content: Content? }
    let candidates: [Candidate]?
}

// Everything is touched on the main queue only, so no locks are needed.
final class GenreResolver {
    private let cacheURL: URL
    private let session: URLSession
    private let loadCredentials: @Sendable () -> GenreCredentials
    private var credentials: GenreCredentials?
    private var credentialWaiters: [(GenreCredentials) -> Void]?  // non-nil while loading
    private var cache: [String: GenreBucket]
    private var waiters: [String: [(GenreBucket, String) -> Void]] = [:]
    private var failedAt: [String: Date] = [:]
    private var token: SpotifyToken?

    convenience init(cacheURL: URL, session: URLSession = .shared, credentials: GenreCredentials) {
        self.init(cacheURL: cacheURL, session: session, credentials: { credentials })
        self.credentials = credentials
    }

    // Keychain reads can block (and may prompt), so `credentials` runs only when a
    // lookup first needs a key, once, off the main thread. Cache hits and iTunes
    // answers never touch it.
    init(cacheURL: URL, session: URLSession = .shared, credentials: @escaping @Sendable () -> GenreCredentials) {
        self.cacheURL = cacheURL
        self.session = session
        self.loadCredentials = credentials
        self.cache = Self.loadCache(from: cacheURL)
    }

    // MARK: Public

    // Completion gets the bucket and where it came from (GenreSource.sourceName)
    func resolve(_ track: TrackInfo, completion: @escaping (GenreBucket, String) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.resolve(track, completion: completion) }
            return
        }
        let key = Self.cacheKey(for: track)
        if key.isEmpty { return deliver(track, .defaultMix, .fallback, completion) }
        if let hit = cache[key] { return deliver(track, hit, .cache, completion) }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < GENRE_FAILURE_COOLDOWN {
            return deliver(track, .defaultMix, .fallback, completion)
        }
        // A lookup for this track is already running; just wait for it
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]
        lookUp(track, key: key)
    }

    // MARK: Pure helpers

    static func bucket(forSpotifyGenres genres: [String]) -> GenreBucket? {
        var votes: [GenreBucket: Int] = [:]
        for genre in genres {
            let name = genre.lowercased()
            let rule = GENRE_KEYWORD_RULES.first { rule in rule.keywords.contains { name.contains($0) } }
            if let rule { votes[rule.bucket, default: 0] += 1 }
        }
        var best: (bucket: GenreBucket, votes: Int)?
        for rule in GENRE_KEYWORD_RULES {
            let count = votes[rule.bucket] ?? 0
            if count > (best?.votes ?? 0) { best = (rule.bucket, count) }
        }
        return best?.bucket
    }

    static func bucket(forITunesGenre genre: String) -> GenreBucket? {
        let name = genre.lowercased()
        let rule = ITUNES_GENRE_RULES.first { rule in rule.keywords.contains { name.contains($0) } }
        return rule?.bucket
    }

    // Prefers the result by the same artist; the search can rank covers first
    static func parseITunesGenre(_ data: Data, artist: String) -> String? {
        guard let items = try? JSONDecoder().decode(ITunesResponse.self, from: data).results,
              let first = items.first else { return nil }
        let wanted = normalized(artist)
        let pick = items.first { $0.artistName.map(normalized) == wanted } ?? first
        return pick.primaryGenreName
    }

    static func iTunesSearchURL(for track: TrackInfo) -> URL? {
        let term = "\(clipped(track.artist)) \(clipped(track.name))"
        guard let encoded = term.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else { return nil }
        return URL(string: "\(ITUNES_SEARCH_URL)?term=\(encoded)&media=music&entity=song&limit=\(ITUNES_RESULT_LIMIT)")
    }

    static func parseGeminiResponse(_ data: Data) -> GenreBucket? {
        guard let response = try? JSONDecoder().decode(GeminiResponse.self, from: data),
              let text = response.candidates?.first?.content?.parts?.first?.text else { return nil }
        // With a JSON mime type a string enum comes back quoted
        let value = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
        return GenreBucket(rawValue: value)
    }

    static func geminiRequestBody(for track: TrackInfo) -> [String: Any] {
        let buckets = GenreBucket.allCases
        let meanings = buckets.map { "\($0.rawValue): \($0.promptHint)" }.joined(separator: "\n")
        let prompt = """
            Pick the single best genre bucket for this song.
            Artist: \(clipped(track.artist))
            Track: \(clipped(track.name))
            Album: \(clipped(track.album))
            Buckets:
            \(meanings)
            Answer with exactly one bucket name.
            """
        return [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
                "responseSchema": ["type": "STRING", "enum": buckets.map(\.rawValue)],
            ],
        ]
    }

    static func spotifyTrackID(from uri: String) -> String? {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" else { return nil }
        return isSafeSpotifyID(String(parts[2])) ? String(parts[2]) : nil
    }

    static func parseFirstArtistID(_ data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(SpotifyTrackResponse.self, from: data),
              let id = response.artists?.first?.id, isSafeSpotifyID(id) else { return nil }
        return id
    }

    static func parseGenres(_ data: Data) -> [String]? {
        try? JSONDecoder().decode(SpotifyArtistResponse.self, from: data).genres
    }

    private static func parseToken(_ data: Data) -> SpotifyToken? {
        guard let response = try? JSONDecoder().decode(SpotifyTokenResponse.self, from: data),
              !response.access_token.isEmpty else { return nil }
        let lifetime = max(0, response.expires_in - SPOTIFY_TOKEN_EXPIRY_MARGIN)
        return SpotifyToken(value: response.access_token, expiresAt: Date().addingTimeInterval(lifetime))
    }

    // IDs go straight into a URL path, so allow only what Spotify really uses
    private static func isSafeSpotifyID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // Each new song is checked, so the key is the track, not the artist
    private static func cacheKey(for track: TrackInfo) -> String {
        track.trackID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // "&" and "+" would otherwise split or garble the search term
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#")
        return allowed
    }()

    private static func clipped(_ text: String) -> String {
        String(text.prefix(GENRE_PROMPT_FIELD_MAX))
    }

    // MARK: Lookup chain

    private typealias Step = (TrackInfo, @escaping (GenreBucket?) -> Void) -> Void

    private func lookUp(_ track: TrackInfo, key: String) {
        let steps: [(GenreSource, Step)] = [
            (.itunes, { self.iTunesBucket(for: $0, completion: $1) }),
            (.spotify, { self.spotifyBucket(for: $0, completion: $1) }),
            (.gemini, { self.geminiBucket(for: $0, completion: $1) }),
        ]
        run(steps[...], track, key: key)
    }

    private func run(_ steps: ArraySlice<(GenreSource, Step)>, _ track: TrackInfo, key: String) {
        guard let (source, step) = steps.first else {
            // No real answer (error, or nothing to ask): don't cache, so it retries later
            failedAt[key] = Date()
            return finish(track, key, .defaultMix, .fallback, shouldCache: false)
        }
        step(track) { [self] bucket in
            guard let bucket else { return run(steps.dropFirst(), track, key: key) }
            finish(track, key, bucket, source, shouldCache: true)
        }
    }

    private func finish(_ track: TrackInfo, _ key: String, _ bucket: GenreBucket, _ source: GenreSource,
                        shouldCache: Bool) {
        let pending = waiters.removeValue(forKey: key) ?? []
        if shouldCache {
            cache = cache.merging([key: bucket]) { _, new in new }
            failedAt.removeValue(forKey: key)
            saveCache()
        }
        logResolution(track, bucket, source)
        pending.forEach { $0(bucket, source.sourceName) }
    }

    private func deliver(_ track: TrackInfo, _ bucket: GenreBucket, _ source: GenreSource,
                         _ completion: (GenreBucket, String) -> Void) {
        logResolution(track, bucket, source)
        completion(bucket, source.sourceName)
    }

    private func logResolution(_ track: TrackInfo, _ bucket: GenreBucket, _ source: GenreSource) {
        NSLog("wallpaper-overlay: genre %@ \u{2013} %@ -> %@ (%@)", track.artist, track.name, bucket.rawValue, source.sourceName)
    }

    // MARK: iTunes (no key needed)

    private func iTunesBucket(for track: TrackInfo, completion: @escaping (GenreBucket?) -> Void) {
        guard let url = Self.iTunesSearchURL(for: track) else { return completion(nil) }
        send(URLRequest(url: url), label: "itunes", parse: { Self.parseITunesGenre($0, artist: track.artist) }) { genre in
            completion(genre.flatMap(Self.bucket(forITunesGenre:)))
        }
    }

    // MARK: Spotify

    private func spotifyBucket(for track: TrackInfo, completion: @escaping (GenreBucket?) -> Void) {
        withCredentials { [self] credentials in spotifyBucket(for: track, credentials, completion: completion) }
    }

    private func spotifyBucket(for track: TrackInfo, _ credentials: GenreCredentials,
                               completion: @escaping (GenreBucket?) -> Void) {
        guard let clientID = credentials.spotifyClientID, !clientID.isEmpty,
              let secret = credentials.spotifyClientSecret, !secret.isEmpty,
              let trackID = Self.spotifyTrackID(from: track.trackID) else { return completion(nil) }
        withSpotifyToken(clientID: clientID, secret: secret) { [self] accessToken in
            guard let accessToken else { return completion(nil) }
            spotifyGet("tracks/\(trackID)", accessToken, parse: Self.parseFirstArtistID) { [self] artistID in
                guard let artistID else { return completion(nil) }
                spotifyGet("artists/\(artistID)", accessToken, parse: Self.parseGenres) { genres in
                    completion(genres.flatMap(Self.bucket(forSpotifyGenres:)))
                }
            }
        }
    }

    private func withSpotifyToken(clientID: String, secret: String, completion: @escaping (String?) -> Void) {
        if let token, token.expiresAt > Date() { return completion(token.value) }
        guard let url = URL(string: SPOTIFY_TOKEN_URL) else { return completion(nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let basic = Data("\(clientID):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials".utf8)
        send(request, label: "spotify token", parse: Self.parseToken) { [self] fresh in
            token = fresh
            completion(fresh?.value)
        }
    }

    private func spotifyGet<T>(_ path: String, _ accessToken: String, parse: @escaping (Data) -> T?,
                               completion: @escaping (T?) -> Void) {
        guard let url = URL(string: "\(SPOTIFY_API_BASE)/\(path)") else { return completion(nil) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        send(request, label: "spotify \(path.split(separator: "/")[0])", parse: parse, completion: completion)
    }

    // MARK: Gemini

    private func geminiBucket(for track: TrackInfo, completion: @escaping (GenreBucket?) -> Void) {
        withCredentials { [self] credentials in geminiBucket(for: track, credentials, completion: completion) }
    }

    private func geminiBucket(for track: TrackInfo, _ credentials: GenreCredentials,
                              completion: @escaping (GenreBucket?) -> Void) {
        guard let apiKey = credentials.geminiAPIKey, !apiKey.isEmpty,
              let url = URL(string: GEMINI_ENDPOINT),
              let body = try? JSONSerialization.data(withJSONObject: Self.geminiRequestBody(for: track))
        else { return completion(nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        send(request, label: "gemini", parse: Self.parseGeminiResponse, completion: completion)
    }

    // MARK: Credentials

    // Loads once; lookups that need keys while the load runs wait for the same result
    private func withCredentials(_ body: @escaping (GenreCredentials) -> Void) {
        if let credentials { return body(credentials) }
        if credentialWaiters != nil {
            credentialWaiters?.append(body)
            return
        }
        credentialWaiters = [body]
        let load = loadCredentials
        DispatchQueue.global(qos: .utility).async {
            let loaded = load()
            DispatchQueue.main.async { [self] in
                credentials = loaded
                let pending = credentialWaiters ?? []
                credentialWaiters = nil
                pending.forEach { $0(loaded) }
            }
        }
    }

    // MARK: Transport

    // Calls back on the main queue with nil on any failure; logs never include
    // headers, bodies or keys
    private func send<T>(_ request: URLRequest, label: String, parse: @escaping (Data) -> T?,
                         completion: @escaping (T?) -> Void) {
        var request = request
        request.timeoutInterval = GENRE_REQUEST_TIMEOUT
        // Built here on the main actor and only ever called there: the session's
        // completion runs on its own queue and just hops back with the raw result
        let deliver: @MainActor @Sendable (Data?, URLResponse?, (any Error)?) -> Void = { [self] data, response, error in
            completion(interpret(data, response, error, label: label, parse: parse))
        }
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { deliver(data, response, error) }
        }.resume()
    }

    private func interpret<T>(_ data: Data?, _ response: URLResponse?, _ error: Error?,
                              label: String, parse: (Data) -> T?) -> T? {
        if let error {
            NSLog("wallpaper-overlay: \(label) request failed: \(error.localizedDescription)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let data else {
            NSLog("wallpaper-overlay: \(label) returned HTTP \(status)")
            // A rejected token is dropped so the next lookup logs in again
            if status == 401 { token = nil }
            return nil
        }
        guard let value = parse(data) else {
            NSLog("wallpaper-overlay: \(label) response had no usable answer")
            return nil
        }
        return value
    }

    // MARK: Cache file

    private static func loadCache(from url: URL) -> [String: GenreBucket] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let file = try JSONDecoder().decode(GenreCacheFile.self, from: Data(contentsOf: url))
            guard file.version == GENRE_CACHE_VERSION else { return [:] }
            // Unknown bucket names (from an older or newer build) are dropped, not fatal
            return file.tracks.compactMapValues { GenreBucket(rawValue: $0) }
        } catch {
            // Includes the old artist-keyed layout, which has no version field
            NSLog("wallpaper-overlay: genre cache ignored: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveCache() {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let file = GenreCacheFile(version: GENRE_CACHE_VERSION, tracks: cache.mapValues(\.rawValue))
            try encoder.encode(file).write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("wallpaper-overlay: genre cache write failed: \(error.localizedDescription)")
        }
    }
}
