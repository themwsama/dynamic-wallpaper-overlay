import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

// MARK: stub
// Runs on URLSession's threads, so nonisolated; the handler is @Sendable so the
// closures the tests pass are never main-actor isolated
nonisolated final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data)?)?  // nil = network error
    nonisolated(unsafe) static var requests: [URLRequest] = []
    // Requests whose URL contains one of these are accepted but never answered until `releaseHeld`
    nonisolated(unsafe) static var holdMatching: [String] = []
    nonisolated(unsafe) static var held: [Stub] = []
    nonisolated(unsafe) static var stoppedURLs: [URL] = []
    static let lock = NSLock()
    static func isHeld(_ request: URLRequest) -> Bool {
        let url = request.url!.absoluteString
        return holdMatching.contains { url.contains($0) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Stub.lock.lock(); Stub.requests.append(request)
        if Stub.isHeld(request) { Stub.held.append(self); Stub.lock.unlock(); return }
        Stub.lock.unlock()
        respond()
    }
    func respond() {
        guard let (status, body) = Stub.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Stub.lock.lock(); Stub.stoppedURLs.append(request.url!); Stub.held.removeAll { $0 === self }; Stub.lock.unlock()
    }
    // Answers every held request (a cancelled one has already left the list)
    static func releaseHeld() {
        lock.lock(); let ready = held; held = []; lock.unlock()
        ready.forEach { $0.respond() }
    }
}
// Request counter for stub handlers, which run on URLSession's threads
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
func resetStub(_ h: @escaping @Sendable (URLRequest) -> (Int, Data)?) {
    Stub.lock.lock(); Stub.requests = []; Stub.holdMatching = []; Stub.held = []; Stub.stoppedURLs = []; Stub.lock.unlock()
    Stub.handler = h
}
func stoppedCount() -> Int { Stub.lock.lock(); defer { Stub.lock.unlock() }; return Stub.stoppedURLs.count }
func requestCount(containing text: String) -> Int {
    Stub.lock.lock(); defer { Stub.lock.unlock() }
    return Stub.requests.filter { $0.url!.absoluteString.contains(text) }.count
}
func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func reqCount() -> Int { Stub.lock.lock(); defer { Stub.lock.unlock() }; return Stub.requests.count }
let cfg = URLSessionConfiguration.ephemeral
cfg.protocolClasses = [Stub.self]
let session = URLSession(configuration: cfg)

nonisolated func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
func tmpDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-provider-tests-\(UUID().uuidString)") }
func spin(_ cond: () -> Bool) { let end = Date().addingTimeInterval(5); while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }

func lyricsOf(_ o: LookupOutcome) -> TimedLyrics? { if case .found(let l) = o { return l }; return nil }

func fetch(_ p: LyricsProvider, id: String = "t1", duration: TimeInterval? = 200) -> TimedLyrics? {
    var done = false; var out: TimedLyrics?
    p.lyrics(trackID: id, artist: "Paper Lanterns", title: "River & Moon", album: "Night", duration: duration) { out = lyricsOf($0); done = true }
    spin { done }
    check(done, "completion fired")
    return out
}

let lrcA = "[00:01.00] paper lanterns drift over the river\n[00:05.50] a quiet bell under the bridge"

// MARK: parseLRC
do {
    let l = LyricsProvider.parseLRC("[ar:Nobody]\n[ti:Invented]\n[00:12.00] first invented line\n[00:20.50]second invented line", duration: 60)!
    check(l.lines.count == 2 && l.lines[0].start == 12 && l.lines[0].text == "first invented line", "parse basic")
    check(l.lines[0].end == 20.5 && l.lines[1].end == 60, "ends: next start, last=duration")
}
do {
    let l = LyricsProvider.parseLRC("[00:12.00][01:30.50] chorus of invented words\n[00:40.00] verse", duration: nil)!
    check(l.lines.map(\.start) == [12, 40, 90.5], "multi timestamp sorted")
    check(l.lines[2].text == "chorus of invented words" && l.lines[2].end == 95.5, "last line end = start+5")
}
do {
    let l = LyricsProvider.parseLRC("[offset:+500]\n[00:10.00] x", duration: nil)!
    check(l.lines[0].start == 9.5, "positive offset appears sooner")
    let n = LyricsProvider.parseLRC("[offset:-250]\n[00:10.00] x", duration: nil)!
    check(n.lines[0].start == 10.25, "negative offset later")
}
do {
    let l = LyricsProvider.parseLRC("[00:10.00]<00:10.00>paper <00:10.50>lanterns <00:11.25>drift", duration: nil)!
    check(l.lines[0].text == "paper lanterns drift", "enhanced text")
    check(l.lines[0].words == [LyricWord(start: 10, text: "paper "), LyricWord(start: 10.5, text: "lanterns "), LyricWord(start: 11.25, text: "drift")], "enhanced words")
}
do {
    let l = LyricsProvider.parseLRC("[00:01.00] one\r\n[00:02.00] two\r\n", duration: nil)!
    check(l.lines.count == 2 && l.lines[0].text == "one" && l.lines[1].text == "two", "CRLF")
}
do {
    let l = LyricsProvider.parseLRC("[00:01.00] one\n[00:05.00]\n[00:09.00] two", duration: nil)!
    check(l.lines.count == 3 && l.lines[1].text == "" && l.lines[1].end == 9, "empty gap line kept")
}
do {
    let l = LyricsProvider.parseLRC("[00:12.00] [00:15.00] spaced stamps\n[00:20.00]\t[00:25.00]\ttabbed", duration: nil)!
    check(l.lines.count == 4 && l.lines.map(\.start) == [12, 15, 20, 25], "whitespace between stamps: one line per stamp")
    check(l.lines.allSatisfy { $0.text == "spaced stamps" || $0.text == "tabbed" } && l.lines[0].text == "spaced stamps" && l.lines[2].text == "tabbed", "whitespace between stamps: text intact")
    let m = LyricsProvider.parseLRC("[00:12.00] [00:15.00] text", duration: nil)!
    check(m.lines.count == 2 && m.lines.allSatisfy { $0.text == "text" }, "two spaced stamps give 2 lines with text")
    let b = LyricsProvider.parseLRC("[00:12.00] [Chorus] words", duration: nil)!
    check(b.lines.count == 1 && b.lines[0].text == "[Chorus] words", "non-stamp bracket after a stamp stays in the text")
}
check(LyricsProvider.parseLRC("just some text\nno stamps\n[ar:x]", duration: 10) == nil, "garbage nil")
check(LyricsProvider.parseLRC("", duration: nil) == nil, "empty nil")

