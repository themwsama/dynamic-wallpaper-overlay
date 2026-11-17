// Adds a YouTube video to the mini TV: downloads it with yt-dlp (1080p max),
// makes sure AVPlayer can play it, normalizes the audio to the same loudness
// as the rest of the library (two-pass EBU R128), checks the result, and moves
// it into the overlay folder. Blocking; run it off the main thread.
// Processes are started directly with argument arrays (never through a shell)
// and yt-dlp only ever sees a canonical URL rebuilt from the parsed video id.
import Foundation

// The library's loudness target. Every mini TV video is normalized to this.
nonisolated let LOUDNESS_TARGET_LUFS = -14.0
nonisolated let LOUDNESS_TRUE_PEAK_DB = -1.0
nonisolated let LOUDNESS_RANGE_LU = 11.0
nonisolated let LOUDNESS_TOLERANCE_LU = 1.0   // the check pass fails beyond this
nonisolated let IMPORT_MAX_HEIGHT = 1080
nonisolated let IMPORT_MAX_DURATION_SECONDS = 3600  // longer videos and live streams are refused
nonisolated let IMPORT_MAX_FILESIZE = "3G"
nonisolated let IMPORT_AUDIO_BITRATE = "256k"
nonisolated let IMPORT_VIDEO_BITRATE = "8M"   // only when the source codec needs re-encoding
nonisolated let PLAYABLE_VIDEO_CODECS: Set<String> = ["h264", "hevc"]

nonisolated enum YouTubeLink {
    private static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
    private static let pathPrefixes = ["/shorts/", "/live/", "/embed/"]

    // The 11-character video id, or nil for anything that isn't a single YouTube video link
    static func videoID(from text: String) -> String? {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !link.contains(where: \.isWhitespace) else { return nil }
        if !link.contains("://") { link = "https://" + link }
        guard let components = URLComponents(string: link),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased() else { return nil }
        let candidate: String?
        if host == "youtu.be" {
            candidate = components.path.split(separator: "/").first.map(String.init)
        } else if hosts.contains(host) {
            if components.path == "/watch" {
                candidate = components.queryItems?.first { $0.name == "v" }?.value
            } else if let prefix = pathPrefixes.first(where: components.path.hasPrefix) {
                candidate = components.path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }
        guard let id = candidate, isValidID(id) else { return nil }
        return id
    }

    static func watchURL(id: String) -> String { "https://www.youtube.com/watch?v=\(id)" }

    private static func isValidID(_ id: String) -> Bool {
        id.count == 11 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

nonisolated enum VideoFileNamer {
    static let maxSlugLength = 60
    static let fallbackSlug = "video"

    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en"))
        let words = folded.lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        var slug = ""
        for word in words {
            let next = slug.isEmpty ? String(word) : slug + "-" + word
            if next.count > maxSlugLength { break }
            slug = next
        }
        return slug.isEmpty ? fallbackSlug : slug
    }

    static func uniqueName(for title: String, taken: Set<String>) -> String {
        let base = slug(title)
        var name = "\(base).mp4"
        var counter = 2
        while taken.contains(name) {
            name = "\(base)-\(counter).mp4"
            counter += 1
        }
        return name
    }
}

// ffmpeg loudnorm's measured values (print_format=json)
nonisolated struct Loudness: Equatable, Sendable {
    let integrated: Double
    let truePeak: Double
    let range: Double
    let threshold: Double
    let targetOffset: Double

    static func parse(_ output: String) -> Loudness? {
        guard let start = output.lastIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: String]
        else { return nil }
        func value(_ key: String) -> Double? {
            guard let number = object[key].flatMap(Double.init), number.isFinite else { return nil }
            return number
        }
        guard let i = value("input_i"), let tp = value("input_tp"), let lra = value("input_lra"),
              let thresh = value("input_thresh"), let offset = value("target_offset") else { return nil }
        return Loudness(integrated: i, truePeak: tp, range: lra, threshold: thresh, targetOffset: offset)
    }
}

nonisolated enum VideoImportStage: Equatable, Sendable {
    case downloading(percent: Double?)
    case preparing
    case normalizing
    case checking
}

nonisolated enum VideoImportError: Error, Equatable, LocalizedError {
    case invalidLink
    case alreadyAdded(String)
    case toolMissing(String)
    case downloadFailed(String)
    case processingFailed(String)
    case loudnessOff(Double)

    var errorDescription: String? {
        switch self {
        case .invalidLink: return "That isn't a YouTube video link."
        case .alreadyAdded(let title): return "Already on the mini TV: \(title)"
        case .toolMissing(let name): return "\(name) is not installed. Run: brew install \(name == "ffprobe" ? "ffmpeg" : name)"
        case .downloadFailed(let message): return "Download failed. \(message)"
        case .processingFailed(let message): return "Couldn't process the video. \(message)"
        case .loudnessOff(let lufs): return String(format: "Volume check failed (%.1f LUFS). Video not added.", lufs)
        }
    }
}

nonisolated struct MediaTools: Sendable {
    let ytDlp: URL
    let ffmpeg: URL
    let ffprobe: URL

    // LaunchAgents get a bare PATH, so Homebrew's folders are always searched too
    static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) })
    -> Result<MediaTools, VideoImportError> {
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = pathDirectories + fallbackDirectories.filter { !pathDirectories.contains($0) }
        func find(_ name: String) -> URL? {
            directories.lazy.map { "\($0)/\(name)" }.first(where: isExecutable).map(URL.init(fileURLWithPath:))
        }
        guard let ytDlp = find("yt-dlp") else { return .failure(.toolMissing("yt-dlp")) }
        guard let ffmpeg = find("ffmpeg") else { return .failure(.toolMissing("ffmpeg")) }
        guard let ffprobe = find("ffprobe") else { return .failure(.toolMissing("ffprobe")) }
        return .success(MediaTools(ytDlp: ytDlp, ffmpeg: ffmpeg, ffprobe: ffprobe))
    }
}

