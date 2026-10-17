// Assert-style runner for GenreResolver. All HTTP is faked by StubProtocol.
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

// MARK: stub transport

struct Recorded { let url: URL; let headers: [String: String]; let body: Data }
struct Reply { let status: Int; let body: Data; static let fail = Reply(status: -1, body: Data()) }

final class Fixture {
    private let lock = NSLock()
    private var recorded: [Recorded] = []
    var spotifyGenres: [String] = ["edm"]
    var spotifyStatus = 200
    var geminiText = "\"pop\""
    var geminiStatus = 200
    var delay: TimeInterval = 0
    var itunesStatus = 200
    var itunesResults: [[String: String]] = []  // empty = iTunes has no answer

    func reset() { lock.lock(); recorded = []; lock.unlock(); spotifyGenres = ["edm"]; spotifyStatus = 200
        geminiText = "\"pop\""; geminiStatus = 200; delay = 0; itunesStatus = 200; itunesResults = [] }
    func record(_ r: Recorded) { lock.lock(); recorded.append(r); lock.unlock() }
    var all: [Recorded] { lock.lock(); defer { lock.unlock() }; return recorded }
    func count(_ fragment: String) -> Int { all.filter { $0.url.absoluteString.contains(fragment) }.count }
    var total: Int { all.count }

    func reply(to url: URL) -> Reply {
        let s = url.absoluteString
        func json(_ o: Any, _ status: Int = 200) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: o)) ?? Data())
        }
        if s.contains("itunes.apple.com") {
            return itunesStatus == -1 ? .fail : json(["resultCount": itunesResults.count, "results": itunesResults], itunesStatus)
        }
        if s.contains("accounts.spotify.com") {
            return spotifyStatus == -1 ? .fail : json(["access_token": "tok", "token_type": "Bearer", "expires_in": 3600], spotifyStatus)
        }
        if s.contains("/v1/tracks/") {
            return spotifyStatus == -1 ? .fail : json(["artists": [["id": "art1", "name": "X"]]], spotifyStatus)
        }
        if s.contains("/v1/artists/") {
            return spotifyStatus == -1 ? .fail : json(["genres": spotifyGenres], spotifyStatus)
        }
        if s.contains("generativelanguage.googleapis.com") {
            if geminiStatus == -1 { return .fail }
            return json(["candidates": [["content": ["parts": [["text": geminiText]]]]]], geminiStatus)
        }
        return Reply(status: 404, body: Data())
    }
}
let fixture = Fixture()

final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func readBody() -> Data {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        return data
    }

    override func startLoading() {
        guard let url = request.url else { return }
        fixture.record(Recorded(url: url, headers: request.allHTTPHeaderFields ?? [:], body: readBody()))
        let reply = fixture.reply(to: url)
        let respond = { [self] in
            if reply.status < 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
            let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if fixture.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + fixture.delay, execute: respond) } else { respond() }
    }
}

// MARK: helpers

let stubSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: config)
}()

let workDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("genretest-\(UUID().uuidString)")
func freshCacheURL() -> URL { workDir.appendingPathComponent(UUID().uuidString).appendingPathComponent("genre-cache.json") }

let fullCreds = GenreCredentials(spotifyClientID: "cid", spotifyClientSecret: "csecret", geminiAPIKey: "gkey")
let geminiOnly = GenreCredentials(spotifyClientID: nil, spotifyClientSecret: nil, geminiAPIKey: "gkey")
let noCreds = GenreCredentials(spotifyClientID: nil, spotifyClientSecret: nil, geminiAPIKey: nil)

func track(_ artist: String, id: String = "spotify:track:abc") -> TrackInfo {
    TrackInfo(trackID: id, name: "Song", artist: artist, album: "Album")
}

func spin(timeout: TimeInterval = 3, until done: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}