// MARK: lineIndex
do {
    let l = LyricsProvider.parseLRC("[00:10.00] a\n[00:20.00] b", duration: 30)!
    check(l.lineIndex(at: 9.99) == nil, "before first nil")
    check(l.lineIndex(at: 10) == 0, "start inclusive")
    check(l.lineIndex(at: 19.999) == 0, "end exclusive side")
    check(l.lineIndex(at: 20) == 1, "next start")
    check(l.lineIndex(at: 30) == nil, "last end exclusive")
    check(l.lineIndex(at: 100) == nil, "after last nil")
}

// MARK: network
func getPath(_ r: URLRequest) -> String { r.url!.path }
do {
    // exact hit, header, query
    resetStub { _ in (200, json(["syncedLyrics": lrcA, "duration": 200])) }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])
    let l = fetch(p)
    check(l?.lines.count == 2, "get hit parsed")
    let r = Stub.requests[0]
    check(r.value(forHTTPHeaderField: "User-Agent") == LRCLIB_USER_AGENT, "user agent")
    let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
    check(q.first { $0.name == "duration" }?.value == "200" && q.first { $0.name == "track_name" }?.value == "River & Moon", "get query")
    check(r.timeoutInterval == 8, "timeout 8")
    // cache hit: no request
    let before = reqCount()
    let again = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(again == l && reqCount() == before, "cache hit no request")
}
do {
    // no duration omitted
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    _ = fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), duration: nil)
    check(!Stub.requests[0].url!.absoluteString.contains("duration"), "duration omitted when nil")
}
do {
    // 404 -> search, prefers duration within 3s
    resetStub { r in
        if r.url!.path.hasSuffix("/get") { return (404, Data()) }
        return (200, json([
            ["trackName": "River & Moon", "artistName": "Paper Lanterns", "duration": 250, "syncedLyrics": "[00:01.00] wrong length"],
            ["trackName": "River & Moon", "artistName": "Paper Lanterns", "duration": 201.5, "syncedLyrics": "[00:01.00] right length"],
            ["trackName": "River & Moon", "artistName": "Paper Lanterns", "duration": 200, "plainLyrics": "plain only"],
        ]))
    }
    let l = fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]))
    check(l?.lines.first?.text == "right length", "search prefers close duration")
    check(Stub.requests.count == 2 && Stub.requests[1].url!.path.hasSuffix("/search"), "get->404->search")
    let q = URLComponents(url: Stub.requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
    check(q.map(\.name) == ["track_name", "artist_name"], "search query names")
}
do {
    resetStub { r in
        if r.url!.path.hasSuffix("/get") { return (404, Data()) }
        return (200, json([["trackName": "River & Moon", "artistName": "Paper Lanterns", "duration": 999, "syncedLyrics": "[00:01.00] only candidate"]]))
    }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]))?.lines.first?.text == "only candidate", "same song with a far duration still accepted via artist")
}
do {
    resetStub { _ in (200, json(["plainLyrics": "plain only", "instrumental": false])) }
    // Raced endpoints: an unusable search reply counts as that endpoint failing, so get's plain
    // text is used, estimated, and not cached
    let undecodableDir = tmpDir()
    let undecodable = fetch(LyricsProvider(cacheDirectory: undecodableDir, session: session, retryDelays: [0, 0]))
    check(undecodable?.isEstimated == true && undecodable?.lines.first?.text == "plain only" && cacheFiles(undecodableDir).isEmpty, "plain-only get with an undecodable search: plain used, estimated, not cached")
    resetStub { _ in (200, json(["instrumental": true, "syncedLyrics": lrcA])) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0])) == nil, "instrumental nil")
}
do {
    // negative cache + expiry via clock
    resetStub { r in r.url!.path.hasSuffix("/get") ? (404, Data()) : (200, json([[String: Any]]())) }
    let dir = tmpDir()
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let p = LyricsProvider(cacheDirectory: dir, session: session, now: { clock }, retryDelays: [0, 0])
    check(fetch(p) == nil, "not found nil")
    check(reqCount() == 2, "two requests for miss")
    clock = clock.addingTimeInterval(6 * 24 * 3600)
    check(fetch(p) == nil && reqCount() == 2, "negative cache hit within 7 days")
    clock = clock.addingTimeInterval(2 * 24 * 3600)
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    check(fetch(p)?.lines.count == 2 && reqCount() == 2, "negative cache expired, refetched (get and search raced)")
}
do {
    // network errors and 500 not cached
    resetStub { _ in nil }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])
    check(fetch(p) == nil, "network error nil")
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    check(fetch(p) != nil, "error not cached")
    resetStub { _ in (500, Data()) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0])) == nil, "500 nil")
}
do {
    // in-flight dedup
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    let p = LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0])
    var results: [TimedLyrics?] = []
    for _ in 0..<3 {
        p.lyrics(trackID: "dup", artist: "a", title: "t", album: "al", duration: nil) { results.append(lyricsOf($0)) }
    }
    spin { results.count == 3 }
    check(results.count == 3 && results.allSatisfy { $0 != nil } && reqCount() == 2, "in-flight dedup: one lookup, get and search once each")
}
do {
    check(LyricsProvider.cacheFileName(for: "spotify:track:abc") != LyricsProvider.cacheFileName(for: "spotify_track_abc"), "file names collision-free")
    check(!LyricsProvider.cacheFileName(for: "../../etc/x").contains("/"), "file name sanitized")
}


