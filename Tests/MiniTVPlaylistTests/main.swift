// MiniTVPlaylist: seeding, load/save round trip, broken-file tolerance,
// unsafe names, add/remove (immutable) and URL resolution. Temp dirs only.
import Foundation

var failed = false
func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failed = true }
}

let fm = FileManager.default
func makeDir() -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("playlist-tests-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
func touch(_ dir: URL, _ name: String) {
    fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8))
}

// seeding when no playlist file exists
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    let playlist = MiniTVPlaylist.load(from: dir, seed: ["first-clip.mp4", "second.mov"])
    check("missing file: seeded from defaults", playlist.videos.map(\.file) == ["first-clip.mp4", "second.mov"])
    check("seeded title comes from the file name", playlist.videos.first?.title == "first clip")
    check("seeded entries have no YouTube id", playlist.videos.allSatisfy { $0.youtubeID == nil })
}

// save / load round trip
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    let playlist = MiniTVPlaylist(videos: [
        MiniTVVideo(file: "a.mp4", title: "A", youtubeID: "abcdefghijk"),
        MiniTVVideo(file: "b.mp4", title: "B", youtubeID: nil),
    ])
    try playlist.save(to: dir)
    let loaded = MiniTVPlaylist.load(from: dir, seed: ["ignored.mp4"])
    check("round trip keeps every entry", loaded == playlist)
    let leftovers = try fm.contentsOfDirectory(atPath: dir.path).filter { $0 != MiniTVPlaylist.fileName }
    check("atomic save leaves no temp files", leftovers.isEmpty)
} catch {
    check("round trip did not throw: \(error)", false)
}

// a broken file is kept aside, never silently overwritten
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent(MiniTVPlaylist.fileName)
    try! Data("{not json".utf8).write(to: file)
    let playlist = MiniTVPlaylist.load(from: dir, seed: ["seed.mp4"])
    check("broken file: falls back to seed", playlist.videos.map(\.file) == ["seed.mp4"])
    let broken = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasPrefix(MiniTVPlaylist.fileName + ".broken") } ?? []
    check("broken file: moved aside for inspection", broken.count == 1)
}

// an unreadable (not missing) file is kept aside too, and earlier .broken copies survive
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    let file = dir.appendingPathComponent(MiniTVPlaylist.fileName)
    try! fm.createDirectory(at: file, withIntermediateDirectories: false)  // a folder can't be read as data
    let first = MiniTVPlaylist.load(from: dir, seed: ["seed.mp4"])
    check("unreadable file: falls back to seed", first.videos.map(\.file) == ["seed.mp4"])
    try! Data("{bad".utf8).write(to: file)
    _ = MiniTVPlaylist.load(from: dir, seed: [])
    let broken = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.contains(".broken") } ?? []
    check("unreadable file: moved aside, nothing overwritten", !fm.fileExists(atPath: file.path) && broken.count == 2)
}

// entries with unsafe file names are dropped on load
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    let json = #"{"videos":[{"file":"ok.mp4","title":"ok"},{"file":"../escape.mp4","title":"x"},{"file":".hidden.mp4","title":"x"},{"file":"notes.txt","title":"x"},{"file":"sub/dir.mp4","title":"x"}]}"#
    try! Data(json.utf8).write(to: dir.appendingPathComponent(MiniTVPlaylist.fileName))
    let playlist = MiniTVPlaylist.load(from: dir, seed: [])
    check("unsafe names dropped, safe kept", playlist.videos.map(\.file) == ["ok.mp4"])
}

check("safe name: plain mp4", MiniTVPlaylist.isSafeFileName("clip-1.mp4"))
check("safe name: mov and m4v", MiniTVPlaylist.isSafeFileName("a.MOV") && MiniTVPlaylist.isSafeFileName("b.m4v"))
check("unsafe name: path separator", !MiniTVPlaylist.isSafeFileName("a/b.mp4"))
check("unsafe name: empty stem", !MiniTVPlaylist.isSafeFileName(".mp4"))
check("unsafe name: other extension", !MiniTVPlaylist.isSafeFileName("a.mkv"))

// add / remove return new values and leave the original untouched
do {
    let original = MiniTVPlaylist(videos: [MiniTVVideo(file: "a.mp4", title: "A", youtubeID: "aaaaaaaaaaa")])
    let added = original.adding(MiniTVVideo(file: "b.mp4", title: "B", youtubeID: "bbbbbbbbbbb"))
    check("adding appends", added.videos.map(\.file) == ["a.mp4", "b.mp4"])
    check("adding leaves the original unchanged", original.videos.count == 1)
    let replaced = added.adding(MiniTVVideo(file: "a.mp4", title: "A2", youtubeID: nil))
    check("adding an existing file replaces it in place",
          replaced.videos.map(\.file) == ["a.mp4", "b.mp4"] && replaced.videos[0].title == "A2")
    let removed = added.removing(file: "a.mp4")
    check("removing drops only that file", removed.videos.map(\.file) == ["b.mp4"])
    check("removing leaves the original unchanged", added.videos.count == 2)
    check("contains YouTube id", added.contains(youtubeID: "bbbbbbbbbbb") && !added.contains(youtubeID: "ccccccccccc"))
}

// URLs only for files that exist
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    touch(dir, "here.mp4")
    let playlist = MiniTVPlaylist(videos: [
        MiniTVVideo(file: "here.mp4", title: "here", youtubeID: nil),
        MiniTVVideo(file: "gone.mp4", title: "gone", youtubeID: nil),
    ])
    check("urls skip missing files", playlist.urls(in: dir).map(\.lastPathComponent) == ["here.mp4"])
}

exit(failed ? 1 : 0)
