import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("PASS \(name)") } else { print("FAIL \(name)"); failures += 1 }
}

// MARK: stub
final class Stub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data)?)?  // nil = network error
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Stub.lock.lock(); Stub.requests.append(request); Stub.lock.unlock()
        guard let (status, body) = Stub.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
func resetStub(_ h: @escaping (URLRequest) -> (Int, Data)?) { Stub.lock.lock(); Stub.requests = []; Stub.lock.unlock(); Stub.handler = h }
func reqCount() -> Int { Stub.lock.lock(); defer { Stub.lock.unlock() }; return Stub.requests.count }
let cfg = URLSessionConfiguration.ephemeral
cfg.protocolClasses = [Stub.self]
let session = URLSession(configuration: cfg)

func json(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }
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
            ["duration": 250, "syncedLyrics": "[00:01.00] wrong length"],
            ["duration": 201.5, "syncedLyrics": "[00:01.00] right length"],
            ["duration": 200, "plainLyrics": "plain only"],
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
        return (200, json([["duration": 999, "syncedLyrics": "[00:01.00] only candidate"]]))
    }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]))?.lines.first?.text == "only candidate", "search falls back to first synced")
}
do {
    resetStub { _ in (200, json(["plainLyrics": "plain only", "instrumental": false])) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0])) == nil, "plain-only nil")
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
    check(fetch(p)?.lines.count == 2 && reqCount() == 1, "negative cache expired, refetched")
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
    check(results.count == 3 && results.allSatisfy { $0 != nil } && reqCount() == 1, "in-flight dedup")
}
do {
    check(LyricsProvider.cacheFileName(for: "spotify:track:abc") != LyricsProvider.cacheFileName(for: "spotify_track_abc"), "file names collision-free")
    check(!LyricsProvider.cacheFileName(for: "../../etc/x").contains("/"), "file name sanitized")
}


// MARK: fallthrough, retry, versioning
func isGet(_ r: URLRequest) -> Bool { r.url!.path.hasSuffix("/get") }
func cacheFiles(_ d: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] }
func fetchArtist(_ p: LyricsProvider, artist: String, duration: TimeInterval?) -> TimedLyrics? {
    var done = false; var out: TimedLyrics?
    p.lyrics(trackID: "art", artist: artist, title: "t", album: "al", duration: duration) { out = lyricsOf($0); done = true }
    spin { done }
    return out
}
do {
    resetStub { r in isGet(r) ? (200, json(["plainLyrics": "plain", "syncedLyrics": NSNull(), "instrumental": false]))
        : (200, json([["artistName": "Paper Lanterns", "duration": 201, "syncedLyrics": "[00:01.00] from search"]])) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]))?.lines.first?.text == "from search", "get plain-only falls through to search")
    check(reqCount() == 2, "plain-only made get+search")
}
do {
    resetStub { _ in (200, json(["instrumental": true])) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil && reqCount() == 1, "get instrumental: no search")
    check(cacheFiles(dir).count == 1, "instrumental negative cached")
}
do {
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([
        ["artistName": "paper lanterns", "duration": 205, "syncedLyrics": "[00:01.00] far"],
        ["artistName": "PAPER LANTERNS", "duration": 199, "syncedLyrics": "[00:01.00] closest"],
        ["artistName": "paper lanterns", "duration": 202.5, "syncedLyrics": "[00:01.00] near"],
    ])) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), duration: 200)?.lines.first?.text == "closest", "search picks closest duration within 3s")
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), duration: nil)?.lines.first?.text == "far", "no duration: first synced")
}
do {
    resetStub { r in isGet(r) ? (404, Data()) : (200, json([
        ["artistName": "Someone Else", "duration": 200, "syncedLyrics": "[00:01.00] cover"],
        ["artistName": "Paper Lanterns", "duration": 230, "syncedLyrics": "[00:01.00] mine"],
    ])) }
    check(fetchArtist(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), artist: "paper lanterns", duration: 200)?.lines.first?.text == "mine", "artist mismatch skipped")
    check(fetchArtist(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0]), artist: "Nobody Matches", duration: 200)?.lines.first?.text == "cover", "no artist match: keep all")
}
do {
    var n = 0
    resetStub { r in n += 1; return n == 1 ? (503, Data()) : (200, json(["syncedLyrics": lrcA])) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0])) != nil && reqCount() == 2, "503 then 200 retried")
}
do {
    resetStub { _ in (503, Data()) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil, "three 503s nil")
    check(reqCount() == 3 && cacheFiles(dir).isEmpty, "3 attempts, no negative cache file")
    resetStub { _ in (429, Data()) }
    _ = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(reqCount() == 3, "429 retried")
    resetStub { _ in (400, Data()) }
    _ = fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0]))
    check(reqCount() == 1, "400 not retried")
}
do {
    var n = 0
    resetStub { _ in n += 1; return n == 1 ? nil : (200, json(["syncedLyrics": lrcA])) }
    check(fetch(LyricsProvider(cacheDirectory: tmpDir(), session: session, retryDelays: [0, 0])) != nil && reqCount() == 2, "URL error retried")
    // search retries too; get plain-only then search 503 x3 -> no cache
    resetStub { r in isGet(r) ? (200, json(["plainLyrics": "p"])) : (503, Data()) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil && cacheFiles(dir).isEmpty && reqCount() == 4, "search retried, failure not cached")
}
do {
    // old-version cache ignored
    let dir = tmpDir()
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = LyricsProvider.cacheFileName(for: "t1")
    let old: [String: Any] = ["version": 1, "fetchedAt": Date().timeIntervalSince1970]
    try! json(old).write(to: dir.appendingPathComponent(name))
    resetStub { _ in (200, json(["syncedLyrics": lrcA])) }
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) != nil && reqCount() == 1, "old-version cache ignored")
}
do {
    // negative cache only after definitive search miss
    resetStub { r in isGet(r) ? (200, json(["plainLyrics": "p"])) : (200, json([[String: Any]]())) }
    let dir = tmpDir()
    check(fetch(LyricsProvider(cacheDirectory: dir, session: session, retryDelays: [0, 0])) == nil && cacheFiles(dir).count == 1, "definitive miss writes negative")
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