// MARK: fallthrough, retry, versioning
nonisolated func isGet(_ r: URLRequest) -> Bool { r.url!.path.hasSuffix("/get") }
func cacheFiles(_ d: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] }
func fetchArtist(_ p: LyricsProvider, artist: String, duration: TimeInterval?) -> TimedLyrics? {
    var done = false; var out: TimedLyrics?
    p.lyrics(trackID: "art", artist: artist, title: "t", album: "al", duration: duration) { out = lyricsOf($0); done = true }
    spin { done }
    return out
}
do {
    resetStub { r in isGet(r) ? (200, json(["plainLyrics": "plain", "syncedLyrics": NSNull(), "instrumental": false]))
        : (200, json([["trackName": "River & Moon", "artistName": "Paper Lanterns", "duration": 201, "syncedLyrics": "[00:01.00] from search"]])) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]))?.lines.first?.text == "from search", "get plain-only falls through to search")
    check(reqCount() == 2, "plain-only made get+search")
}
do {
    resetStub { _ in (200, json(["instrumental": true])) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil && reqCount() == 2, "get instrumental: none (search was raced, its answer is not needed)")
    check(cacheFiles(dir).count == 1, "instrumental negative cached")
}
do {
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([
        ["trackName": "River & Moon", "artistName": "paper lanterns", "duration": 205, "syncedLyrics": "[00:01.00] far"],
        ["trackName": "river & moon", "artistName": "PAPER LANTERNS", "duration": 199, "syncedLyrics": "[00:01.00] closest"],
        ["trackName": "River & Moon", "artistName": "paper lanterns", "duration": 202.5, "syncedLyrics": "[00:01.00] near"],
    ])) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), duration: 200)?.lines.first?.text == "closest", "search picks closest duration within 3s")
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), duration: nil)?.lines.first?.text == "far", "no duration: first same-artist result")
}
do {
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([
        ["trackName": "t", "artistName": "Someone Else", "duration": 200, "syncedLyrics": "[00:01.00] cover"],
        ["trackName": "t", "artistName": "Paper Lanterns", "duration": 230, "syncedLyrics": "[00:01.00] mine"],
    ])) }
    check(fetchArtist(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), artist: "paper lanterns", duration: 200)?.lines.first?.text == "mine", "same artist beats a length-only match")
    check(fetchArtist(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), artist: "Nobody Matches", duration: 200)?.lines.first?.text == "cover", "no artist match: length-only match accepted")
    check(fetchArtist(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), artist: "Nobody Matches", duration: 100) == nil, "no artist match and wrong length: rejected")
}
do {
    let n = Counter()
    resetStub { r in isGet(r) ? (n.next() == 1 ? (503, Data()) : (200, json(["syncedLyrics": lrcA]))) : (404, Data()) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0])) != nil && reqCount() == 3, "503 then 200 retried (get twice, search once)")
}
do {
    resetStub { _ in (503, Data()) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil, "three 503s nil")
    check(reqCount() == 6 && cacheFiles(dir).isEmpty, "3 attempts per endpoint, no negative cache file")
    resetStub { _ in (429, Data()) }
    _ = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(reqCount() == 6, "429 retried")
    resetStub { _ in (400, Data()) }
    _ = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(reqCount() == 2, "400 not retried")
}
do {
    let n = Counter()
    resetStub { r in isGet(r) ? (n.next() == 1 ? nil : (200, json(["syncedLyrics": lrcA]))) : (404, Data()) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0])) != nil && reqCount() == 3, "URL error retried")
    // search retries too; get plain-only then search 503 x3 -> plain shown, nothing cached
    resetStub { r in isGet(r) ? (200, json(["plainLyrics": "p"])) : (503, Data()) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))?.isEstimated == true && cacheFiles(dir).isEmpty && reqCount() == 4, "search retried, partial answer not cached")
}
do {
    // old-version cache ignored
    let dir = tmpDir()
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = LyricsProvider.cacheFileName(for: "t1")
    let old: [String: Any] = ["version": 1, "fetchedAt": Date().timeIntervalSince1970]
    try! json(old).write(to: dir.appendingPathComponent(name))
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) != nil && reqCount() == 2, "old-version cache ignored")
}
do {
    // negative cache only after definitive search miss
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([[String: Any]]())) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil && cacheFiles(dir).count == 1, "definitive miss writes negative")
}


// MARK: search result validation
func searchResult(title: String = "River & Moon", artist: String = "Paper Lanterns", wantTitle: String = "River & Moon",
                  wantArtist: String = "Paper Lanterns", duration: TimeInterval? = 200, results: [[String: Any]],
                  dir: URL = tmpDir(), id: String = "sv") -> LookupOutcome? {
    let body = json(results)
    resetStub { r in isGet(r) ? (404, Data()) : (200, body) }
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])
    var out: LookupOutcome?
    p.lyrics(trackID: id, artist: wantArtist, title: wantTitle, album: "al", duration: duration) { out = $0 }
    spin { out != nil }
    return out
}
func isNone(_ o: LookupOutcome?) -> Bool { if case .none? = o { return true }; return false }
func text(_ o: LookupOutcome?) -> String? { lyricsOf(o ?? .failed)?.lines.first?.text }
nonisolated func hit(_ name: String, _ artist: String, _ duration: Double, _ lyric: String) -> [String: Any] {
    ["trackName": name, "artistName": artist, "duration": duration, "syncedLyrics": "[00:01.00] \(lyric)"]
}
do {
    check(isNone(searchResult(results: [hit("Different Song", "Paper Lanterns", 200, "wrong song")])), "wrong-title result rejected")
    check(isNone(searchResult(results: [["artistName": "Paper Lanterns", "duration": 200, "syncedLyrics": "[00:01.00] no title"]])), "result without a title rejected")
    check(text(searchResult(results: [hit("River & Moon (feat. Someone Invented)", "Paper Lanterns", 200, "feat ok")])) == "feat ok", "(feat. ...) suffix tolerated")
    check(text(searchResult(results: [hit("River & Moon - Remastered 2011", "Paper Lanterns", 200, "remaster ok")])) == "remaster ok", "- Remastered suffix tolerated")
    check(text(searchResult(results: [hit("River & Moon (TV Size)", "Paper Lanterns", 200, "tv ok")])) == "tv ok", "(TV Size) tolerated")
    check(text(searchResult(wantTitle: "River & Moon - 2011 Remaster", results: [hit("River & Moon", "Paper Lanterns", 200, "wanted side")])) == "wanted side", "suffix on the Spotify side tolerated")
    check(isNone(searchResult(results: [hit("River & Moon - Part Two", "Paper Lanterns", 200, "subtitle differs")])), "a real subtitle still differs")
    check(text(searchResult(wantTitle: "Ｒｉｖｅｒ Ｍｏｏｎ", results: [hit("River Moon", "Paper Lanterns", 200, "width ok")])) == "width ok", "full-width Latin title matches")
    check(text(searchResult(wantTitle: "ｶﾞｯｸﾞﾗﾝﾀﾝ", wantArtist: "ﾍﾟｰﾊﾟｰ", results: [hit("ガッグランタン", "ペーパー", 200, "kana ok")])) == "kana ok", "half-width katakana title and artist match")
    check(text(searchResult(wantTitle: "紙の灯り", wantArtist: "灯", results: [hit("紙の灯り", "灯", 199, "kanji ok")])) == "kanji ok", "Japanese exact match")
    check(text(searchResult(results: [hit("River & Moon", "Someone Else Entirely", 201, "length ok")])) == "length ok", "artist mismatch with matching duration accepted")
    check(isNone(searchResult(results: [hit("River & Moon", "Someone Else Entirely", 240, "far")])), "artist mismatch with wrong duration rejected")
    check(isNone(searchResult(duration: nil, results: [hit("River & Moon", "Someone Else Entirely", 200, "no length known")])), "artist mismatch and no duration rejected")
    check(text(searchResult(duration: nil, results: [hit("River & Moon", "paper  lanterns", 200, "artist only")])) == "artist only", "artist match needs no duration (case and spacing folded)")
    check(isNone(searchResult(results: [hit("Other One", "Paper Lanterns", 200, "x"), hit("Another", "Nobody", 200, "y")])), "nothing matching gives none")
    check(isNone(searchResult(results: [])), "empty results give none")
    check(text(searchResult(results: [hit("Other One", "Paper Lanterns", 200, "x"), hit("River & Moon", "Paper Lanterns", 200, "right")])) == "right", "right song picked among wrong ones")
    check(text(searchResult(results: [hit("River & Moon", "Cover Band", 200, "cover"), hit("River & Moon", "Paper Lanterns", 230, "original")])) == "original", "artist match beats a length-only match")
    let dir = tmpDir()
    check(isNone(searchResult(results: [hit("Other One", "Paper Lanterns", 200, "x")], dir: dir)) && cacheFiles(dir).count == 1, "rejected search is a definitive miss, cached negative")
    check(LyricsProvider.normalizedMatchKey("(Intro)") == "intro", "title that is only a parenthetical keeps its text")
    check(LyricsProvider.normalizedMatchKey("  Hello, World! ") == "helloworld", "punctuation and whitespace dropped")
}
do {
    // wrongly cached version-2 entry is dropped
    let dir = tmpDir()
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wrong = ["version": 2, "fetchedAt": Date().timeIntervalSince1970,
                 "lyrics": ["lines": [["start": 1, "end": 5, "text": "wrong song"]]]] as [String: Any]
    try! json(wrong).write(to: dir.appendingPathComponent(LyricsProvider.cacheFileName(for: "t1")))
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    let l = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(LYRICS_CACHE_VERSION == 4 && l?.lines.first?.text == "paper lanterns drift over the river" && reqCount() == 2, "version 2 cache entry dropped")
}