func resolveFull(_ r: GenreResolver, _ t: TrackInfo) -> (bucket: GenreBucket, source: String)? {
    var out: (GenreBucket, String)?
    r.resolve(t) { out = ($0, $1); if !Thread.isMainThread { print("FAIL  completion off main"); failures += 1 } }
    spin { out != nil }
    return out.map { (bucket: $0.0, source: $0.1) }
}

func resolveSync(_ r: GenreResolver, _ t: TrackInfo) -> GenreBucket? { resolveFull(r, t)?.bucket }

func itunesItem(_ artist: String, _ genre: String) -> [String: String] {
    ["artistName": artist, "trackName": "Song", "primaryGenreName": genre]
}

func cacheFile(_ url: URL) -> [String: String]? {
    guard let d = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          obj["version"] as? Int == 2 else { return nil }
    return obj["tracks"] as? [String: String]
}

func makeResolver(_ url: URL, _ creds: GenreCredentials) -> GenreResolver {
    GenreResolver(cacheURL: url, session: stubSession, credentials: creds)
}

// MARK: 1. genre mapping

let samples: [GenreBucket: [String]] = [
    .lofiChill: ["lo-fi beats", "chillhop", "ambient"],
    .pop: ["pop", "k-pop", "dance pop"],
    .hipHopRnb: ["hip hop", "rap", "contemporary r&b", "trap"],
    .electronic: ["edm", "tropical house", "techno", "dubstep", "electronic"],
    .rockMetal: ["indie rock", "heavy metal", "punk", "grunge"],
    .classical: ["classical", "orchestral", "baroque", "late romantic era"],
    .jazzSoul: ["jazz", "neo soul", "funk", "blues"],
    .animeJpopGame: ["anime", "j-pop", "vocaloid", "video game music", "otacore"],
    .worshipGospel: ["christian", "gospel", "worship", "ccm", "praise", "southern gospel"],
]
for bucket in GenreBucket.allCases where bucket != .defaultMix {
    let list = samples[bucket] ?? []
    check(!list.isEmpty, "mapping has samples for \(bucket.rawValue)")
    for genre in list {
        check(GenreResolver.bucket(forSpotifyGenres: [genre]) == bucket, "'\(genre)' -> \(bucket.rawValue)")
    }
}
check(GenreResolver.bucket(forSpotifyGenres: []) == nil, "empty genres -> nil")
check(GenreResolver.bucket(forSpotifyGenres: ["polka", "country"]) == nil, "unknown genres -> nil")
check(GenreResolver.bucket(forSpotifyGenres: ["Lo-Fi Beats"]) == .lofiChill, "matching is case-insensitive")
check(GenreResolver.bucket(forSpotifyGenres: ["lo-fi hip hop"]) == .lofiChill, "lo-fi hip hop -> lofiChill")
check(GenreResolver.bucket(forSpotifyGenres: ["pop rap"]) == .hipHopRnb, "pop rap -> hipHopRnb")
check(GenreResolver.bucket(forSpotifyGenres: ["pop", "j-pop", "anime"]) == .animeJpopGame, "majority vote wins")
check(GenreResolver.bucket(forSpotifyGenres: ["polka", "techno"]) == .electronic, "unknown genre ignored among known")
check(GenreResolver.bucket(forSpotifyGenres: ["christian pop"]) == .worshipGospel, "christian pop -> worshipGospel")
check(GenreResolver.bucket(forSpotifyGenres: ["christian rock"]) == .worshipGospel, "christian rock -> worshipGospel")
check(GenreResolver.bucket(forSpotifyGenres: ["worship", "pop", "rock"]) == .worshipGospel, "worship beats pop and rock votes")
check(GenreResolver.bucket(forSpotifyGenres: ["christian metal"]) == .worshipGospel, "christian metal -> worshipGospel")
check(GenreResolver.bucket(forSpotifyGenres: ["jazz", "pop"]) == .jazzSoul, "tie goes to the more specific bucket")

