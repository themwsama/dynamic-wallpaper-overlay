// Dynamic wallpaper overlay: draws the name block as real text above the
// video wallpaper and below the desktop icons, anchored to each screen's
// top-right corner with a fixed margin, with a glass stopwatch / timer card
// underneath. A gear at the end of the subtitle row opens the control center,
// whose tiles toggle the clock, the wallpaper version (with an animated
// transition), the transition style, the music glow, lyrics and romaji.
// The overlay renders the wallpaper video itself (Metal). While Spotify plays,
// a glow with fire sparks pulses along the bottom edge to its beat, colored
// by the song's genre.
// Build: ./build.sh  (Transition.metal compiles at launch)
import AppKit

// Borderless panel that takes clicks without ever activating the app or
// stealing keyboard focus from the window you're working in
final class ClickThroughFocusPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ScreenWindows {
    let backdrop: NSWindow?
    let text: NSWindow
    let gear: NSWindow
    let gearButton: GlassButton
    let clock: NSWindow
    let clockView: ClockView
    let lyrics: NSWindow
    let lyricsView: LyricsView
    let clockHomeOrigin: NSPoint  // where the clock sits while the control center is closed
    let panelTopRight: NSPoint
}

let AUDIO_TAP_IDLE_GRACE: TimeInterval = 15
// Display changes arrive in bursts (wake, arrange, resolution); rebuild once they settle
let SCREEN_REBUILD_DEBOUNCE: TimeInterval = 0.3

final class OverlayController: NSObject {
    private var screens: [ScreenWindows] = []
    private let settings = Settings()
    private let clock = ClockModel()
    private var ticker: Timer?
    private var transitionStyle: TransitionStyle {
        TransitionStyle(rawValue: settings.transitionStyleRaw) ?? Self.defaultTransitionStyle
    }
    // .crossfade only if DEFAULT_TRANSITION_STYLE_RAW itself were ever out of range
    private static let defaultTransitionStyle = TransitionStyle(rawValue: DEFAULT_TRANSITION_STYLE_RAW) ?? .crossfade
    // Without the video file or Metal, the overlay runs without the backdrop
    private lazy var renderer: TransitionRenderer? = VideoFrameSource(url: BACKDROP_VIDEO_URL)
        .flatMap { TransitionRenderer(frames: $0, showsEffects: settings.isEffectsVisible) }
    private let spotify = SpotifyWatcher()
    private let audioTap = SpotifyAudioTap()
    private var tapSuspendWork: DispatchWorkItem?
    private var rebuildWork: DispatchWorkItem?
    private var housekeeping: Timer?
    private lazy var visibility = VisibilityMonitor(backdrops: { [weak self] in self?.screens.compactMap(\.backdrop) ?? [] })
    private var glow: GlowController?
    private let genres = GenreResolver(
        cacheURL: OVERLAY_DIR.appendingPathComponent("genre-cache.json"),
        credentials: { .fromKeychain() })
    private lazy var lyrics = LyricsController(
        settings: settings,
        provider: LyricsProvider(cacheDirectory: OVERLAY_DIR.appendingPathComponent("lyrics-cache")),
        clock: PlaybackClock(source: AppleScriptPositionSource()),
        views: { [weak self] in self?.screens.map(\.lyricsView) ?? [] },
        accent: { [weak self] in self?.glow?.accentColor ?? TEXT_COLOR })
    private lazy var controlCenter = ControlCenterPanel(
        tiles: makeTiles(), exemptWindows: { [weak self] in self?.screens.map(\.gear) ?? [] })
    // The clock sits where the panel opens, so it slides down out of the way
    private var clockOffset: CGFloat {
        ControlCenterPanel.size(tileCount: makeTiles().count).height + PANEL_GAP
    }