// MARK: estimated timing
let plain5 = "first invented line\nsecond invented line here\n\n  \nthird\nfourth invented lantern line goes on\nfifth"
do {
    let l = LyricsProvider.estimateTiming(plain: plain5, duration: 200)!
    let intro = min(12.0, 200 * 0.08), outro = min(10.0, 200 * 0.06)
    check(l.isEstimated && l.lines.count == 5 && l.lines.allSatisfy { $0.text != "" && $0.words == nil }, "estimate: flagged, empty lines dropped, no gap lines")
    check(l.lines[0].start == intro, "estimate: first line starts at the intro offset (12s cap)")
    check(zip(l.lines, l.lines.dropFirst()).allSatisfy { $0.start < $1.start }, "estimate: starts strictly increase")
    check(zip(l.lines, l.lines.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-9 }, "estimate: slots touch, no holes")
    check(abs(l.lines.last!.end - (200 - outro)) < 1e-9 && l.lines.last!.end <= 200 - outro + 1e-9, "estimate: last end at duration minus outro")
    // weighting: the 5-char lines get the 8-char minimum, longer lines get proportionally more
    let len = l.lines.map { $0.end - $0.start }
    check(abs(len[2] - len[4]) < 1e-9 && len[2] > 0, "estimate: short lines share the minimum weight")
    check(len[3] > len[1] && len[1] > len[0] && len[0] > len[2], "estimate: longer lines get longer slots")
    let w = [19, 25, 8, 36, 8].map(Double.init)
    check(abs(len[3] / len[0] - w[3] / w[0]) < 1e-9, "estimate: slot ratio equals weight ratio")
    // short song: margins scale with duration
    let s = LyricsProvider.estimateTiming(plain: "a long enough invented line\nanother invented line", duration: 50)!
    check(abs(s.lines[0].start - 4) < 1e-9 && abs(s.lines.last!.end - 47) < 1e-9, "estimate: 8% intro and 6% outro on a short song")
    let t = LyricsProvider.estimateTiming(plain: plain5, duration: nil)!
    check(t.isEstimated && t.lines.map(\.start) == [0, 3.5, 7, 10.5, 14] && t.lines.last!.end == 17.5, "estimate: unknown duration uses 3.5s per line")
    check(LyricsProvider.estimateTiming(plain: plain5, duration: 0)?.lines[1].start == 3.5, "estimate: zero duration treated as unknown")
    check(LyricsProvider.estimateTiming(plain: "", duration: 100) == nil, "estimate: empty is nil")
    check(LyricsProvider.estimateTiming(plain: " \n\t\n\r\n ", duration: 100) == nil, "estimate: blank lines only is nil")
    let crlf = LyricsProvider.estimateTiming(plain: "one invented\r\ntwo invented\r\n", duration: 100)!
    check(crlf.lines.map(\.text) == ["one invented", "two invented"], "estimate: CRLF split")
    let many = (0..<300).map { "invented line number \($0)" }.joined(separator: "\n")
    let capped = LyricsProvider.estimateTiming(plain: many, duration: 240)!
    check(capped.lines.count == LYRICS_ESTIMATE_MAX_LINES && capped.lines.count == 120, "estimate: capped at 120 lines")
    check(abs(capped.lines.last!.end - (240 - min(10, 240 * 0.06))) < 1e-9 && abs(capped.lines[0].start - min(12, 240 * 0.08)) < 1e-9, "estimate: capped lines still span the song")
}
do {
    // Codable: isEstimated round-trips, and a payload without the field decodes as exact
    let l = LyricsProvider.estimateTiming(plain: "invented one\ninvented two", duration: 100)!
    let back = try! JSONDecoder().decode(TimedLyrics.self, from: JSONEncoder().encode(l))
    check(back == l && back.isEstimated, "TimedLyrics isEstimated round-trips")
    let legacy = try! JSONDecoder().decode(TimedLyrics.self, from: json(["lines": [["start": 1, "end": 5, "text": "old entry"]]]))
    check(!legacy.isEstimated && legacy.lines.count == 1, "TimedLyrics without isEstimated decodes as exact")
    check(!TimedLyrics(lines: []).isEstimated, "isEstimated defaults to false")
}

