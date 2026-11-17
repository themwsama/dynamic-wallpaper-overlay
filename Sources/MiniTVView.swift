// A compact, looping video card styled like a tiny retro television.
import AppKit
import AVFoundation

final class MiniTVView: NSView {
    private static let clipCrossfadeDuration: TimeInterval = 0.75
    private var videoURLs: [URL]
    private var currentVideoURL: URL?
    private var player: AVPlayer
    private var screenLayer = AVPlayerLayer()
    private var nextPlayer: AVPlayer?
    private var nextLayer: AVPlayerLayer?
    private var itemObservers: [NSObjectProtocol] = []
    private var isPlaying = true
    // Audio is per TV: each display's TV plays its own clip, so muting one must not touch the others.
    private var isAudioEnabled: Bool
    private var isSwitchingClips = false
    private let effectsView = CRTScreenEffectsView(frame: .zero)
    private let audioButton = NSButton(frame: .zero)
    let positionKey: String
    private var dragOffset = NSPoint.zero

    init(frame: NSRect, videoURLs: [URL], positionKey: String) {
        self.videoURLs = videoURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        self.positionKey = positionKey
        isAudioEnabled = UserDefaults.standard.bool(forKey: Self.audioEnabledKey(for: positionKey))
        currentVideoURL = self.videoURLs.first
        player = self.videoURLs.first.map(AVPlayer.init(url:)) ?? AVPlayer()
        super.init(frame: frame)

        wantsLayer = true
        layer?.masksToBounds = false
        screenLayer.player = player
        screenLayer.videoGravity = .resizeAspectFill
        screenLayer.cornerRadius = 8
        screenLayer.masksToBounds = true
        layer?.addSublayer(screenLayer)
        effectsView.frame = .zero
        addSubview(effectsView)
        player.isMuted = !isAudioEnabled
        player.preventsDisplaySleepDuringVideoPlayback = false
        configureAudioButton()
        addSubview(audioButton)
        observeItemEnd()
        if currentVideoURL != nil { player.play() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let screenFrame = CGRect(x: 13, y: 31, width: bounds.width - 26, height: bounds.width * 9 / 16)
        screenLayer.frame = screenFrame
        nextLayer?.frame = screenFrame
        effectsView.frame = screenFrame
        audioButton.frame = NSRect(x: bounds.width - 43, y: 4, width: 24, height: 20)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let cursor = window.convertPoint(toScreen: event.locationInWindow)
        dragOffset = NSPoint(x: cursor.x - window.frame.minX, y: cursor.y - window.frame.minY)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let cursor = window.convertPoint(toScreen: event.locationInWindow)
        var origin = NSPoint(x: cursor.x - dragOffset.x, y: cursor.y - dragOffset.y)
        if let visible = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - window.frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - window.frame.height)
        }
        window.setFrameOrigin(origin)
        UserDefaults.standard.set(origin.x, forKey: "\(positionKey).x")
        UserDefaults.standard.set(origin.y, forKey: "\(positionKey).y")
    }

    // Swap in a new playlist. A removed current clip moves on to another one;
    // a TV that had nothing to play starts with the first new clip.
    func setVideoURLs(_ urls: [URL]) {
        videoURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let current = currentVideoURL, videoURLs.contains(current) { return }
        startFirstClipOrStop()
    }

    private func startFirstClipOrStop() {
        guard !isSwitchingClips else { return }
        guard let first = videoURLs.first else {
            player.replaceCurrentItem(with: nil)
            currentVideoURL = nil
            return
        }
        if currentVideoURL == nil {
            player.replaceCurrentItem(with: AVPlayerItem(url: first))
            currentVideoURL = first
            if isPlaying { player.play() }
        } else {
            currentVideoURL = nil  // lets playNextClip pick any clip, including the first
            playNextClip()
        }
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        if playing {
            player.play()
            nextPlayer?.play()
        } else {
            player.pause()
            nextPlayer?.pause()
        }
    }

    private func configureAudioButton() {
        audioButton.isBordered = false
        audioButton.imagePosition = .imageOnly
        audioButton.imageScaling = .scaleProportionallyDown
        audioButton.wantsLayer = true
        audioButton.layer?.cornerRadius = 6
        audioButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        audioButton.target = self
        audioButton.action = #selector(toggleAudio)
        applyAudioButtonAppearance()
    }

    @objc private func toggleAudio() {
        let enabled = !isAudioEnabled
        UserDefaults.standard.set(enabled, forKey: Self.audioEnabledKey(for: positionKey))
        applyAudioEnabled(enabled)
    }

    static func audioEnabledKey(for positionKey: String) -> String { "\(positionKey).audioEnabled" }

    private func applyAudioEnabled(_ enabled: Bool) {
        isAudioEnabled = enabled
        player.isMuted = !enabled
        nextPlayer?.isMuted = !enabled
        applyAudioButtonAppearance()
    }

    private func applyAudioButtonAppearance() {
        let symbol = isAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
        let description = isAudioEnabled ? "Mute mini TV audio" : "Enable mini TV audio"
        audioButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        audioButton.contentTintColor = NSColor(srgbRed: 0.78, green: 0.94, blue: 0.86, alpha: 1)
        audioButton.toolTip = description
        audioButton.setAccessibilityLabel(description)
    }

    // A clip that ends, or fails mid-play (corrupt, removed), moves on to the next one
    private func observeItemEnd() {
        itemObservers = [Notification.Name.AVPlayerItemDidPlayToEndTime, .AVPlayerItemFailedToPlayToEndTime].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let endedItemID = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, endedItemID == self.player.currentItem.map(ObjectIdentifier.init) else { return }
                    self.playNextClip()
                }
            }
        }
    }

    private func playNextClip() {
        guard !isSwitchingClips else { return }
        let choices = videoURLs.filter { $0 != currentVideoURL }
        guard let nextURL = choices.randomElement() else {
            player.seek(to: .zero)
            if isPlaying { player.play() }
            return
        }

        isSwitchingClips = true
        let incomingPlayer = AVPlayer(url: nextURL)
        incomingPlayer.isMuted = !isAudioEnabled
        incomingPlayer.preventsDisplaySleepDuringVideoPlayback = false
        let incomingLayer = AVPlayerLayer(player: incomingPlayer)
        incomingLayer.frame = screenLayer.frame
        incomingLayer.videoGravity = .resizeAspectFill
        incomingLayer.cornerRadius = 8
        incomingLayer.masksToBounds = true
        incomingLayer.opacity = 0
        screenLayer.superlayer?.addSublayer(incomingLayer)
        nextPlayer = incomingPlayer
        nextLayer = incomingLayer
        if isPlaying { incomingPlayer.play() }

        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = Self.clipCrossfadeDuration
        fadeIn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        incomingLayer.opacity = 1
        incomingLayer.add(fadeIn, forKey: "clip-fade-in")

        let outgoingLayer = screenLayer
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = fadeIn.duration
        fadeOut.timingFunction = fadeIn.timingFunction
        outgoingLayer.opacity = 0
        outgoingLayer.add(fadeOut, forKey: "clip-fade-out")

        DispatchQueue.main.asyncAfter(deadline: .now() + fadeIn.duration) { [weak self] in
            guard let self, self.nextPlayer === incomingPlayer else { return }
            outgoingLayer.removeFromSuperlayer()
            self.player.pause()
            self.player = incomingPlayer
            self.screenLayer = incomingLayer
            self.currentVideoURL = nextURL
            self.nextPlayer = nil
            self.nextLayer = nil
            self.isSwitchingClips = false
            self.player.isMuted = !self.isAudioEnabled
            if self.isPlaying { self.player.play() }
            // The playlist may have changed while the clips were crossfading
            if !self.videoURLs.contains(nextURL) { self.startFirstClipOrStop() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 19, yRadius: 19)
        NSColor(srgbRed: 0.13, green: 0.15, blue: 0.19, alpha: 0.96).setFill()
        body.fill()
        NSColor.white.withAlphaComponent(0.32).setStroke()
        body.lineWidth = 1
        body.stroke()

        let label = NSAttributedString(string: "MINI  •  TV", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.75, green: 0.9, blue: 0.83, alpha: 0.9),
            .kern: 1.1,
        ])
        label.draw(at: NSPoint(x: 14, y: 10))

        let led = NSBezierPath(ovalIn: NSRect(x: bounds.width - 18, y: 10, width: 6, height: 6))
        NSColor(srgbRed: 0.95, green: 0.35, blue: 0.31, alpha: 0.95).setFill()
        led.fill()
    }

    isolated deinit {
        player.pause()
        nextPlayer?.pause()
        itemObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

private final class CRTScreenEffectsView: NSView {
    private var elapsed = 0.0
    private var tick: Timer?
    private let commercials = ["TUNE IN  •  STAY SHARP", "NOW SHOWING  •  CHANNEL 02", "YOUR NEXT FAVORITE THING"]

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        tick = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.elapsed += 0.12
                self.needsDisplay = true
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { superview?.mouseDragged(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        // Phosphor scanlines and moving snow give the footage a gentle CRT texture.
        for y in stride(from: 1.0, to: bounds.height, by: 3.0) {
            NSColor.black.withAlphaComponent(0.15).setFill()
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }
        let seed = Int(elapsed * 8)
        for index in 0..<55 {
            let x = CGFloat((index * 47 + seed * 31) % max(1, Int(bounds.width)))
            let y = CGFloat((index * 29 + seed * 17) % max(1, Int(bounds.height)))
            NSColor.white.withAlphaComponent(index.isMultiple(of: 5) ? 0.2 : 0.08).setFill()
            NSRect(x: x, y: y, width: 1.5, height: 1.5).fill()
        }

        // Every ~24 seconds the channel briefly cuts to a made-up TV spot.
        let phase = elapsed.truncatingRemainder(dividingBy: 24)
        guard phase > 18, phase < 21 else { return }
        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.11, alpha: 0.8).setFill()
        bounds.fill()
        let text = commercials[Int(elapsed / 24) % commercials.count]
        let caption = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 1, green: 0.84, blue: 0.45, alpha: 0.96),
            .kern: 0.3,
        ])
        let size = caption.size()
        caption.draw(at: NSPoint(x: max(3, (bounds.width - size.width) / 2), y: bounds.midY - size.height / 2))
    }

    isolated deinit { tick?.invalidate() }
}