// MARK: 1b. iTunes genre mapping

let itunesSamples: [(String, GenreBucket)] = [
    ("Pop", .pop), ("K-Pop", .pop),
    ("Hip-Hop/Rap", .hipHopRnb), ("Rap", .hipHopRnb), ("R&B/Soul", .hipHopRnb),
    ("Electronic", .electronic), ("Dance", .electronic), ("House", .electronic), ("Techno", .electronic),
    ("Rock", .rockMetal), ("Hard Rock", .rockMetal), ("Metal", .rockMetal), ("Alternative", .rockMetal), ("Punk", .rockMetal),
    ("Classical", .classical), ("Soundtrack", .classical),
    ("Anime", .animeJpopGame), ("J-Pop", .animeJpopGame), ("Video Game", .animeJpopGame), ("Japanese Pop", .animeJpopGame),
    ("Jazz", .jazzSoul), ("Soul", .jazzSoul), ("Blues", .jazzSoul),
    ("Christian & Gospel", .worshipGospel), ("Christian", .worshipGospel), ("Gospel", .worshipGospel),
    ("Inspirational", .worshipGospel), ("Worship", .worshipGospel),
    ("Lo-Fi", .lofiChill), ("Ambient", .lofiChill), ("Chill", .lofiChill), ("New Age", .lofiChill),
]
for (name, expected) in itunesSamples {
    check(GenreResolver.bucket(forITunesGenre: name) == expected, "itunes '\(name)' -> \(expected.rawValue)")
}
check(GenreResolver.bucket(forITunesGenre: "Country") == nil, "itunes unknown genre -> nil")
check(GenreResolver.bucket(forITunesGenre: "") == nil, "itunes empty genre -> nil")
check(GenreResolver.bucket(forITunesGenre: "hip-hop/rap") == .hipHopRnb, "itunes mapping case-insensitive")

func itunesData(_ results: [[String: String]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["resultCount": results.count, "results": results])
}
check(GenreResolver.parseITunesGenre(itunesData([itunesItem("Cover Band", "Rock"), itunesItem("Real Artist", "Jazz")]), artist: "real ARTIST") == "Jazz",
      "itunes picks the result by the matching artist")
check(GenreResolver.parseITunesGenre(itunesData([itunesItem("Someone", "Rock"), itunesItem("Other", "Jazz")]), artist: "Nobody") == "Rock",
      "itunes falls back to the first result")
check(GenreResolver.parseITunesGenre(itunesData([]), artist: "x") == nil, "itunes no results -> nil")
check(GenreResolver.parseITunesGenre(Data("garbage".utf8), artist: "x") == nil, "itunes bad JSON -> nil")

// MARK: 2. Gemini parsing

func gemini(_ text: String) -> Data {
    try! JSONSerialization.data(withJSONObject: ["candidates": [["content": ["parts": [["text": text]]]]]])
}
check(GenreResolver.parseGeminiResponse(gemini("\"jazzSoul\"")) == .jazzSoul, "gemini valid quoted enum")
check(GenreResolver.parseGeminiResponse(gemini("rockMetal\n")) == .rockMetal, "gemini valid bare value")
check(GenreResolver.parseGeminiResponse(gemini("\"defaultMix\"")) == .defaultMix, "gemini defaultMix parses")
check(GenreResolver.parseGeminiResponse(Data("not json {".utf8)) == nil, "gemini invalid JSON -> nil")
check(GenreResolver.parseGeminiResponse(Data()) == nil, "gemini empty data -> nil")
check(GenreResolver.parseGeminiResponse(gemini("\"polka\"")) == nil, "gemini unknown value -> nil")
check(GenreResolver.parseGeminiResponse(Data("{\"candidates\":[]}".utf8)) == nil, "gemini no candidates -> nil")
check(GenreResolver.parseGeminiResponse(Data("{\"error\":{\"code\":400}}".utf8)) == nil, "gemini error body -> nil")