// MARK: plain-lyrics fallback
let plainText = "invented first line\ninvented second line\ninvented third line"
nonisolated func plainHit(_ name: String = "River & Moon", _ artist: String = "Paper Lanterns", _ duration: Double = 200,
              plain: String = plainText, instrumental: Bool = false) -> [String: Any] {
    ["trackName": name, "artistName": artist, "duration": duration, "plainLyrics": plain, "instrumental": instrumental]
}
do {
    // get is plain-only, search has synced: synced wins
    resetStub { r in isGet(r) ? (200, json(plainHit())) : (200, json([hit("River & Moon", "Paper Lanterns", 200, "synced from search")])) }
    let l = fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]))
    check(l?.lines.first?.text == "synced from search" && l?.isEstimated == false, "plain-only get, synced search: synced preferred")
    check(reqCount() == 2, "plain-only get still searched")
}
do {
    // plain-only everywhere: get's plain, estimated, cached with the flag
    resetStub { r in isGet(r) ? (200, json(plainHit(plain: "get plain one\nget plain two"))) : (200, json([plainHit(plain: "search plain")])) }
    let dir = tmpDir()
    let l = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(l?.isEstimated == true && l?.lines.map(\.text) == ["get plain one", "get plain two"], "plain-only everywhere: estimated from get's plain")
    check(reqCount() == 2 && cacheFiles(dir).count == 1, "plain fallback: get then search, one cache file")
    let before = reqCount()
    let again = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(again == l && again?.isEstimated == true && reqCount() == before, "estimated lyrics cached with isEstimated")
    let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(cacheFiles(dir)[0]))) as! [String: Any]
    check(((raw["lyrics"] as? [String: Any])?["isEstimated"] as? Bool) == true && raw["version"] as? Int == LYRICS_CACHE_VERSION, "cache file stores isEstimated and the current version")
}
do {
    // get 404, search plain-only: estimated from the search result
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([plainHit(plain: "search plain one\nsearch plain two")])) }
    let l = fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), duration: 200)
    check(l?.isEstimated == true && l?.lines.first?.text == "search plain one", "get 404, plain-only search: estimated")
    check(abs((l?.lines.first?.start ?? 0) - 12) < 1e-9, "search plain: timing uses the known duration")
    // search 404 after a plain get: fall back to the get text
    resetStub { r in isGet(r) ? (200, json(plainHit(plain: "get only plain"))) : (404, Data()) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]))?.lines.first?.text == "get only plain", "plain get, search 404: get's plain used")
    // duration unknown: falls back to the result's own length
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([plainHit("River & Moon", "Paper Lanterns", 100, plain: "one invented line")])) }
    let own = fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), duration: nil)
    check(abs((own?.lines.first?.start ?? 0) - 8) < 1e-9, "no duration: estimate uses the track's own duration")
}
do {
    // synced result among plain ones: synced wins even when the plain one is a closer match
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([plainHit("River & Moon", "Paper Lanterns", 200),
        hit("River & Moon", "Paper Lanterns", 202, "synced far-ish")])) }
    let l = fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]))
    check(l?.lines.first?.text == "synced far-ish" && l?.isEstimated == false, "search: synced beats a closer plain-only result")
}
do {
    // instrumental: none, no search for get; flagged search results are skipped
    resetStub { _ in (200, json(["instrumental": true, "plainLyrics": plainText])) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil && reqCount() == 2 && cacheFiles(dir).count == 1, "instrumental with plain text: none")
    check(isNone(searchResult(results: [plainHit(instrumental: true)])), "instrumental search result with plain text: none")
}
do {
    // empty plain: none
    resetStub { r in isGet(r) ? (200, json(["plainLyrics": "  \n ", "instrumental": false])) : (200, json([plainHit(plain: "")])) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil && cacheFiles(dir).count == 1, "empty plain everywhere: none, negative cached")
    check(isNone(searchResult(results: [plainHit(plain: "")])), "empty plainLyrics search result: none")
}
do {
    // wrong title / mismatched artist and length: rejected
    check(isNone(searchResult(results: [plainHit("Different Song")])), "wrong-title plain result rejected")
    check(isNone(searchResult(results: [plainHit("River & Moon", "Someone Else Entirely", 240)])), "plain result with wrong artist and length rejected")
    check(searchResult(results: [plainHit("River & Moon", "Someone Else Entirely", 201)]).flatMap(lyricsOf)?.isEstimated == true, "plain result accepted by length like synced ones")
    check(searchResult(results: [plainHit("River & Moon (feat. Someone Invented)")]).flatMap(lyricsOf)?.isEstimated == true, "plain result title normalization same as synced")
}
do {
    // old-version cache (a negative entry from before plain support) is refetched
    let dir = tmpDir()
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let old: [String: Any] = ["version": 3, "fetchedAt": Date().timeIntervalSince1970]
    try! json(old).write(to: dir.appendingPathComponent(LyricsProvider.cacheFileName(for: "t1")))
    resetStub { r in isGet(r) ? (200, json(plainHit())) : (200, json([plainHit()])) }
    let first = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(reqCount() >= 1 && first?.isEstimated == true, "version 3 'none' entry ignored and plain lyrics fetched")
    let before = reqCount()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == first && reqCount() == before, "refetched entry rewritten at the current version")
}
do {
    // a current-version entry written before isEstimated existed still decodes
    let dir = tmpDir()
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let entry: [String: Any] = ["version": LYRICS_CACHE_VERSION, "fetchedAt": Date().timeIntervalSince1970,
                                "lyrics": ["lines": [["start": 1, "end": 5, "text": "cached invented"]]]]
    try! json(entry).write(to: dir.appendingPathComponent(LyricsProvider.cacheFileName(for: "t1")))
    resetStub { _ in (500, Data()) }
    let l = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(l?.lines.first?.text == "cached invented" && l?.isEstimated == false && reqCount() == 0, "cache entry without isEstimated decodes as exact")
}


