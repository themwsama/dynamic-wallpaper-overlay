// The mini TV's video library: owns the playlist file, imports YouTube links
// one at a time on a background queue, and removes videos (to the Trash, so a
// mistake can be undone in Finder). Main-thread object; the views read
// `playlist` and `status` and listen to `onChange`.
import Foundation

struct VideoLibraryStatus: Equatable {
    let text: String
    let isError: Bool
    let isBusy: Bool

    static let idle = VideoLibraryStatus(text: "", isError: false, isBusy: false)
}

final class VideoLibrary {
    private let directory: URL
    private let runner: ProcessRunning
    private let locateTools: () -> Result<MediaTools, VideoImportError>
    private let moveToTrash: (URL) throws -> Void
    private let work = DispatchQueue(label: "wallpaper-overlay.video-import", qos: .utility)
    private var pendingIDs: [String] = []
    private var activeID: String?

    private(set) var playlist: MiniTVPlaylist
    private(set) var status = VideoLibraryStatus.idle
    var onChange: (() -> Void)?           // playlist or status changed
    var onPlaylistChange: (([URL]) -> Void)?

    var videoURLs: [URL] { playlist.urls(in: directory) }
    var queuedCount: Int { pendingIDs.count }

    init(directory: URL, seed: [String],
         runner: ProcessRunning = SystemProcessRunner(),
         locateTools: @escaping () -> Result<MediaTools, VideoImportError> = { MediaTools.locate() },
         moveToTrash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.directory = directory
        self.runner = runner
        self.locateTools = locateTools
        self.moveToTrash = moveToTrash
        playlist = MiniTVPlaylist.load(from: directory, seed: seed)
        Self.removeStaleImports(in: directory)
        // Write the seeded list once, so the file exists for people to inspect
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(MiniTVPlaylist.fileName).path) {
            try? playlist.save(to: directory)
        }
    }

    // Returns false (and sets an error status) when the text isn't a usable link
    @discardableResult
    func add(link: String) -> Bool {
        guard let id = YouTubeLink.videoID(from: link) else {
            setStatus(VideoImportError.invalidLink.errorDescription ?? "", isError: true)
            return false
        }
        if let existing = playlist.videos.first(where: { $0.youtubeID == id }) {
            setStatus(VideoImportError.alreadyAdded(existing.title).errorDescription ?? "", isError: true)
            return false
        }
        guard activeID != id, !pendingIDs.contains(id) else {
            setStatus("That link is already downloading.", isError: true)
            return false
        }
        pendingIDs.append(id)
        startNextImport()
        return true
    }

    func remove(file: String) {
        guard let video = playlist.videos.first(where: { $0.file == file }) else { return }
        let updated = playlist.removing(file: file)
        do {
            try updated.save(to: directory)
        } catch {
            NSLog("wallpaper-overlay: couldn't save the mini TV playlist: %@", "\(error)")
            setStatus("Couldn't save the playlist. Nothing removed.", isError: true)
            return
        }
        playlist = updated
        onPlaylistChange?(videoURLs)
        let url = directory.appendingPathComponent(file)
        do {
            try moveToTrash(url)
            setStatus("Removed \(video.title). It's in the Trash.", isError: false)
        } catch {
            NSLog("wallpaper-overlay: couldn't move %@ to the Trash: %@", url.path, "\(error)")
            setStatus("Removed \(video.title) from the TV. The file stays in the overlay folder.", isError: false)
        }
    }

    // Work folders left by an import that was cut short (app quit, crash)
    private static func removeStaleImports(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".import-") {
            do {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                NSLog("wallpaper-overlay: couldn't remove stale import folder %@: %@", name, "\(error)")
            }
        }
    }

    // MARK: importing

    private func startNextImport() {
        guard activeID == nil, !pendingIDs.isEmpty else { return }
        let id = pendingIDs.removeFirst()
        let tools: MediaTools
        switch locateTools() {
        case .success(let found): tools = found
        case .failure(let error):
            pendingIDs.removeAll()
            setStatus(error.errorDescription ?? "", isError: true)
            return
        }
        activeID = id
        show(.downloading(percent: nil))
        let pipeline = VideoImportPipeline(tools: tools, runner: runner, destination: directory)
        let snapshot = playlist
        work.async { [weak self] in
            let result = Result {
                try pipeline.importVideo(id: id, playlist: snapshot, progress: { stage in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(stage) } }
                })
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishImport(result) } }
        }
    }

    private func finishImport(_ result: Result<MiniTVVideo, Error>) {
        activeID = nil
        switch result {
        case .success(let video):
            let updated = playlist.adding(video)
            do {
                try updated.save(to: directory)
                playlist = updated
                onPlaylistChange?(videoURLs)
                setStatus("Added \(video.title)", isError: false)
            } catch {
                NSLog("wallpaper-overlay: couldn't save the mini TV playlist: %@", "\(error)")
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(video.file))
                setStatus("Couldn't save the playlist. Video not added.", isError: true)
            }
        case .failure(let error):
            NSLog("wallpaper-overlay: video import failed: %@", "\(error)")
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            setStatus(message, isError: true)
        }
        startNextImport()
    }

    private func show(_ stage: VideoImportStage) {
        guard activeID != nil else { return }  // a late progress hop after the job finished
        let text: String
        switch stage {
        case .downloading(let percent?): text = String(format: "Downloading %.0f%%", percent)
        case .downloading(nil): text = "Downloading…"
        case .preparing: text = "Preparing…"
        case .normalizing: text = "Matching volume…"
        case .checking: text = "Checking volume…"
        }
        let queued = pendingIDs.isEmpty ? "" : "  ·  \(pendingIDs.count) queued"
        let next = VideoLibraryStatus(text: text + queued, isError: false, isBusy: true)
        guard next != status else { return }  // yt-dlp repeats the same percent often
        status = next
        onChange?()
    }

    private func setStatus(_ text: String, isError: Bool) {
        status = VideoLibraryStatus(text: text, isError: isError, isBusy: activeID != nil)
        onChange?()
    }
}
