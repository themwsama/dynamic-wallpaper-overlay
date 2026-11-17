// Dynamic wallpaper overlay: draws the name block as real text above the
// video wallpaper and below the desktop icons, anchored to each screen's
// top-right corner with a fixed margin, with a glass stopwatch / timer card
// underneath. A gear at the end of the subtitle row opens the control center,
// whose tiles toggle the clock, the wallpaper version (with an animated
// transition), the transition style, the music glow, lyrics, romaji and a
// draggable mini TV whose videos are added from YouTube links.
// The overlay renders the wallpaper video itself (Metal). While music plays,
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
    let screenFrame: NSRect
    let backdrop: NSWindow?
    let text: NSWindow
    let gear: NSWindow
    let gearButton: GlassButton
    let clock: NSWindow
    let clockView: ClockView
    let miniTV: NSWindow
    let miniTVView: MiniTVView
    let lyrics: NSWindow
    let lyricsView: LyricsView
    let clockHomeOrigin: NSPoint  // where the clock sits while the control center is closed
    let panelTopRight: NSPoint
}

// Display changes arrive in bursts (wake, arrange, resolution); rebuild once they settle
let SCREEN_REBUILD_DEBOUNCE: TimeInterval = 0.3

final class OverlayController: NSObject {
    private var screens: [ScreenWindows] = []
    private let settings = Settings()
    private let clock = ClockModel(defaultMinutes: TIMER_DEFAULT_MINUTES, maxMinutes: TIMER_MAX_MINUTES)
    private var ticker: Timer?
    private var transitionStyle: TransitionStyle {
        TransitionStyle(rawValue: settings.transitionStyleRaw) ?? Self.defaultTransitionStyle
    }
    // .crossfade only if DEFAULT_TRANSITION_STYLE_RAW itself were ever out of range
    private static let defaultTransitionStyle = TransitionStyle(rawValue: DEFAULT_TRANSITION_STYLE_RAW) ?? .crossfade
    // Without the video file or Metal, the overlay runs without the backdrop
    private lazy var renderer: TransitionRenderer? = VideoFrameSource(url: BACKDROP_VIDEO_URL)
        .flatMap { TransitionRenderer(frames: $0, showsEffects: settings.isEffectsVisible) }
    private let music = MusicSession()
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
        clock: music.makePlaybackClock(),
        views: { [weak self] in self?.screens.map(\.lyricsView) ?? [] },
        accent: { [weak self] in self?.glow?.accentColor ?? TEXT_COLOR })
    private lazy var controlCenter = ControlCenterPanel(
        tiles: makeTiles(), exemptWindows: { [weak self] in self?.screens.map(\.gear) ?? [] })
    private lazy var videoLibrary = VideoLibrary(directory: OVERLAY_DIR, seed: MINI_TV_DEFAULT_VIDEOS)
    private lazy var videoPanel = VideoLibraryPanel(library: videoLibrary)
    // The clock sits where the panel opens, so it slides down out of the way
    private var clockOffset: CGFloat {
        ControlCenterPanel.size(tileCount: makeTiles().count).height + PANEL_GAP
    }

    func start() {
        NSLog("wallpaper-overlay: using config dir %@ log %@", OVERLAY_DIR.path, Housekeeping.logURL.path)
        clock.onChange = { [weak self] in self?.refreshClocks() }
        clock.onFinish = { playFinishSound() }
        controlCenter.onOpenChange = { [weak self] isOpen in self?.controlCenterChanged(isOpen: isOpen) }
        videoPanel.onOpenChange = { [weak self] isOpen in
            self?.slideClocks(down: isOpen ? VIDEO_PANEL_SIZE.height + PANEL_GAP : 0)
        }
        videoLibrary.onChange = { [weak self] in self?.videoPanel.refresh() }
        videoLibrary.onPlaylistChange = { [weak self] urls in
            self?.screens.forEach { $0.miniTVView.setVideoURLs(urls) }
        }
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
            // Scheduled on the main run loop below, so this really is on the main actor
            MainActor.assumeIsolated {
                guard let self, self.clock.isRunning else { return }
                self.clock.tick()
                self.refreshClocks()
            }
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
        videoPanel.close()
        screens.forEach { $0.miniTVView.setPlaying(false) }  // old TVs would keep playing sound
        screens.flatMap { [$0.backdrop, $0.text, $0.gear, $0.clock, $0.miniTV, $0.lyrics].compactMap { $0 } }
            .forEach { $0.orderOut(nil) }
        screens = NSScreen.screens.map(makeWindows)
        // New windows start with an unknown occlusion state; check again once they're up
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.visibility.reevaluate() }
    }

    // Genre recolors the glow, lyrics follow the track, the glow follows the audio
    private func startMusicGlow() {
        let glow = GlowController(
            audioLevels: { [weak self] in self?.music.audioLevels() },
            isMusicPlaying: { [weak self] in self?.music.isPlaying ?? false })
        glow.isEnabled = settings.isMusicGlowEnabled
        renderer?.glow = glow
        self.glow = glow
        music.onTrack = { [weak self] track in
            guard let self else { return }
            let info = TrackInfo(trackID: track.id, name: track.name, artist: track.artist, album: track.album)
            // A slow lookup must not recolor the glow for a song that's no longer playing
            self.genres.resolve(info) { [weak self] genre, _ in
                guard self?.music.track?.id == track.id else { return }
                glow.setGenre(genre)
            }
            self.lyrics.trackChanged(track, position: self.music.lastPosition)
        }
        music.onPlayState = { [weak self] playing in self?.lyrics.playStateChanged(playing) }
        music.onPosition = { [weak self] seconds in self?.lyrics.positionChanged(seconds) }
        music.onEnded = { [weak self] in self?.lyrics.playbackEnded() }
        music.start()
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
            ControlTile(symbol: "tv", glyph: nil, title: { "Mini TV" },
                        isOn: { s.isMiniTVVisible }, isReadOnly: false,
                        action: { [weak self] in self?.toggleMiniTV() }),
            ControlTile(symbol: "plus.rectangle.on.rectangle", glyph: nil, title: { "TV videos" },
                        isOn: { [weak self] in self?.videoPanel.isOpen ?? false }, isReadOnly: false,
                        action: { [weak self] in self?.openVideoPanel() }),
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

    private func toggleMiniTV() {
        settings.isMiniTVVisible.toggle()
        screens.forEach { screen in
            screen.miniTVView.setPlaying(settings.isMiniTVVisible)
            if settings.isMiniTVVisible { screen.miniTV.orderFrontRegardless() } else { screen.miniTV.orderOut(nil) }
        }
    }

    // Opens on the display under the pointer, where the control center just was
    private func openVideoPanel() {
        let mouse = NSEvent.mouseLocation
        guard let screen = screens.first(where: { NSMouseInRect(mouse, $0.screenFrame, false) }) ?? screens.first
        else { return }
        controlCenter.close()
        videoPanel.open(topRight: screen.panelTopRight)
    }

    private func toggleGlow() {
        settings.isMusicGlowEnabled.toggle()
        glow?.isEnabled = settings.isMusicGlowEnabled
    }

    // Posted on a background queue. Nonisolated: Swift 6 checks the actor in @objc
    // entry points, so a main-actor method would trap there; it hops to main instead.
    @objc nonisolated private func powerStateChanged() {
        DispatchQueue.main.async { self.controlCenter.refresh() }
    }

    private func controlCenterChanged(isOpen: Bool) {
        screens.forEach { $0.gearButton.isSelected = isOpen }
        slideClocks(down: isOpen ? clockOffset : 0)
    }

    private func slideClocks(down offset: CGFloat) {
        for s in screens {
            let origin = NSPoint(x: s.clockHomeOrigin.x, y: s.clockHomeOrigin.y - offset)
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
            // AppKit runs animation completions on the main thread
            MainActor.assumeIsolated {
                // Skip if the user toggled back while the fade was running
                if !visible && !self.settings.isClockVisible { window.orderOut(nil) }
            }
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

        // The TV starts under the clock; once dragged, it reopens where it was left
        let tvKey = Self.miniTVPositionKey(for: screen)
        let defaultTVOrigin = NSPoint(x: right - MINI_TV_SIZE.width, y: clockOrigin.y - MINI_TV_GAP - MINI_TV_SIZE.height)
        let savedX = UserDefaults.standard.object(forKey: "\(tvKey).x") as? CGFloat ?? defaultTVOrigin.x
        let savedY = UserDefaults.standard.object(forKey: "\(tvKey).y") as? CGFloat ?? defaultTVOrigin.y
        let tvOrigin = NSPoint(x: min(max(savedX, visible.minX), visible.maxX - MINI_TV_SIZE.width),
                               y: min(max(savedY, visible.minY), visible.maxY - MINI_TV_SIZE.height))
        let miniTVWindow = makeWindow(NSRect(origin: tvOrigin, size: MINI_TV_SIZE), level: CLOCK_LEVEL, clickable: true)
        let miniTVView = MiniTVView(frame: NSRect(origin: .zero, size: MINI_TV_SIZE),
                                    videoURLs: videoLibrary.videoURLs, positionKey: tvKey)
        miniTVWindow.contentView = miniTVView

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
        if settings.isMiniTVVisible { miniTVWindow.orderFrontRegardless() } else { miniTVView.setPlaying(false) }
        let windows = ScreenWindows(
            screenFrame: screen.frame, backdrop: backdrop, text: textWindow, gear: gearWindow, gearButton: gearButton,
            clock: clockWindow, clockView: view, miniTV: miniTVWindow, miniTVView: miniTVView,
            lyrics: lyricsWindow, lyricsView: lyricsView,
            clockHomeOrigin: clockOrigin,
            panelTopRight: NSPoint(x: right, y: rowBottom - PANEL_GAP))
        // Capture only the point, not the windows: holding them here would keep
        // every screen's windows alive after a rebuild
        let panelTopRight = windows.panelTopRight
        gearButton.action = { [weak self] in self?.controlCenter.toggle(topRight: panelTopRight) }
        return windows
    }

    // One saved TV position per display
    private static func miniTVPositionKey(for screen: NSScreen) -> String {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return "miniTV.\(displayID?.stringValue ?? screen.localizedName)"
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