    func start() {
        NSLog("wallpaper-overlay: using config dir %@ log %@", OVERLAY_DIR.path, Housekeeping.logURL.path)
        clock.onChange = { [weak self] in self?.refreshClocks() }
        clock.onFinish = { playFinishSound() }
        controlCenter.onOpenChange = { [weak self] isOpen in self?.controlCenterChanged(isOpen: isOpen) }
        settings.observe { [weak self] _ in self?.controlCenter.refresh() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
        startMusicGlow()
        visibility.onChange = { [weak self] visible in self?.renderer?.setPaused(!visible) }
        rebuild()
        housekeeping = Housekeeping.schedule()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ticker = Timer(timeInterval: CLOCK_TICK_INTERVAL, repeats: true) { [weak self] _ in
            guard let self, self.clock.isRunning else { return }
            self.clock.tick()
            self.refreshClocks()
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    @objc private func screenParametersChanged() {
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildWork = nil
            self?.rebuild()
        }
        rebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SCREEN_REBUILD_DEBOUNCE, execute: work)
    }

    private func rebuild() {
        controlCenter.close()
        screens.flatMap { [$0.backdrop, $0.text, $0.gear, $0.clock, $0.lyrics].compactMap { $0 } }
            .forEach { $0.orderOut(nil) }
        screens = NSScreen.screens.map(makeWindows)
        // New windows start with an unknown occlusion state; check again once they're up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.visibility.reevaluate() }
    }

    // Glow follows Spotify's real audio when the tap is healthy, else its play state
    private func startMusicGlow() {
        audioTap.start()
        let glow = GlowController(
            audioLevels: { [weak self] in
                guard let self, self.audioTap.isHealthy else { return nil }
                return self.audioTap.levels
            },
            isSpotifyPlaying: { [weak self] in self?.spotify.isPlaying ?? false })
        glow.isEnabled = settings.isMusicGlowEnabled
        renderer?.glow = glow
        self.glow = glow
        spotify.onTrackChange = { [weak self] track in
            guard let self else { return }
            NSLog("wallpaper-overlay: now playing %@ – %@", track.artist, track.name)
            let info = TrackInfo(trackID: track.id, name: track.name, artist: track.artist, album: track.album)
            let trackID = track.id
            // A slow lookup must not recolor the glow for a song that's no longer playing
            self.genres.resolve(info) { [weak self] genre, _ in
                guard self?.spotify.track?.id == trackID else { return }
                glow.setGenre(genre)
            }
            self.lyrics.trackChanged(track, position: self.spotify.lastPosition)
        }
        spotify.onStateChange = { [weak self] playing in
            guard let self else { return }
            self.lyrics.playStateChanged(playing)
            if !playing && self.spotify.track == nil { self.lyrics.playbackEnded() }
            self.updateAudioTap(playing: playing)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let self, app?.bundleIdentifier == SPOTIFY_BUNDLE_ID else { return }
            self.spotify.reset()
            self.lyrics.playbackEnded()
            self.updateAudioTap(playing: false, immediately: true)
        }
        updateAudioTap(playing: false)
        spotify.onPositionUpdate = { [weak self] seconds in self?.lyrics.positionChanged(seconds) }
        spotify.start()
        // Pick up a song that was already playing before the overlay started
        fetchSpotifyNowPlaying { [weak self] info in
            // Spotify may have quit while the query ran; its answer is stale then
            guard let self, let info, self.spotify.track == nil,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: SPOTIFY_BUNDLE_ID).isEmpty else { return }
            self.spotify.handle(info)
        }
    }