// MARK: cancellation and cache peek
// Tracks are told apart by title: "Cancel One" is held in flight, "Cancel Two" is a bystander
func lookup(_ p: LyricsProvider, id: String, title: String, done: @escaping (LookupOutcome) -> Void) {
    p.lyrics(trackID: id, artist: "Paper Lanterns", title: title, album: "Night", duration: 200, completion: done)
}
func outcomeName(_ o: LookupOutcome) -> String {
    switch o { case .found: return "found"; case .none: return "none"; case .failed: return "failed" }
}
do {
    // cancel while the request is in flight: no completion, no cache, the task is stopped
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    Stub.holdMatching = ["Cancel%20One"]
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])
    var calls: [String] = []
    lookup(p, id: "c1", title: "Cancel One") { calls.append("c1 \(outcomeName($0))") }
    spin { requestCount(containing: "Cancel%20One") == 2 }  // get and search
    p.cancel(trackID: "c1")
    spin { stoppedCount() == 2 }
    check(stoppedCount() == 2, "cancel: both in-flight URLSessionTasks are cancelled")
    Stub.releaseHeld()
    wait(0.3)
    check(calls.isEmpty, "cancel in flight: no completion side effects")
    check(cacheFiles(dir).isEmpty && p.cachedLyrics(trackID: "c1") == nil, "cancel in flight: no negative cache entry")
    check(reqCount() == 2, "cancel in flight: no retry or follow-up request")
}
do {
    // other tracks' waiters are unaffected by a cancel, and a cancelled id can be asked again
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    Stub.holdMatching = ["Cancel%20One", "Cancel%20Two"]
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])
    var calls: [String] = []
    lookup(p, id: "c1", title: "Cancel One") { calls.append("c1 \(outcomeName($0))") }
    lookup(p, id: "c2", title: "Cancel Two") { calls.append("c2 \(outcomeName($0))") }
    lookup(p, id: "c2", title: "Cancel Two") { calls.append("c2b \(outcomeName($0))") }  // a second waiter, same id
    spin { requestCount(containing: "Cancel%20One") == 2 && requestCount(containing: "Cancel%20Two") == 2 }
    p.cancel(trackID: "c1")
    Stub.holdMatching = []
    Stub.releaseHeld()
    spin { calls.count == 2 }
    check(calls.sorted() == ["c2 found", "c2b found"], "cancel: other track's waiters still complete, the cancelled one doesn't")
    check(cacheFiles(dir).count == 1 && p.cachedLyrics(trackID: "c2") != nil, "cancel: only the other track was cached")
    check(requestCount(containing: "Cancel%20Two") == 2, "cancel: other track's requests not repeated")
    // asking about the cancelled id again starts fresh and completes normally
    var again: LookupOutcome?
    lookup(p, id: "c1", title: "Cancel One") { again = $0 }
    spin { again != nil }
    check(again.flatMap(lyricsOf) != nil && !calls.contains { $0.hasPrefix("c1") }, "cancel: the same id can be looked up again, the old completion stays silent")
    p.cancel(trackID: "never-asked")
    p.cancel(trackID: "c1")  // already finished: nothing to cancel
    check(true, "cancel: unknown and finished ids are no-ops")
}
do {
    // cancel during a retry wait: the timer never fires, nothing is cached, nothing completes
    resetStub { _ in (503, Data()) }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0.4, 0.4])
    var calls = 0
    lookup(p, id: "c1", title: "Cancel One") { _ in calls += 1 }
    spin { reqCount() == 2 }
    wait(0.1)  // both 503s are in; the retry timers wait
    p.cancel(trackID: "c1")
    wait(1.2)  // well past both retry delays
    check(reqCount() == 2, "cancel during a retry wait: the retry never fires")
    check(calls == 0, "cancel during a retry wait: no completion")
    check(cacheFiles(dir).isEmpty, "cancel during a retry wait: no negative cache entry")
}
do {
    // a retry timer for one track keeps running while another track is cancelled
    let twoGets = Counter()
    resetStub { r in
        if !isGet(r) { return (404, Data()) }
        let isFirstTwoGet = r.url!.absoluteString.contains("Cancel%20Two") && twoGets.next() == 1
        return isFirstTwoGet ? (503, Data()) : (200, json(["syncedLyrics": lrcA]))
    }
    let p = LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0.3, 0.3])
    var two: LookupOutcome?
    var oneCalls = 0
    lookup(p, id: "c2", title: "Cancel Two") { two = $0 }
    lookup(p, id: "c1", title: "Cancel One") { _ in oneCalls += 1 }
    p.cancel(trackID: "c1")
    spin { two != nil }
    check(two.flatMap(lyricsOf) != nil && requestCount(containing: "Cancel%20Two") == 3, "cancel: another track's pending retry still fires and completes")
    check(oneCalls == 0, "cancel: the cancelled track stays silent")
}
do {
    // cachedLyrics: hit, negative hit, expired negative, miss, old version
    var clock = Date()
    resetStub { r in isGet(r) ? (200, json(["syncedLyrics": lrcA])) : (200, json([])) }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, now: { clock }, retryDelays: [0, 0])
    check(p.cachedLyrics(trackID: "k1") == nil, "cachedLyrics: miss is nil")
    _ = fetch(p, id: "k1")
    check(p.cachedLyrics(trackID: "k1").flatMap(lyricsOf)?.lines.count == 2, "cachedLyrics: found entry")
    check(p.cachedLyrics(trackID: "  k1 \n").flatMap(lyricsOf) != nil, "cachedLyrics: id trimmed like lookups")
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([])) }
    _ = fetch(p, id: "k2")
    if case .some(.none) = p.cachedLyrics(trackID: "k2") { check(true, "cachedLyrics: negative entry is a none") } else { check(false, "cachedLyrics: negative entry is a none") }
    clock = clock.addingTimeInterval(LYRICS_NEGATIVE_CACHE_TTL + 1)
    check(p.cachedLyrics(trackID: "k2") == nil, "cachedLyrics: expired negative is a miss")
    if case .some(.none) = p.cachedLyrics(trackID: "") { check(true, "cachedLyrics: empty id is a none") } else { check(false, "cachedLyrics: empty id is a none") }
    let before = reqCount()
    _ = p.cachedLyrics(trackID: "k1")
    check(reqCount() == before, "cachedLyrics never touches the network")
}

