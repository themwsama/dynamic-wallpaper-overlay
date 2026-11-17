// VideoImporter: YouTube link parsing, file naming, loudnorm parsing, tool
// lookup, the exact yt-dlp / ffmpeg arguments, and the whole pipeline driven
// by a fake process runner (no network, no real yt-dlp or ffmpeg).
import Foundation

var failed = false
func check(_ name: String, _ ok: Bool) {
    print(ok ? "PASS \(name)" : "FAIL \(name)")
    if !ok { failed = true }
}

let fm = FileManager.default

// MARK: link parsing

let goodLinks: [(String, String)] = [
    ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
    ("https://youtube.com/watch?v=dQw4w9WgXcQ&list=PL123&index=4", "dQw4w9WgXcQ"),
    ("https://m.youtube.com/watch?feature=share&v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
    ("https://music.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ"),
    ("https://youtu.be/dQw4w9WgXcQ?si=abc", "dQw4w9WgXcQ"),
    ("https://www.youtube.com/shorts/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
    ("https://www.youtube.com/live/dQw4w9WgXcQ?feature=x", "dQw4w9WgXcQ"),
    ("https://www.youtube.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
    ("  youtube.com/watch?v=dQw4w9WgXcQ \n", "dQw4w9WgXcQ"),
]
for (link, id) in goodLinks {
    check("link parses: \(link.trimmingCharacters(in: .whitespacesAndNewlines))", YouTubeLink.videoID(from: link) == id)
}
let badLinks = [
    "", "not a link", "https://vimeo.com/123456", "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ",
    "https://www.youtube.com/watch?v=short", "https://www.youtube.com/watch?v=dQw4w9WgXcQ;rm",
    "https://www.youtube.com/playlist?list=PL123", "file:///etc/passwd", "-o /tmp/x https://youtu.be/dQw4w9WgXcQ",
    "ftp://youtube.com/watch?v=dQw4w9WgXcQ",
]
for link in badLinks {
    check("link rejected: \(link.isEmpty ? "<empty>" : link)", YouTubeLink.videoID(from: link) == nil)
}
check("watch URL is canonical", YouTubeLink.watchURL(id: "dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

// MARK: file naming

check("slug: lowercase dashes", VideoFileNamer.slug("Hello, World! (Official Video)") == "hello-world-official-video")
check("slug: accents folded", VideoFileNamer.slug("Café Déjà Vu") == "cafe-deja-vu")
check("slug: non-latin falls back", VideoFileNamer.slug("甲鉄城のカバネリ") == "video")
check("slug: capped length", VideoFileNamer.slug(String(repeating: "abc ", count: 40)).count <= 60)
check("slug: no trailing dash after cap", !VideoFileNamer.slug(String(repeating: "abcd ", count: 40)).hasSuffix("-"))
check("unique name: free", VideoFileNamer.uniqueName(for: "My Song", taken: []) == "my-song.mp4")
check("unique name: numbered when taken",
      VideoFileNamer.uniqueName(for: "My Song", taken: ["my-song.mp4", "my-song-2.mp4"]) == "my-song-3.mp4")
check("unique name passes playlist safety", MiniTVPlaylist.isSafeFileName(VideoFileNamer.uniqueName(for: "../../x", taken: [])))

// MARK: loudnorm output

let loudnormOutput = """
[Parsed_loudnorm_0 @ 0x600]
{
\t"input_i" : "-21.26",
\t"input_tp" : "-9.94",
\t"input_lra" : "6.10",
\t"input_thresh" : "-31.50",
\t"output_i" : "-14.02",
\t"output_tp" : "-1.00",
\t"output_lra" : "5.20",
\t"output_thresh" : "-24.20",
\t"normalization_type" : "dynamic",
\t"target_offset" : "0.02"
}
"""
let parsed = Loudness.parse(loudnormOutput)
check("loudnorm parsed", parsed == Loudness(integrated: -21.26, truePeak: -9.94, range: 6.10, threshold: -31.50, targetOffset: 0.02))
check("loudnorm: garbage gives nil", Loudness.parse("no json here") == nil)
check("loudnorm: -inf (silent) gives nil", Loudness.parse(#"{"input_i" : "-inf", "input_tp" : "-inf", "input_lra" : "0.00", "input_thresh" : "-inf", "target_offset" : "inf"}"#) == nil)

// MARK: tool lookup

do {
    let present: Set<String> = ["/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe"]
    let tools = MediaTools.locate(environment: ["PATH": "/usr/bin:/bin"], isExecutable: { present.contains($0) })
    check("tools found in Homebrew even when PATH lacks it", (try? tools.get())?.ytDlp.path == "/opt/homebrew/bin/yt-dlp")
    let fromPath = MediaTools.locate(environment: ["PATH": "/custom/bin"], isExecutable: {
        ["/custom/bin/yt-dlp", "/custom/bin/ffmpeg", "/custom/bin/ffprobe"].contains($0) })
    check("tools found on PATH", (try? fromPath.get())?.ffmpeg.path == "/custom/bin/ffmpeg")
    let missing = MediaTools.locate(environment: ["PATH": "/usr/bin"], isExecutable: { $0.hasSuffix("ffmpeg") || $0.hasSuffix("ffprobe") })
    if case .failure(.toolMissing(let name)) = missing { check("missing yt-dlp is named", name == "yt-dlp") }
    else { check("missing yt-dlp reported", false) }
}

// MARK: argument builders and parsers

do {
    let args = VideoImportPipeline.downloadArguments(
        id: "dQw4w9WgXcQ", outputTemplate: "/tmp/w/source.%(ext)s", ffmpegDirectory: "/opt/homebrew/bin")
    check("download: URL is the last argument and canonical", args.last == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    check("download: no playlist expansion", args.contains("--no-playlist"))
    check("download: capped at 1080p", args.contains { $0.contains("height<=1080") } && !args.contains { $0.contains("height<=2160") })
    check("download: merged to mp4", zip(args, args.dropFirst()).contains { $0 == "--merge-output-format" && $1 == "mp4" })
    check("download: output template used", zip(args, args.dropFirst()).contains { $0 == "-o" && $1 == "/tmp/w/source.%(ext)s" })
    check("download: live streams and huge videos refused",
          zip(args, args.dropFirst()).contains { $0 == "--match-filter" && $1.contains("!is_live") && $1.contains("duration<=") }
          && args.contains("--max-filesize"))
    check("download: ffmpeg location passed", zip(args, args.dropFirst()).contains { $0 == "--ffmpeg-location" && $1 == "/opt/homebrew/bin" })
}
check("progress line parsed", VideoImportPipeline.parseProgress("PROGRESS  42.5%") == 42.5)
check("progress line with colour codes parsed", VideoImportPipeline.parseProgress("PROGRESS \u{1B}[0;94m 7.0%\u{1B}[0m") == 7.0)
check("other lines are not progress", VideoImportPipeline.parseProgress("TITLE 42%") == nil)
check("yt-dlp private video message",
      VideoImportPipeline.downloadErrorMessage(stderr: "WARNING: x\nERROR: [youtube] abc: Private video. Sign in if you've been granted access") == "This video is private.")
check("yt-dlp age restricted message",
      VideoImportPipeline.downloadErrorMessage(stderr: "ERROR: [youtube] abc: Sign in to confirm your age.") == "This video is age-restricted.")
check("yt-dlp generic message is the ERROR line",
      VideoImportPipeline.downloadErrorMessage(stderr: "noise\nERROR: [youtube] abc: Something odd happened") == "Something odd happened")

// MARK: pipeline with a fake runner

nonisolated final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(tool: String, args: [String])] = []
    var videoCodec = "h264"
    var hasAudio = true
    var verifiedLoudness = "-14.03"
    var sourceLoudness = "-21.26"
    var downloadStatus: Int32 = 0

    func run(_ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult {
        let tool = executable.lastPathComponent
        lock.withLock { calls.append((tool, arguments)) }
        switch tool {
        case "yt-dlp":
            guard downloadStatus == 0 else {
                return ProcessResult(status: downloadStatus, stdout: "", stderr: "ERROR: [youtube] x: Video unavailable")
            }
            let template = arguments[arguments.firstIndex(of: "-o")! + 1]
            let file = template.replacingOccurrences(of: "%(ext)s", with: "mp4")
            FileManager.default.createFile(atPath: file, contents: Data("video".utf8))
            ["TITLE Test Song (Official Video)", "PROGRESS  10.0%", "PROGRESS 100.0%"].forEach(onLine)
            return ProcessResult(status: 0, stdout: "", stderr: "")
        case "ffprobe":
            return ProcessResult(status: 0, stdout: "\(videoCodec),video\n" + (hasAudio ? "aac,audio\n" : ""), stderr: "")
        default:
            if arguments.contains("null") {
                let isVerify = calls.filter { $0.tool == "ffmpeg" && $0.args.contains("null") }.count > 1
                let integrated = isVerify ? verifiedLoudness : sourceLoudness
                let json = #"{"input_i" : "\#(integrated)", "input_tp" : "-9.94", "input_lra" : "6.10", "input_thresh" : "-31.50", "target_offset" : "0.02"}"#
                return ProcessResult(status: 0, stdout: "", stderr: json)
            }
            FileManager.default.createFile(atPath: arguments.last!, contents: Data("normalized".utf8))
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
    }
}

nonisolated final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [VideoImportStage] = []
    func append(_ stage: VideoImportStage) { lock.withLock { stages.append(stage) } }
    var all: [VideoImportStage] { lock.withLock { stages } }
}

let tools = MediaTools(ytDlp: URL(fileURLWithPath: "/fake/yt-dlp"),
                       ffmpeg: URL(fileURLWithPath: "/fake/ffmpeg"),
                       ffprobe: URL(fileURLWithPath: "/fake/ffprobe"))

func makeDest() -> URL {
    let dir = fm.temporaryDirectory.appendingPathComponent("importer-tests-\(UUID().uuidString)", isDirectory: true)
    try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// happy path
do {
    let dest = makeDest(); defer { try? fm.removeItem(at: dest) }
    fm.createFile(atPath: dest.appendingPathComponent("test-song-official-video.mp4").path, contents: Data())
    let runner = FakeRunner()
    let log = StageLog()
    let pipeline = VideoImportPipeline(tools: tools, runner: runner, destination: dest)
    let video = try pipeline.importVideo(id: "dQw4w9WgXcQ", playlist: MiniTVPlaylist(videos: []),
                                         progress: { log.append($0) })
    check("pipeline: titled from yt-dlp", video.title == "Test Song (Official Video)")
    check("pipeline: name avoids existing file", video.file == "test-song-official-video-2.mp4")
    check("pipeline: keeps YouTube id", video.youtubeID == "dQw4w9WgXcQ")
    check("pipeline: file landed in destination", fm.fileExists(atPath: dest.appendingPathComponent(video.file).path))
    let leftovers = try fm.contentsOfDirectory(atPath: dest.path).filter { $0.hasPrefix(".") }
    check("pipeline: temp work dir removed", leftovers.isEmpty)
    check("pipeline: stages in order", log.all == [
        .downloading(percent: nil), .downloading(percent: 10), .downloading(percent: 100),
        .preparing, .normalizing, .checking])

    let normalize = runner.calls.first { $0.tool == "ffmpeg" && !$0.args.contains("null") }!.args
    let filter = normalize[normalize.firstIndex(of: "-af")! + 1]
    check("normalize: two-pass values fed back", filter.contains("measured_I=-21.26") && filter.contains("measured_TP=-9.94")
          && filter.contains("measured_LRA=6.10") && filter.contains("measured_thresh=-31.50") && filter.contains("offset=0.02"))
    check("normalize: same target as the library", filter.hasPrefix("loudnorm=I=-14:TP=-1:LRA=11:"))
    check("normalize: h264 video stream copied", zip(normalize, normalize.dropFirst()).contains { $0 == "-c:v" && $1 == "copy" })
    check("normalize: AAC audio", zip(normalize, normalize.dropFirst()).contains { $0 == "-c:a" && $1 == "aac" })
} catch {
    check("happy path did not throw: \(error)", false)
}

// VP9 / AV1 get re-encoded so AVPlayer can play them
do {
    let dest = makeDest(); defer { try? fm.removeItem(at: dest) }
    let runner = FakeRunner()
    runner.videoCodec = "vp9"
    _ = try VideoImportPipeline(tools: tools, runner: runner, destination: dest)
        .importVideo(id: "dQw4w9WgXcQ", playlist: MiniTVPlaylist(videos: []), progress: { _ in })
    let normalize = runner.calls.first { $0.tool == "ffmpeg" && !$0.args.contains("null") }!.args
    check("vp9: video re-encoded to h264", zip(normalize, normalize.dropFirst()).contains { $0 == "-c:v" && $1 == "h264_videotoolbox" })
} catch {
    check("vp9 path did not throw: \(error)", false)
}

// HEVC is copied but retagged hvc1, which AVPlayer needs in mp4
do {
    let dest = makeDest(); defer { try? fm.removeItem(at: dest) }
    let runner = FakeRunner()
    runner.videoCodec = "hevc"
    _ = try VideoImportPipeline(tools: tools, runner: runner, destination: dest)
        .importVideo(id: "dQw4w9WgXcQ", playlist: MiniTVPlaylist(videos: []), progress: { _ in })
    let normalize = runner.calls.first { $0.tool == "ffmpeg" && !$0.args.contains("null") }!.args
    check("hevc: copied", zip(normalize, normalize.dropFirst()).contains { $0 == "-c:v" && $1 == "copy" })
    check("hevc: tagged hvc1", zip(normalize, normalize.dropFirst()).contains { $0 == "-tag:v" && $1 == "hvc1" })
} catch {
    check("hevc path did not throw: \(error)", false)
}

// an all-silent audio track (loudnorm reports -inf) imports without normalizing
do {
    let dest = makeDest(); defer { try? fm.removeItem(at: dest) }
    let runner = FakeRunner()
    runner.sourceLoudness = "-inf"
    let video = try VideoImportPipeline(tools: tools, runner: runner, destination: dest)
        .importVideo(id: "dQw4w9WgXcQ", playlist: MiniTVPlaylist(videos: []), progress: { _ in })
    let normalize = runner.calls.first { $0.tool == "ffmpeg" && !$0.args.contains("null") }!.args
    check("silent track: imported", fm.fileExists(atPath: dest.appendingPathComponent(video.file).path))
    check("silent track: no loudnorm filter", !normalize.contains("-af"))
    check("silent track: no check pass", runner.calls.filter { $0.args.contains("null") }.count == 1)
} catch {
    check("silent track path did not throw: \(error)", false)
}

// silent video: no loudness pass, video kept
do {
    let dest = makeDest(); defer { try? fm.removeItem(at: dest) }
    let runner = FakeRunner()
    runner.hasAudio = false
    let video = try VideoImportPipeline(tools: tools, runner: runner, destination: dest)
        .importVideo(id: "dQw4w9WgXcQ", playlist: MiniTVPlaylist(videos: []), progress: { _ in })
    check("silent: imported", fm.fileExists(atPath: dest.appendingPathComponent(video.file).path))
    check("silent: no loudness measurement", !runner.calls.contains { $0.args.contains("null") })
} catch {
    check("silent path did not throw: \(error)", false)
}

// duplicates are rejected before any download
do {
    let dest = makeDest(); defer { try? fm.removeItem(at: dest) }
    let runner = FakeRunner()
    let playlist = MiniTVPlaylist(videos: [MiniTVVideo(file: "x.mp4", title: "Already here", youtubeID: "dQw4w9WgXcQ")])
    do {
        _ = try VideoImportPipeline(tools: tools, runner: runner, destination: dest)
            .importVideo(id: "dQw4w9WgXcQ", playlist: playlist, progress: { _ in })
        check("duplicate rejected", false)
    } catch let error as VideoImportError {
        check("duplicate rejected", error == .alreadyAdded("Already here"))
        check("duplicate: nothing downloaded", runner.calls.isEmpty)
    }
}

// download failure surfaces the yt-dlp message and cleans up
do {
    let dest = makeDest(); defer { try? fm.removeItem(at: dest) }
    let runner = FakeRunner()
    runner.downloadStatus = 1
    do {
        _ = try VideoImportPipeline(tools: tools, runner: runner, destination: dest)
            .importVideo(id: "dQw4w9WgXcQ", playlist: MiniTVPlaylist(videos: []), progress: { _ in })
        check("download failure thrown", false)
    } catch let error as VideoImportError {
        check("download failure thrown", error == .downloadFailed("This video is unavailable."))
        check("download failure: temp dir removed", ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? ["?"]).isEmpty)
    }
}

// verification failure keeps the result out of the library
do {
    let dest = makeDest(); defer { try? fm.removeItem(at: dest) }
    let runner = FakeRunner()
    runner.verifiedLoudness = "-19.00"
    do {
        _ = try VideoImportPipeline(tools: tools, runner: runner, destination: dest)
            .importVideo(id: "dQw4w9WgXcQ", playlist: MiniTVPlaylist(videos: []), progress: { _ in })
        check("loudness check failure thrown", false)
    } catch let error as VideoImportError {
        check("loudness check failure thrown", error == .loudnessOff(-19.0))
        check("loudness check failure: nothing added", ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? ["?"]).isEmpty)
    }
}

check("error text is readable", VideoImportError.toolMissing("yt-dlp").errorDescription == "yt-dlp is not installed. Run: brew install yt-dlp")

exit(failed ? 1 : 0)
