// VideoLibrary: seeding the playlist file, link rejection, duplicate guards,
// a full background import with a fake runner (main-thread callbacks), the
// missing-tool error and removal. Temp dirs and a fake Trash only.
import Foundation

var failed = false
func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failed = true }
}

let fm = FileManager.default
func makeDir() -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("library-tests-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// Waits on the main run loop so background imports can hop back
func spin(until done: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return done()
}

// Answers like yt-dlp / ffprobe / ffmpeg would, creating the files they would create
nonisolated struct FakeRunner: ProcessRunning {
    func run(_ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult {
        switch executable.lastPathComponent {
        case "yt-dlp":
            let template = arguments[arguments.firstIndex(of: "-o")! + 1]
            FileManager.default.createFile(atPath: template.replacingOccurrences(of: "%(ext)s", with: "mp4"), contents: Data("v".utf8))
            onLine("TITLE New Clip")
            onLine("PROGRESS 50.0%")
            return ProcessResult(status: 0, stdout: "", stderr: "")
        case "ffprobe":
            return ProcessResult(status: 0, stdout: "h264,video\naac,audio\n", stderr: "")
        default:
            if arguments.contains("null") {
                return ProcessResult(status: 0, stdout: "", stderr:
                    #"{"input_i" : "-14.01", "input_tp" : "-2.00", "input_lra" : "5.00", "input_thresh" : "-24.00", "target_offset" : "0.01"}"#)
            }
            FileManager.default.createFile(atPath: arguments.last!, contents: Data("n".utf8))
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
    }
}

let tools = MediaTools(ytDlp: URL(fileURLWithPath: "/fake/yt-dlp"), ffmpeg: URL(fileURLWithPath: "/fake/ffmpeg"),
                       ffprobe: URL(fileURLWithPath: "/fake/ffprobe"))

// leftovers from an import interrupted by a quit are swept
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    let stale = dir.appendingPathComponent(".import-OLD", isDirectory: true)
    try! fm.createDirectory(at: stale, withIntermediateDirectories: true)
    _ = VideoLibrary(directory: dir, seed: [], runner: FakeRunner(), locateTools: { .success(tools) })
    check("stale import dirs removed", !fm.fileExists(atPath: stale.path))
}

// seeding writes the playlist file once
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    fm.createFile(atPath: dir.appendingPathComponent("old.mp4").path, contents: Data())
    let library = VideoLibrary(directory: dir, seed: ["old.mp4"], runner: FakeRunner(), locateTools: { .success(tools) })
    check("seed: playlist has the seeded file", library.playlist.videos.map(\.file) == ["old.mp4"])
    check("seed: playlist file written", fm.fileExists(atPath: dir.appendingPathComponent(MiniTVPlaylist.fileName).path))
    check("seed: urls resolve", library.videoURLs.map(\.lastPathComponent) == ["old.mp4"])
}

// a full import
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    let library = VideoLibrary(directory: dir, seed: [], runner: FakeRunner(), locateTools: { .success(tools) })
    var playlistUpdates: [[URL]] = []
    var sawBusy = false
    library.onPlaylistChange = { playlistUpdates.append($0) }
    library.onChange = { if library.status.isBusy { sawBusy = true } }

    check("invalid link rejected", !library.add(link: "https://vimeo.com/1"))
    check("invalid link: error status", library.status.isError)

    check("valid link accepted", library.add(link: "https://youtu.be/dQw4w9WgXcQ"))
    check("same link while downloading rejected", !library.add(link: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
    check("import finished", spin { !library.status.isBusy && !library.playlist.videos.isEmpty })
    check("import: busy status shown while working", sawBusy)
    check("import: added to playlist", library.playlist.videos.map(\.file) == ["new-clip.mp4"])
    check("import: status says added", library.status.text == "Added New Clip" && !library.status.isError)
    check("import: TVs told about the new list", playlistUpdates.last?.map(\.lastPathComponent) == ["new-clip.mp4"])
    let reloaded = MiniTVPlaylist.load(from: dir, seed: [])
    check("import: saved to disk", reloaded.videos.first?.youtubeID == "dQw4w9WgXcQ")
    check("already-added link rejected", !library.add(link: "https://youtu.be/dQw4w9WgXcQ"))
    check("already-added: names the video", library.status.text.contains("New Clip"))

    // removal
    var trashed: [String] = []
    let removing = VideoLibrary(directory: dir, seed: [], runner: FakeRunner(), locateTools: { .success(tools) },
                                moveToTrash: { trashed.append($0.lastPathComponent) })
    var removedUpdate: [URL]?
    removing.onPlaylistChange = { removedUpdate = $0 }
    removing.remove(file: "new-clip.mp4")
    check("remove: gone from playlist", removing.playlist.videos.isEmpty)
    check("remove: file sent to Trash", trashed == ["new-clip.mp4"])
    check("remove: TVs told", removedUpdate == [])
    check("remove: saved to disk", MiniTVPlaylist.load(from: dir, seed: ["x.mp4"]).videos.isEmpty)
    removing.remove(file: "not-in-playlist.mp4")
    check("remove: unknown file is ignored", trashed == ["new-clip.mp4"])
}

// missing tools
do {
    let dir = makeDir(); defer { try? fm.removeItem(at: dir) }
    let library = VideoLibrary(directory: dir, seed: [], runner: FakeRunner(), locateTools: { .failure(.toolMissing("yt-dlp")) })
    _ = library.add(link: "https://youtu.be/dQw4w9WgXcQ")
    check("missing tool: error shown", library.status.isError && library.status.text.contains("brew install yt-dlp"))
    check("missing tool: not busy", !library.status.isBusy)
}

exit(failed ? 1 : 0)