// MARK: race (get and search run at the same time)
nonisolated func isSearch(_ r: URLRequest) -> Bool { r.url!.path.hasSuffix("/search") }
func stoppedCount(containing text: String) -> Int {
    Stub.lock.lock(); defer { Stub.lock.unlock() }
    return Stub.stoppedURLs.filter { $0.absoluteString.contains(text) }.count
}
nonisolated func searchSynced(_ lyric: String) -> Data { json([hit("River & Moon", "Paper Lanterns", 200, lyric)]) }
nonisolated func getSynced(_ lyric: String) -> Data { json(["syncedLyrics": "[00:01.00] \(lyric)", "duration": 200]) }
func raceLookup(_ p: LyricsProvider, id: String = "race", _ done: @escaping (LookupOutcome) -> Void) {
    lookup(p, id: id, title: "River & Moon", done: done)
}
do {
    // get keeps answering 503 (its retries are slow), search is synced: no waiting for get's retries
    resetStub { r in isGet(r) ? (503, Data()) : (200, searchSynced("search synced")) }
    Stub.holdMatching = ["/api/search"]
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0.5, 0.5, 0.5])
    var outs: [LookupOutcome] = []
    raceLookup(p) { outs.append($0) }
    spin { requestCount(containing: "/api/get") == 1 }
    wait(0.1)  // get's 503 is in; its retry timer waits
    let start = Date()
    Stub.holdMatching = []; Stub.releaseHeld()
    spin { !outs.isEmpty }
    check(outs.count == 1 && text(outs[0]) == "search synced", "race: get 503s, search synced: synced result")
    check(Date().timeIntervalSince(start) < 0.3, "race: result arrives without waiting for get's retries")
    wait(1.8)  // past every get retry delay
    check(requestCount(containing: "/api/get") == 1, "race: get's pending retry is cancelled once search wins")
    check(cacheFiles(dir).count == 1 && outs.count == 1, "race: synced result cached once, one completion")
}
do {
    // get hangs in flight, search is synced: get's URLSessionTask is cancelled
    resetStub { r in isGet(r) ? (200, getSynced("never delivered")) : (200, searchSynced("search wins")) }
    Stub.holdMatching = ["/api/get"]
    let p = LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0, 0])
    var outs: [LookupOutcome] = []
    raceLookup(p) { outs.append($0) }
    spin { !outs.isEmpty }
    check(outs.count == 1 && text(outs[0]) == "search wins", "race: search synced completes while get hangs")
    check(requestCount(containing: "/api/get") == 1 && stoppedCount(containing: "/api/get") == 1, "race: get's in-flight request is cancelled")
    Stub.holdMatching = []; Stub.releaseHeld()
    wait(0.2)
    check(outs.count == 1, "race: the cancelled get never completes again")
}
do {
    // get synced quickly, search hangs: completes at once, search cancelled
    resetStub { r in isGet(r) ? (200, getSynced("get wins")) : (200, searchSynced("search late")) }
    Stub.holdMatching = ["/api/search"]
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0, 0])
    var outs: [LookupOutcome] = []
    let start = Date()
    raceLookup(p) { outs.append($0) }
    spin { !outs.isEmpty }
    check(outs.count == 1 && text(outs[0]) == "get wins", "race: get synced beats a hanging search")
    check(Date().timeIntervalSince(start) < 0.5 && requestCount(containing: "/api/search") == 1, "race: get synced completes immediately, search was fired concurrently")
    check(stoppedCount(containing: "/api/search") == 1 && cacheFiles(dir).count == 1, "race: hanging search cancelled, result cached")
    Stub.holdMatching = []; Stub.releaseHeld(); wait(0.2)
    check(outs.count == 1, "race: no second completion")
}
do {
    // get plain, search 503 once then synced: synced wins
    let n = Counter()
    resetStub { r in
        if isGet(r) { return (200, json(plainHit(plain: "get plain one\nget plain two"))) }
        return n.next() == 1 ? (503, Data()) : (200, searchSynced("search synced later"))
    }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0.1, 0.1, 0.1])
    var out: LookupOutcome?
    raceLookup(p) { out = $0 }
    spin { out != nil }
    check(text(out) == "search synced later" && lyricsOf(out ?? .failed)?.isEstimated == false, "race: plain get waits for search's retry, synced wins")
    check(requestCount(containing: "/api/search") == 2 && cacheFiles(dir).count == 1, "race: synced from the retried search cached")
}
do {
    // get plain while search is still pending: wait, do not decide yet
    resetStub { r in isGet(r) ? (200, json(plainHit(plain: "get plain one"))) : (200, searchSynced("search synced")) }
    Stub.holdMatching = ["/api/search"]
    let p = LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0, 0])
    var out: LookupOutcome?
    raceLookup(p) { out = $0 }
    spin { requestCount(containing: "/api/get") == 1 }
    wait(0.3)
    check(out == nil, "race: plain get does not complete while search is pending")
    Stub.holdMatching = []; Stub.releaseHeld()
    spin { out != nil }
    check(text(out) == "search synced", "race: pending search answers synced after a plain get")
}
do {
    // get plain, search exhausts its retries: plain used (estimated), nothing cached
    resetStub { r in isGet(r) ? (200, json(plainHit(plain: "get plain one\nget plain two"))) : (503, Data()) }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0, 0])
    var out: LookupOutcome?
    raceLookup(p) { out = $0 }
    spin { out != nil }
    let l = lyricsOf(out ?? .failed)
    check(l?.isEstimated == true && l?.lines.first?.text == "get plain one", "race: plain get + search exhausted: plain used, estimated")
    check(requestCount(containing: "/api/search") == 4 && cacheFiles(dir).isEmpty, "race: partial answer is not cached (no negative either)")
    check(p.cachedLyrics(trackID: "race") == nil, "race: nothing to peek after a partial answer")
}
do {
    // get instrumental: none at once, search cancelled, definitive so cached
    resetStub { r in isGet(r) ? (200, json(["instrumental": true])) : (200, searchSynced("x")) }
    Stub.holdMatching = ["/api/search"]
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0, 0])
    var out: LookupOutcome?
    raceLookup(p) { out = $0 }
    spin { out != nil }
    check(isNone(out) && cacheFiles(dir).count == 1, "race: instrumental get gives none without waiting for search")
    check(stoppedCount(containing: "/api/search") == 1, "race: search cancelled after an instrumental get")
}
do {
    // both fail: nil, no cache
    resetStub { _ in (503, Data()) }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0.05, 0.05, 0.05])
    var out: LookupOutcome?
    let start = Date()
    raceLookup(p) { out = $0 }
    spin { out != nil }
    check(out.map(outcomeName) == "failed" && cacheFiles(dir).isEmpty, "race: both endpoints failing: failed, no cache")
    check(Date().timeIntervalSince(start) < 8, "race: both failing stays under the 8 s budget")
    check(requestCount(containing: "/api/get") == 4 && requestCount(containing: "/api/search") == 4, "race: each endpoint tried 1 + 3 retries")
}
do {
    // cancel mid-race, both requests in flight
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    Stub.holdMatching = ["/api/get", "/api/search"]
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0, 0])
    var calls = 0
    raceLookup(p) { _ in calls += 1 }
    spin { reqCount() == 2 }
    p.cancel(trackID: "race")
    spin { stoppedCount() == 2 }
    check(stoppedCount(containing: "/api/get") == 1 && stoppedCount(containing: "/api/search") == 1, "race cancel: both in-flight requests cancelled")
    Stub.holdMatching = []; Stub.releaseHeld(); wait(0.3)
    check(calls == 0 && cacheFiles(dir).isEmpty && reqCount() == 2, "race cancel: no completion, no cache, no follow-up request")
}
do {
    // cancel while both legs wait for a retry
    resetStub { _ in (503, Data()) }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0.4, 0.4, 0.4])
    var calls = 0
    raceLookup(p) { _ in calls += 1 }
    spin { reqCount() == 2 }
    wait(0.1)
    p.cancel(trackID: "race")
    wait(1.5)
    check(reqCount() == 2 && calls == 0 && cacheFiles(dir).isEmpty, "race cancel: both retry timers cancelled, nothing completes or caches")
}