nonisolated struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

nonisolated protocol ProcessRunning: Sendable {
    // `onLine` gets each output line (stdout and stderr) as it arrives
    func run(_ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult
}

nonisolated struct VideoImportPipeline: Sendable {
    let tools: MediaTools
    let runner: ProcessRunning
    let destination: URL

    private static let titlePrefix = "TITLE "
    private static let progressPrefix = "PROGRESS "

    func importVideo(id: String, playlist: MiniTVPlaylist,
                     progress: @escaping @Sendable (VideoImportStage) -> Void) throws -> MiniTVVideo {
        if let existing = playlist.videos.first(where: { $0.youtubeID == id }) {
            throw VideoImportError.alreadyAdded(existing.title)
        }
        // Hidden work folder on the same volume, so the final move is a rename
        let work = destination.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress(.downloading(percent: nil))
        let (source, title) = try download(id: id, into: work, progress: progress)

        progress(.preparing)
        let streams = try probeStreams(source)
        let output = work.appendingPathComponent("normalized.mp4")
        progress(.normalizing)
        let isNormalized = try normalize(source, to: output, videoCodec: streams.videoCodec, hasAudio: streams.hasAudio)

        progress(.checking)
        if isNormalized {
            // Normalized audio that now measures silent is as wrong as audio off target
            let measured = try measureLoudness(output)?.integrated ?? -.infinity
            guard abs(measured - LOUDNESS_TARGET_LUFS) <= LOUDNESS_TOLERANCE_LU else {
                throw VideoImportError.loudnessOff(measured)
            }
        }

        let taken = Set(playlist.videos.map(\.file))
            .union((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
        let name = VideoFileNamer.uniqueName(for: title, taken: taken)
        try FileManager.default.moveItem(at: output, to: destination.appendingPathComponent(name))
        return MiniTVVideo(file: name, title: title, youtubeID: id)
    }

    // MARK: steps

    private func download(id: String, into work: URL,
                          progress: @escaping @Sendable (VideoImportStage) -> Void) throws -> (URL, String) {
        let titleBox = LockedValue<String?>(nil)
        let result = try runner.run(
            tools.ytDlp,
            Self.downloadArguments(id: id, outputTemplate: work.appendingPathComponent("source.%(ext)s").path,
                                   ffmpegDirectory: tools.ffmpeg.deletingLastPathComponent().path),
            onLine: { line in
                if line.hasPrefix(Self.titlePrefix) {
                    titleBox.set(String(line.dropFirst(Self.titlePrefix.count)).trimmingCharacters(in: .whitespaces))
                } else if let percent = Self.parseProgress(line) {
                    progress(.downloading(percent: percent))
                }
            })
        guard result.status == 0 else {
            throw VideoImportError.downloadFailed(Self.downloadErrorMessage(stderr: result.stderr + "\n" + result.stdout))
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        guard let source = files.first(where: { $0.lastPathComponent.hasPrefix("source.") && $0.pathExtension != "part" }) else {
            // --match-filter / --max-filesize skips exit 0 with nothing downloaded
            let output = (result.stdout + result.stderr).lowercased()
            if output.contains("does not pass filter") || output.contains("max-filesize") {
                throw VideoImportError.downloadFailed("Live streams and videos over \(IMPORT_MAX_DURATION_SECONDS / 60) minutes can't be added.")
            }
            throw VideoImportError.downloadFailed("yt-dlp finished without a video file.")
        }
        let title = titleBox.get().flatMap { $0.isEmpty ? nil : $0 } ?? id
        return (source, title)
    }

    private func probeStreams(_ file: URL) throws -> (videoCodec: String, hasAudio: Bool) {
        let result = try runner.run(tools.ffprobe, [
            "-v", "error", "-show_entries", "stream=codec_name,codec_type", "-of", "csv=p=0", file.path,
        ], onLine: { _ in })
        let streams = result.stdout.split(whereSeparator: \.isNewline).map { $0.split(separator: ",").map(String.init) }
        guard result.status == 0, let video = streams.first(where: { $0.last == "video" })?.first else {
            throw VideoImportError.processingFailed("No video stream found.")
        }
        return (video, streams.contains { $0.last == "audio" })
    }

    // nil for an all-silent track (loudnorm reports -inf): nothing to normalize
    private func measureLoudness(_ file: URL) throws -> Loudness? {
        let result = try runner.run(tools.ffmpeg, [
            "-hide_banner", "-nostats", "-i", file.path, "-vn",
            "-af", "\(Self.loudnormTarget):print_format=json", "-f", "null", "-",
        ], onLine: { _ in })
        if result.status == 0, let loudness = Loudness.parse(result.stderr) { return loudness }
        if result.status == 0, Self.isSilent(result.stderr) { return nil }
        throw VideoImportError.processingFailed("Couldn't measure the volume.")
    }

    // Returns whether the audio was loudness-normalized (false: no audio, or silent)
    private func normalize(_ source: URL, to output: URL, videoCodec: String, hasAudio: Bool) throws -> Bool {
        var video = PLAYABLE_VIDEO_CODECS.contains(videoCodec)
            ? ["-c:v", "copy"]
            : ["-c:v", "h264_videotoolbox", "-b:v", IMPORT_VIDEO_BITRATE, "-pix_fmt", "yuv420p"]
        if videoCodec == "hevc" { video += ["-tag:v", "hvc1"] }  // AVPlayer won't play hev1-tagged HEVC in mp4
        var audio: [String] = ["-an"]
        var isNormalized = false
        if hasAudio {
            audio = ["-c:a", "aac", "-b:a", IMPORT_AUDIO_BITRATE, "-ar", "48000"]
            if let measured = try measureLoudness(source) {
                audio += ["-af", Self.loudnormFilter(measured)]
                isNormalized = true
            }
        }
        let result = try runner.run(tools.ffmpeg, [
            "-hide_banner", "-nostats", "-loglevel", "error", "-y", "-i", source.path,
            "-map", "0:v:0", "-map", "0:a:0?",
        ] + video + audio + ["-movflags", "+faststart", output.path], onLine: { _ in })
        guard result.status == 0, FileManager.default.fileExists(atPath: output.path) else {
            let reason = result.stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "ffmpeg failed."
            throw VideoImportError.processingFailed(reason)
        }
        return isNormalized
    }

    static func isSilent(_ loudnormOutput: String) -> Bool {
        loudnormOutput.range(of: #""input_i"\s*:\s*"-inf""#, options: .regularExpression) != nil
    }

    // MARK: arguments and output parsing (static for tests)

    static var loudnormTarget: String {
        "loudnorm=I=\(format(LOUDNESS_TARGET_LUFS)):TP=\(format(LOUDNESS_TRUE_PEAK_DB)):LRA=\(format(LOUDNESS_RANGE_LU))"
    }

    static func loudnormFilter(_ m: Loudness) -> String {
        "\(loudnormTarget):measured_I=\(decimal(m.integrated)):measured_TP=\(decimal(m.truePeak))"
            + ":measured_LRA=\(decimal(m.range)):measured_thresh=\(decimal(m.threshold)):offset=\(decimal(m.targetOffset))"
            + ":linear=true:print_format=summary"
    }

    static func downloadArguments(id: String, outputTemplate: String, ffmpegDirectory: String) -> [String] {
        let h = IMPORT_MAX_HEIGHT
        // Prefer H.264 + AAC (plays everywhere, no re-encode), then anything up to 1080p
        let format = "bv*[height<=\(h)][vcodec^=avc1]+ba[ext=m4a]/b[height<=\(h)][vcodec^=avc1]"
            + "/bv*[height<=\(h)]+ba/b[height<=\(h)]"
        return [
            "--no-playlist", "--no-color", "--newline", "--progress",
            "--progress-template", "download:\(progressPrefix)%(progress._percent_str)s",
            "--print", "before_dl:\(titlePrefix)%(title)s",
            "-f", format, "--merge-output-format", "mp4",
            "--match-filter", "!is_live & duration<=\(IMPORT_MAX_DURATION_SECONDS)",
            "--max-filesize", IMPORT_MAX_FILESIZE,
            "--ffmpeg-location", ffmpegDirectory,
            "-o", outputTemplate,
            YouTubeLink.watchURL(id: id),
        ]
    }

    static func parseProgress(_ line: String) -> Double? {
        guard line.hasPrefix(progressPrefix) else { return nil }
        let cleaned = line.dropFirst(progressPrefix.count)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard cleaned.hasSuffix("%") else { return nil }
        return Double(cleaned.dropLast())
    }

    static func downloadErrorMessage(stderr: String) -> String {
        let errorLine = stderr.split(whereSeparator: \.isNewline).map(String.init)
            .last { $0.hasPrefix("ERROR:") } ?? ""
        let lower = errorLine.lowercased()
        if lower.contains("private video") { return "This video is private." }
        if lower.contains("confirm your age") { return "This video is age-restricted." }
        if lower.contains("video unavailable") { return "This video is unavailable." }
        if lower.contains("not a bot") { return "YouTube asked to confirm you're not a bot. Try again later." }
        // Drop "ERROR: [youtube] <id>: " and keep the reason, trimmed for the status line
        var reason = errorLine.replacingOccurrences(
            of: #"^ERROR:\s*(\[[^\]]+\]\s*[^:]+:\s*)?"#, with: "", options: .regularExpression)
        if reason.isEmpty { reason = "yt-dlp failed." }
        return String(reason.prefix(140))
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func decimal(_ value: Double) -> String { String(format: "%.2f", value) }
}

// MARK: the real process runner

nonisolated final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}

// Splits a byte stream into lines, forwarding each one and keeping the full text
nonisolated private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var all = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            all.append(data)
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        lines.filter { !$0.isEmpty }.forEach(onLine)
    }

    func finish() -> String {
        let rest: String = lock.withLock {
            let rest = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            return rest
        }
        if !rest.isEmpty { onLine(rest) }
        return lock.withLock { String(decoding: all, as: UTF8.self) }
    }
}

nonisolated struct SystemProcessRunner: ProcessRunning {
    func run(_ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = LineSplitter(onLine: onLine), err = LineSplitter(onLine: onLine)
        // Each handler reads until EOF (empty data), then detaches itself and
        // signals; waiting on both means every byte is in, in order
        let drained = DispatchGroup()
        for (pipe, splitter) in [(outPipe, out), (errPipe, err)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    splitter.append(data)
                }
            }
        }
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw VideoImportError.processingFailed("Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        drained.wait()
        return ProcessResult(status: process.terminationStatus, stdout: out.finish(), stderr: err.finish())
    }
}