// MARK: 2b. track URI parsing

check(GenreResolver.spotifyTrackID(from: "spotify:track:abc123") == "abc123", "track id parsed")
check(GenreResolver.spotifyTrackID(from: "spotify:local:a:b:c") == nil, "local track rejected")
check(GenreResolver.spotifyTrackID(from: "spotify:track:../x") == nil, "unsafe id rejected")

// MARK: 3. cache hit does no requests

do {
    fixture.reset()
    let url = freshCacheURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"version\":2,\"tracks\":{\"spotify:track:abc\":\"rockMetal\",\"spotify:track:bad\":\"nonsense\"}}".utf8).write(to: url)
    let r = makeResolver(url, fullCreds)
    let hit = resolveFull(r, track("SomeBody"))
    check(hit?.bucket == .rockMetal && hit?.source == "cache", "cache hit returns cached bucket, source cache")
    check(fixture.total == 0, "cache hit makes zero requests")
    fixture.reset()
    let r2 = makeResolver(url, noCreds)
    check(resolveSync(r2, track("bad", id: "spotify:track:bad")) == .defaultMix, "unknown cached bucket name ignored")
}

// MARK: 4. cache persists across instances

do {
    fixture.reset()
    fixture.geminiText = "\"electronic\""
    let url = freshCacheURL()  // parent dir does not exist yet
    check(resolveSync(makeResolver(url, geminiOnly), track("Persist Me")) == .electronic, "gemini-only lookup")
    check(cacheFile(url)?["spotify:track:abc"] == "electronic", "cache file written keyed by track id, parent dir created")
    let before = fixture.total
    check(resolveSync(makeResolver(url, noCreds), track("Persist Me")) == .electronic, "new instance reads persisted cache")
    check(fixture.total == before, "persisted hit makes no new requests")
}

// MARK: 5. Spotify success skips Gemini

do {
    fixture.reset()
    fixture.spotifyGenres = ["edm", "house"]
    let url = freshCacheURL()
    let r = makeResolver(url, fullCreds)
    let spot = resolveFull(r, track("Spotty"))
    check(spot?.bucket == .electronic && spot?.source == "spotify", "spotify genres -> bucket, source spotify")
    check(fixture.count("generativelanguage") == 0, "spotify success makes no gemini call")
    check(fixture.count("accounts.spotify.com") == 1 && fixture.count("/v1/tracks/abc") == 1 && fixture.count("/v1/artists/art1") == 1,
          "one call each: token, track, artist")
    let tokenReq = fixture.all.first { $0.url.absoluteString.contains("accounts.spotify.com") }
    let expectedBasic = "Basic " + Data("cid:csecret".utf8).base64EncodedString()
    check(tokenReq?.headers["Authorization"] == expectedBasic, "token request uses Basic auth")
    check(String(data: tokenReq?.body ?? Data(), encoding: .utf8) == "grant_type=client_credentials", "token body is client_credentials")
    let artistReq = fixture.all.first { $0.url.absoluteString.contains("/v1/artists/") }
    check(artistReq?.headers["Authorization"] == "Bearer tok", "api call uses bearer token")
    check(cacheFile(url)?["spotify:track:abc"] == "electronic", "spotify answer cached")

    // second artist reuses the in-memory token
    fixture.spotifyGenres = ["jazz"]
    check(resolveSync(r, track("Another Artist", id: "spotify:track:def")) == .jazzSoul, "second track resolves")
    check(fixture.count("accounts.spotify.com") == 1, "token reused until expiry")
}

// MARK: 6. Spotify empty genres -> Gemini