// MARK: jitter, budget, breaker
do {
    check(LYRICS_RETRY_DELAYS == [0.4, 1.2, 3] && LYRICS_RETRY_JITTER == 0.3 && LYRICS_LOOKUP_BUDGET == 8, "retry policy constants: 0.4/1.2/3 s, 30% jitter, 8 s budget")
    for base in LYRICS_RETRY_DELAYS {
        check(abs(LyricsProvider.jitteredDelay(base, unit: 0) - base * 0.7) < 1e-9, "jitter: unit 0 gives -30% of \(base)")
        check(abs(LyricsProvider.jitteredDelay(base, unit: 1) - base * 1.3) < 1e-9, "jitter: unit 1 gives +30% of \(base)")
        check(abs(LyricsProvider.jitteredDelay(base, unit: 0.5) - base) < 1e-9, "jitter: unit 0.5 gives the base \(base)")
    }
    let samples = (0..<2000).map { _ in LyricsProvider.jitteredDelay(1.2, unit: Double.random(in: 0...1)) }
    check(samples.allSatisfy { $0 >= 1.2 * 0.7 - 1e-9 && $0 <= 1.2 * 1.3 + 1e-9 } && Set(samples).count > 100, "jitter: random samples stay in +-30% and vary")
    check(LyricsProvider.jitteredDelay(1, unit: -5) == 0.7 && LyricsProvider.jitteredDelay(1, unit: 9) == 1.3, "jitter: out-of-range dice clamp to the bounds")
    check(LyricsProvider.jitteredDelay(0, unit: 0.8) == 0, "jitter: zero base stays zero")
}
do {
    // the injected dice roll is used once per scheduled retry (3 per endpoint)
    resetStub { _ in (503, Data()) }
    let rolls = Counter()
    let p = LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0, 0], randomUnit: { _ = rolls.next(); return 0.5 })
    var out: LookupOutcome?
    raceLookup(p) { out = $0 }
    spin { out != nil }
    check(rolls.next() == 7, "jitter: one dice roll per retry (6), injected source used")
}
do {
    // the budget cuts off slow retries: failed, no cache, on time
    resetStub { _ in (503, Data()) }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [5, 5, 5], budget: 0.5, randomUnit: { 0.5 })
    var outs: [LookupOutcome] = []
    let start = Date()
    raceLookup(p) { outs.append($0) }
    spin { !outs.isEmpty }
    let elapsed = Date().timeIntervalSince(start)
    check(outs.count == 1 && outcomeName(outs[0]) == "failed" && elapsed >= 0.45 && elapsed < 1.2, "budget: both endpoints stuck in backoff: failed at the budget")
    wait(0.3)
    check(cacheFiles(dir).isEmpty && reqCount() == 2 && outs.count == 1, "budget: nothing cached, no retries after the budget, one completion")
}
do {
    // budget with a plain answer from get: plain used (estimated), uncached
    resetStub { r in isGet(r) ? (200, json(plainHit(plain: "get plain one"))) : (503, Data()) }
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [5, 5, 5], budget: 0.4, randomUnit: { 0.5 })
    var out: LookupOutcome?
    raceLookup(p) { out = $0 }
    spin { out != nil }
    check(lyricsOf(out ?? .failed)?.isEstimated == true && cacheFiles(dir).isEmpty, "budget: plain get kept when search never recovers, not cached")
}
do {
    // breaker: more than 5 consecutive 5xx across lookups opens it; get is skipped for 60 s
    resetStub { _ in (503, Data()) }
    var clock = Date(timeIntervalSince1970: 2_000_000)
    let p = LyricsProvider(cacheDirectory: tmpDir(), session: session, now: { clock }, retryDelays: [0, 0], randomUnit: { 0.5 })
    var out: LookupOutcome?
    raceLookup(p, id: "b1") { out = $0 }  // 6 responses of 503: opens the breaker
    spin { out != nil }
    check(requestCount(containing: "/api/get") == 3 && requestCount(containing: "/api/search") == 3, "breaker: first lookup tries both endpoints")
    resetStub { r in isGet(r) ? (200, getSynced("get back")) : (200, searchSynced("search only")) }
    out = nil
    raceLookup(p, id: "b2") { out = $0 }
    spin { out != nil }
    check(requestCount(containing: "/api/get") == 0 && text(out) == "search only", "breaker open: search only, get skipped")
    clock = clock.addingTimeInterval(LYRICS_BREAKER_OPEN_FOR - 1)
    out = nil
    raceLookup(p, id: "b3") { out = $0 }
    spin { out != nil }
    check(requestCount(containing: "/api/get") == 0, "breaker still open just before 60 s")
    clock = clock.addingTimeInterval(2)
    out = nil
    raceLookup(p, id: "b4") { out = $0 }
    spin { out != nil }
    check(requestCount(containing: "/api/get") == 1 && text(out) == "get back", "breaker closed after 60 s: get is raced again")
}
do {
    // breaker: skipped get never turns a miss into a cached negative
    resetStub { _ in (503, Data()) }
    let clock = Date(timeIntervalSince1970: 3_000_000)
    let dir = tmpDir()
    let p = LyricsProvider(cacheDirectory: dir, session: session, now: { clock }, retryDelays: [0, 0], randomUnit: { 0.5 })
    var out: LookupOutcome?
    raceLookup(p, id: "m1") { out = $0 }
    spin { out != nil }
    resetStub { _ in (200, json([[String: Any]]())) }
    out = nil
    raceLookup(p, id: "m2") { out = $0 }
    spin { out != nil }
    check(outcomeName(out ?? .none) == "failed" && cacheFiles(dir).isEmpty && requestCount(containing: "/api/get") == 0, "breaker open: an empty search is not a definitive miss, nothing cached")
    // 5xx streaks need to be consecutive and inside the window
    resetStub { r in isGet(r) ? (503, Data()) : (404, Data()) }
    let q = LyricsProvider(cacheDirectory: tmpDir(), session: session, now: { clock }, retryDelays: [0, 0], randomUnit: { 0.5 })
    out = nil
    raceLookup(q, id: "s1") { out = $0 }  // 3 x 503 on get, a 404 resets the streak
    spin { out != nil }
    resetStub { _ in (200, getSynced("x")) }
    out = nil
    raceLookup(q, id: "s2") { out = $0 }
    spin { out != nil }
    check(requestCount(containing: "/api/get") == 1, "breaker: a good reply between 5xx keeps it closed")
}

// MARK: romaji
do {
    let r = LyricsProvider.romaji(for: "ひかりの なかで あるく")
    check(r != nil && !r!.isEmpty, "romaji non-nil")
    check(r.map { $0.unicodeScalars.allSatisfy { $0.value < 0x3000 } } ?? false, "romaji is Latin")
    print("  romaji:", r ?? "nil")
    check(LyricsProvider.romaji(for: "桜の花びら") != nil, "kanji romaji")
    check(LyricsProvider.romaji(for: "paper lanterns drift") == nil, "latin nil")
    check(LyricsProvider.romaji(for: "") == nil, "empty nil")
}

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("ALL PASSED")