    // The audio stream only runs while Spotify plays; a pause keeps it for a
    // short grace period so quick pause/play doesn't restart it
    // The tap keeps this suspended state even while it couldn't be built
    private func updateAudioTap(playing: Bool, immediately: Bool = false) {
        tapSuspendWork?.cancel()
        tapSuspendWork = nil
        if playing {
            audioTap.resume()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.audioTap.suspend() }
        tapSuspendWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : AUDIO_TAP_IDLE_GRACE), execute: work)
    }

    private func makeTiles() -> [ControlTile] {
        let s = settings
        return [
            ControlTile(symbol: "clock", glyph: nil, title: { "Clock" },
                        isOn: { s.isClockVisible }, isReadOnly: false,
                        action: { [weak self] in self?.toggleClock() }),
            ControlTile(symbol: "circle.lefthalf.filled", glyph: nil,
                        title: { s.isEffectsVisible ? "Glass" : "Original" },
                        isOn: { s.isEffectsVisible }, isReadOnly: false,
                        action: { [weak self] in self?.toggleEffects() }),
            ControlTile(symbol: "arrow.triangle.2.circlepath", glyph: nil,
                        title: { [weak self] in self?.transitionStyle.shortName ?? "" },
                        isOn: { true }, isReadOnly: false,
                        action: { [weak self] in self?.cycleTransitionStyle() }),
            ControlTile(symbol: "sparkles", glyph: nil, title: { "Glow" },
                        isOn: { s.isMusicGlowEnabled }, isReadOnly: false,
                        action: { [weak self] in self?.toggleGlow() }),
            ControlTile(symbol: "music.note", glyph: nil, title: { "Lyrics" },
                        isOn: { s.isLyricsEnabled }, isReadOnly: false,
                        action: { s.isLyricsEnabled.toggle() }),
            ControlTile(symbol: nil, glyph: "あ", title: { "Romaji" },
                        isOn: { s.isRomajiEnabled }, isReadOnly: false,
                        action: { s.isRomajiEnabled.toggle() }),
            ControlTile(symbol: "battery.25", glyph: nil, title: { "Low power" },
                        isOn: { ProcessInfo.processInfo.isLowPowerModeEnabled }, isReadOnly: true,
                        action: {}),
        ]
    }

    private func refreshClocks() {
        screens.forEach { $0.clockView.refresh() }
    }

    private func toggleClock() {
        settings.isClockVisible.toggle()
        screens.forEach { setClockWindow($0.clock, visible: settings.isClockVisible) }
    }

    private func toggleEffects() {
        guard renderer?.transition(toEffects: !settings.isEffectsVisible, style: transitionStyle) == true else { return }
        settings.isEffectsVisible.toggle()
    }

    private func cycleTransitionStyle() {
        settings.transitionStyleRaw = transitionStyle.next.rawValue
    }

    private func toggleGlow() {
        settings.isMusicGlowEnabled.toggle()
        glow?.isEnabled = settings.isMusicGlowEnabled
    }

    @objc private func powerStateChanged() {
        DispatchQueue.main.async { self.controlCenter.refresh() }
    }

    private func controlCenterChanged(isOpen: Bool) {
        for s in screens {
            s.gearButton.isSelected = isOpen
            let origin = NSPoint(x: s.clockHomeOrigin.x, y: s.clockHomeOrigin.y - (isOpen ? clockOffset : 0))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PANEL_ANIMATION_DURATION
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                s.clock.animator().setFrameOrigin(origin)
            }
        }
    }

    private func setClockWindow(_ window: NSWindow, visible: Bool) {
        if visible {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = CLOCK_FADE_DURATION
            window.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: {
            // Skip if the user toggled back while the fade was running
            if !visible && !self.settings.isClockVisible { window.orderOut(nil) }
        })
    }

    private func makeWindows(for screen: NSScreen) -> ScreenWindows {
        let size = BlockView.blockSize()
        let visible = screen.visibleFrame
        let right = visible.maxX - MARGIN_RIGHT
        // Block's padded top-right corner sits MARGIN in from the visible corner
        let textOrigin = NSPoint(
            x: right - size.width + BLOCK_PADDING,
            y: visible.maxY - MARGIN_TOP - size.height + BLOCK_PADDING)
        let textWindow = makeWindow(NSRect(origin: textOrigin, size: size), level: TEXT_LEVEL, clickable: false)
        textWindow.contentView = BlockView(frame: NSRect(origin: .zero, size: size))

        // Gear centered on the subtitle row, flush with the name's right edge
        let row = BlockView.subtitleRow()
        let rowCenterY = textOrigin.y + size.height - row.top - row.height / 2
        let gearFrame = NSRect(x: right - GEAR_SIZE, y: rowCenterY - GEAR_SIZE / 2, width: GEAR_SIZE, height: GEAR_SIZE)
        let gearWindow = makeWindow(gearFrame, level: CLOCK_LEVEL, clickable: true)
        let gearButton = GlassButton(title: "Settings", style: .tab, symbolName: GEAR_SYMBOL_NAME) {}
        gearButton.toolTip = "Overlay settings"
        gearWindow.contentView = makeGlassCard(
            frame: NSRect(origin: .zero, size: gearFrame.size), content: gearButton, cornerRadius: GEAR_CORNER_RADIUS)

        let rowBottom = textOrigin.y + size.height - row.top - row.height
        let clockWidth = BlockView.nameWidth()
        let clockOrigin = NSPoint(x: right - clockWidth, y: rowBottom - CLOCK_GAP - CLOCK_HEIGHT)
        let clockWindow = makeWindow(
            NSRect(origin: clockOrigin, size: NSSize(width: clockWidth, height: CLOCK_HEIGHT)),
            level: CLOCK_LEVEL, clickable: true)
        let view = ClockView(frame: NSRect(x: 0, y: 0, width: clockWidth, height: CLOCK_HEIGHT), model: clock)
        clockWindow.contentView = makeGlassCard(frame: view.frame, content: view)

        let lyricsFrame = NSRect(origin: NSPoint(x: visible.minX + LYRICS_MARGIN.x, y: visible.minY + LYRICS_MARGIN.y),
                                 size: LYRICS_BOX)
        let lyricsWindow = makeWindow(lyricsFrame, level: TEXT_LEVEL, clickable: false)
        let lyricsView = LyricsView(frame: NSRect(origin: .zero, size: LYRICS_BOX))
        lyricsWindow.contentView = lyricsView

        let backdrop = renderer.map { renderer -> NSWindow in
            let window = makeWindow(screen.frame, level: BACKDROP_LEVEL, clickable: false)
            window.contentView = renderer.makeView(frame: NSRect(origin: .zero, size: screen.frame.size))
            return window
        }

        backdrop?.orderFrontRegardless()
        textWindow.orderFrontRegardless()
        gearWindow.orderFrontRegardless()
        lyricsWindow.orderFrontRegardless()
        if settings.isClockVisible { clockWindow.orderFrontRegardless() }
        let windows = ScreenWindows(
            backdrop: backdrop, text: textWindow, gear: gearWindow, gearButton: gearButton,
            clock: clockWindow, clockView: view, lyrics: lyricsWindow, lyricsView: lyricsView,
            clockHomeOrigin: clockOrigin,
            panelTopRight: NSPoint(x: right, y: rowBottom - PANEL_GAP))
        // Capture only the point, not the windows: holding them here would keep
        // every screen's windows alive after a rebuild
        let panelTopRight = windows.panelTopRight
        gearButton.action = { [weak self] in self?.controlCenter.toggle(topRight: panelTopRight) }
        return windows
    }

    private func makeWindow(_ frame: NSRect, level: NSWindow.Level, clickable: Bool) -> NSWindow {
        let window = ClickThroughFocusPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = !clickable
        window.level = level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        return window
    }
}

func playFinishSound() {
    guard let sound = NSSound(named: FINISH_SOUND_NAME) else { return }
    var remaining = FINISH_SOUND_REPEATS
    func playNext() {
        guard remaining > 0, let copy = sound.copy() as? NSSound else { return }
        remaining -= 1
        copy.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { playNext() }
    }
    playNext()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = OverlayController()
controller.start()
app.run()