do {
    fixture.reset()
    fixture.spotifyGenres = []
    fixture.geminiText = "\"classical\""
    let url = freshCacheURL()
    let viaGemini = resolveFull(makeResolver(url, fullCreds), track("Empty Genres"))
    check(viaGemini?.bucket == .classical && viaGemini?.source == "gemini", "empty spotify genres fall through to gemini, source gemini")
    check(fixture.count("generativelanguage") == 1, "gemini called once")
    let g = fixture.all.first { $0.url.absoluteString.contains("generativelanguage") }
    check(g?.headers["x-goog-api-key"] == "gkey", "gemini key sent in header")
    check(g?.url.absoluteString.contains("key=") == false, "gemini key never in URL")
    check(g?.url.path.hasSuffix("/models/gemini-2.5-flash-lite:generateContent") == true, "gemini model in URL")
    if let body = g?.body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let cfg = obj["generationConfig"] as? [String: Any], let schema = cfg["responseSchema"] as? [String: Any] {
        check(cfg["responseMimeType"] as? String == "application/json", "gemini mime type json")
        check(cfg["temperature"] as? Double == 0, "gemini temperature 0")
        check((schema["enum"] as? [String]) == GenreBucket.allCases.map(\.rawValue), "gemini schema enum lists every bucket")
        let text = ((obj["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        check(text.contains("Empty Genres") && text.contains("Song") && text.contains("Album"), "prompt has artist, track, album")
    } else {
        check(false, "gemini request body parses")
    }
    check(cacheFile(url)?["spotify:track:abc"] == "classical", "gemini answer cached")
}

// MARK: 7. no credentials

do {
    fixture.reset()
    let url = freshCacheURL()
    let none = resolveFull(makeResolver(url, noCreds), track("Nobody"))
    check(none?.bucket == .defaultMix && none?.source == "fallback", "no credentials -> defaultMix, source fallback")
    check(fixture.total == 1 && fixture.count("itunes.apple.com") == 1, "no credentials: only the keyless itunes request")
    check(cacheFile(url) == nil, "no-credential defaultMix not cached")
    check(resolveSync(makeResolver(url, noCreds), track("", id: "")) == .defaultMix, "empty track id -> defaultMix")
    check(resolveSync(makeResolver(freshCacheURL(), fullCreds), track("Local", id: "spotify:local:a:b:c")) == .pop
          && fixture.count("spotify.com") == 0 && fixture.count("generativelanguage") == 1, "non-spotify track skips spotify, uses gemini")
}

// MARK: 8. in-flight dedup

do {
    fixture.reset()
    fixture.delay = 0.15
    let r = makeResolver(freshCacheURL(), fullCreds)
    var results: [GenreBucket] = []
    r.resolve(track("Dup Artist")) { b, _ in results.append(b) }
    r.resolve(track("dup artist")) { b, _ in results.append(b) }
    r.resolve(track("DUP ARTIST ")) { b, _ in results.append(b) }
    spin { results.count == 3 }
    check(results == [.electronic, .electronic, .electronic], "all waiters complete with the same bucket")
    check(fixture.count("itunes.apple.com") == 1, "dedup: one itunes request")
    check(fixture.count("accounts.spotify.com") == 1 && fixture.count("/v1/tracks/") == 1 && fixture.count("/v1/artists/") == 1,
          "dedup: one lookup chain for three calls")
}

// MARK: 9. failures and defaultMix caching

do {
    fixture.reset()
    fixture.spotifyStatus = 500
    fixture.geminiStatus = -1
    let url = freshCacheURL()
    let r = makeResolver(url, fullCreds)
    check(resolveSync(r, track("Flaky")) == .defaultMix, "network errors -> defaultMix")
    check(cacheFile(url) == nil, "error defaultMix not cached")
    let before = fixture.total
    check(resolveSync(r, track("Flaky")) == .defaultMix && fixture.total == before, "cooldown avoids immediate re-ask")

    fixture.spotifyStatus = 200; fixture.geminiStatus = 200
    check(resolveSync(makeResolver(url, fullCreds), track("Flaky")) == .electronic, "fresh resolver retries and succeeds")
    check(cacheFile(url)?["spotify:track:abc"] == "electronic", "retry result cached")
}

do {
    fixture.reset()
    fixture.spotifyGenres = []
    fixture.geminiText = "\"defaultMix\""
    let url = freshCacheURL()
    check(resolveSync(makeResolver(url, fullCreds), track("Genuinely Unclear")) == .defaultMix, "gemini defaultMix returned")
    check(cacheFile(url)?["spotify:track:abc"] == "defaultMix", "real gemini defaultMix IS cached")

    fixture.reset()
    fixture.spotifyGenres = []
    fixture.geminiText = "\"not a bucket\""
    let url2 = freshCacheURL()
    check(resolveSync(makeResolver(url2, fullCreds), track("Garbled")) == .defaultMix, "unparseable gemini -> defaultMix")
    check(cacheFile(url2) == nil, "unparseable gemini result not cached")
}

// MARK: 10. iTunes step

do {
    fixture.reset()
    fixture.itunesResults = [itunesItem("Cover Band", "Rock"), itunesItem("Simon & Garfunkel", "Jazz")]
    let url = freshCacheURL()
    let r = makeResolver(url, fullCreds)
    let res = resolveFull(r, track("Simon & Garfunkel"))
    check(res?.bucket == .jazzSoul && res?.source == "itunes", "itunes success picks matching artist, source itunes")
    check(fixture.count("spotify.com") == 0 && fixture.count("generativelanguage") == 0, "itunes success: no spotify or gemini requests")
    check(cacheFile(url)?["spotify:track:abc"] == "jazzSoul", "itunes answer cached")
    if let u = fixture.all.first?.url, let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        check(comps.host == "itunes.apple.com" && comps.path == "/search", "itunes search endpoint")
        check(q["term"] == "Simon & Garfunkel Song", "itunes term is artist + track, encoded round-trip")
        check(q["media"] == "music" && q["entity"] == "song" && q["limit"] == "5", "itunes media/entity/limit")
        check(fixture.all.first?.headers.keys.contains { $0.lowercased() == "authorization" } == false, "itunes request carries no auth")
    } else { check(false, "itunes request url parses") }

    // unmatched Apple genre falls through to spotify
    fixture.reset()
    fixture.itunesResults = [itunesItem("A", "Country")]
    fixture.spotifyGenres = ["jazz"]
    let thr = resolveFull(makeResolver(freshCacheURL(), fullCreds), track("A"))
    check(thr?.bucket == .jazzSoul && thr?.source == "spotify" && fixture.count("itunes.apple.com") == 1,
          "itunes unmatched genre falls through to spotify")

    // HTTP error falls through
    fixture.reset()
    fixture.itunesStatus = 503
    fixture.spotifyGenres = ["techno"]
    let err = resolveFull(makeResolver(freshCacheURL(), fullCreds), track("A"))
    check(err?.bucket == .electronic && err?.source == "spotify", "itunes HTTP error falls through")
    fixture.reset()
    fixture.itunesStatus = -1
    fixture.geminiText = "\"rockMetal\""
    fixture.spotifyGenres = []
    check(resolveFull(makeResolver(freshCacheURL(), fullCreds), track("A"))?.source == "gemini", "itunes network error falls through to the end")
}

// MARK: 11. cache keyed by track id

do {
    fixture.reset()
    fixture.itunesResults = [itunesItem("Same Artist", "Rock")]
    let url = freshCacheURL()
    let r = makeResolver(url, noCreds)
    check(resolveSync(r, track("Same Artist", id: "spotify:track:one")) == .rockMetal, "track one resolves")
    check(fixture.count("itunes.apple.com") == 1, "first track makes one request")
    check(resolveSync(r, track("Same Artist", id: "spotify:track:two")) == .rockMetal, "same artist, new track resolves")
    check(fixture.count("itunes.apple.com") == 2, "same artist with a different track makes a new request")
    let again = resolveFull(r, track("Same Artist", id: "spotify:track:one"))
    check(again?.source == "cache" && fixture.count("itunes.apple.com") == 2, "same track again makes no request")
    check(cacheFile(url)?.count == 2, "cache holds one entry per track")
}

// MARK: 12. old artist-keyed cache ignored

do {
    fixture.reset()
    fixture.itunesResults = [itunesItem("Somebody", "Jazz")]
    let url = freshCacheURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{\"somebody\":\"rockMetal\",\"spotify:track:abc\":\"pop\"}".utf8).write(to: url)
    let r = makeResolver(url, noCreds)
    let res = resolveFull(r, track("Somebody"))
    check(res?.bucket == .jazzSoul && res?.source == "itunes", "old-format cache ignored, fresh lookup used")
    check(cacheFile(url)?["spotify:track:abc"] == "jazzSoul", "file rewritten in the new format")
    try Data("{\"version\":1,\"tracks\":{\"spotify:track:abc\":\"pop\"}}".utf8).write(to: url)
    check(resolveFull(makeResolver(url, noCreds), track("Somebody"))?.source == "itunes", "wrong cache version ignored")
}

// MARK: 13. lazy credentials (keychain) only on first network need, off main

do {
    final class Loader {
        private let lock = NSLock()
        private var _calls = 0
        private var _offMain = true
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var offMain: Bool { lock.lock(); defer { lock.unlock() }; return _offMain }
        func load() -> GenreCredentials {
            lock.lock(); _calls += 1; if Thread.isMainThread { _offMain = false }; lock.unlock()
            return fullCreds
        }
    }
    fixture.reset()
    let loader = Loader()
    let url = freshCacheURL()
    let lazy = GenreResolver(cacheURL: url, session: stubSession, credentials: { loader.load() })
    check(loader.calls == 0, "lazy credentials not read at init")
    fixture.itunesResults = [itunesItem("Lazy", "Rock")]
    let first = resolveFull(lazy, track("Lazy", id: "spotify:track:lazy1"))
    check(first?.source == "itunes" && loader.calls == 0, "iTunes success path never reads credentials")
    let hit = resolveFull(lazy, track("Lazy", id: "spotify:track:lazy1"))
    check(hit?.source == "cache" && loader.calls == 0, "cache hit never reads credentials")

    // iTunes has no answer: the Spotify step needs keys, so they load now, once, off main
    fixture.itunesResults = []
    fixture.spotifyGenres = ["techno"]
    let viaSpotify = resolveFull(lazy, track("Lazy", id: "spotify:track:lazy2"))
    check(viaSpotify?.bucket == .electronic && viaSpotify?.source == "spotify", "lazy credentials reach Spotify")
    check(loader.calls == 1 && loader.offMain, "credentials loaded once, off the main thread")
    fixture.spotifyGenres = []
    fixture.geminiText = "\"classical\""
    let viaGemini = resolveFull(lazy, track("Lazy", id: "spotify:track:lazy3"))
    check(viaGemini?.source == "gemini" && loader.calls == 1, "later lookups reuse the loaded credentials")

    // Two lookups needing keys at once share one load
    fixture.reset()
    fixture.spotifyGenres = ["jazz"]
    let loader2 = Loader()
    let r2 = GenreResolver(cacheURL: freshCacheURL(), session: stubSession, credentials: { loader2.load() })
    var got: [GenreBucket] = []
    r2.resolve(track("P", id: "spotify:track:p1")) { b, _ in got.append(b) }
    r2.resolve(track("Q", id: "spotify:track:q1")) { b, _ in got.append(b) }
    spin { got.count == 2 }
    check(got == [.jazzSoul, .jazzSoul] && loader2.calls == 1, "concurrent lookups share one credentials load")
}

try? FileManager.default.removeItem(at: workDir)
print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
if failures > 0 { exit(1) }
