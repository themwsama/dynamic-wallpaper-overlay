// The mini TV's video popup: a glass card (like the stopwatch) that opens
// from the control center. Paste a YouTube link to add a video; each video in
// the list has a remove button that asks once before removing.
// The panel can become key (unlike the other overlay windows) so the link
// field takes typing, without bringing the app forward.
import AppKit

let VIDEO_PANEL_SIZE = NSSize(width: ControlCenterPanel.size(tileCount: PANEL_COLUMNS).width, height: 420)
let VIDEO_PANEL_PADDING: CGFloat = 18
let VIDEO_ROW_HEIGHT: CGFloat = 34
let VIDEO_FIELD_HEIGHT: CGFloat = 30
let VIDEO_REMOVE_CONFIRM_SECONDS: TimeInterval = 4
let VIDEO_TITLE_FONT = NSFont.systemFont(ofSize: 12, weight: .regular)
let VIDEO_STATUS_FONT = NSFont.systemFont(ofSize: 11, weight: .medium)
let VIDEO_ERROR_COLOR = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.58, alpha: 1)

// Accessory apps have no Edit menu, so ⌘V/⌘C/⌘X/⌘A/⌘Z are routed by hand
final class KeyableGlassPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let actions: [String: Selector] = [
            "v": #selector(NSText.paste(_:)), "c": #selector(NSText.copy(_:)),
            "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
            "z": Selector(("undo:")),
        ]
        // Straight to this panel's responder: the app is usually inactive, so
        // NSApp's key-window routing can't be relied on
        guard let action = actions[key], let responder = firstResponder else {
            return super.performKeyEquivalent(with: event)
        }
        return responder.tryToPerform(action, with: self)
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class VideoLibraryPanel: NSObject, NSTextFieldDelegate {
    private let library: VideoLibrary
    private var window: KeyableGlassPanel?
    private var monitors: [Any] = []
    private let linkField = NSTextField(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let listView = FlippedView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private var addButton: GlassButton!
    private var confirmingFile: String?
    private var renderedVideos: [MiniTVVideo]?  // rows are rebuilt only when this changes
    private var confirmReset: DispatchWorkItem?
    var onOpenChange: ((Bool) -> Void)?

    var isOpen: Bool { window != nil }

    init(library: VideoLibrary) {
        self.library = library
        super.init()
    }

    func toggle(topRight: NSPoint) {
        if isOpen { close() } else { open(topRight: topRight) }
    }

    func open(topRight: NSPoint) {
        guard !isOpen else { return }
        let size = VIDEO_PANEL_SIZE
        let frame = NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height)
        let panel = KeyableGlassPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = PANEL_LEVEL
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = makeGlassCard(
            frame: NSRect(origin: .zero, size: size), content: makeContent(size: size), cornerRadius: CLOCK_CORNER_RADIUS)

        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - PANEL_RISE))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(linkField)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PANEL_ANIMATION_DURATION
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(frame.origin)
        }
        window = panel
        renderedVideos = nil
        refresh()
        installMonitors()
        onOpenChange?(true)
    }

    func close() {
        guard let panel = window else { return }
        window = nil
        cancelConfirm()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PANEL_ANIMATION_DURATION * 0.7
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        onOpenChange?(false)
    }

    // Called by the owner whenever the library changes
    func refresh() {
        guard isOpen else { return }
        let status = library.status
        statusLabel.stringValue = status.text
        statusLabel.textColor = status.isError ? VIDEO_ERROR_COLOR : TEXT_COLOR.withAlphaComponent(0.75)
        let count = library.playlist.videos.count
        countLabel.stringValue = count == 1 ? "1 VIDEO" : "\(count) VIDEOS"
        // Status updates arrive many times a second while downloading; leave the
        // rows (and any click on their buttons) alone unless the list changed
        if library.playlist.videos != renderedVideos { rebuildRows() }
    }

    // MARK: layout

    private func makeContent(size: NSSize) -> NSView {
        let content = FlippedView(frame: NSRect(origin: .zero, size: size))
        let inner = size.width - VIDEO_PANEL_PADDING * 2

        let header = NSTextField(labelWithAttributedString: tracked(
            "MINI TV", font: PANEL_HEADER_FONT, tracking: 3, color: TEXT_COLOR))
        header.frame = NSRect(x: VIDEO_PANEL_PADDING, y: VIDEO_PANEL_PADDING - 2, width: inner / 2, height: 20)
        countLabel.font = CLOCK_LABEL_FONT
        countLabel.textColor = TEXT_COLOR.withAlphaComponent(0.5)
        countLabel.alignment = .right
        countLabel.frame = NSRect(x: VIDEO_PANEL_PADDING + inner / 2, y: VIDEO_PANEL_PADDING, width: inner / 2, height: 18)

        let fieldY = VIDEO_PANEL_PADDING + 30
        let addWidth: CGFloat = 64
        let fieldBox = NSView(frame: NSRect(x: VIDEO_PANEL_PADDING, y: fieldY,
                                            width: inner - addWidth - 8, height: VIDEO_FIELD_HEIGHT))
        fieldBox.wantsLayer = true
        fieldBox.layer?.cornerRadius = VIDEO_FIELD_HEIGHT / 2
        fieldBox.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        fieldBox.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        fieldBox.layer?.borderWidth = 1
        configureLinkField(width: fieldBox.frame.width)
        fieldBox.addSubview(linkField)

        addButton = GlassButton(title: "ADD", style: .pill) { [weak self] in self?.submitLink() }
        addButton.frame = NSRect(x: VIDEO_PANEL_PADDING + inner - addWidth, y: fieldY, width: addWidth, height: VIDEO_FIELD_HEIGHT)

        statusLabel.font = VIDEO_STATUS_FONT
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2
        statusLabel.cell?.wraps = true
        statusLabel.frame = NSRect(x: VIDEO_PANEL_PADDING + 4, y: fieldY + VIDEO_FIELD_HEIGHT + 8, width: inner - 8, height: 30)

        let listY = fieldY + VIDEO_FIELD_HEIGHT + 44
        scrollView.frame = NSRect(x: VIDEO_PANEL_PADDING - 6, y: listY,
                                  width: inner + 12, height: size.height - listY - VIDEO_PANEL_PADDING)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listView

        [header, countLabel, fieldBox, addButton, statusLabel, scrollView].forEach { content.addSubview($0!) }
        return content
    }

    private func configureLinkField(width: CGFloat) {
        linkField.isBezeled = false
        linkField.drawsBackground = false
        linkField.focusRingType = .none
        linkField.isEditable = true
        linkField.isSelectable = true
        linkField.usesSingleLineMode = true
        linkField.lineBreakMode = .byTruncatingHead
        linkField.font = VIDEO_TITLE_FONT
        linkField.textColor = TEXT_COLOR
        linkField.placeholderAttributedString = NSAttributedString(string: "Paste a YouTube link", attributes: [
            .font: VIDEO_TITLE_FONT, .foregroundColor: TEXT_COLOR.withAlphaComponent(0.4)])
        linkField.delegate = self
        linkField.target = self
        linkField.action = #selector(linkFieldSubmitted)
        let textHeight = ceil(VIDEO_TITLE_FONT.ascender - VIDEO_TITLE_FONT.descender) + 2
        linkField.frame = NSRect(x: 12, y: (VIDEO_FIELD_HEIGHT - textHeight) / 2, width: width - 24, height: textHeight)
    }

    private func rebuildRows() {
        listView.subviews.forEach { $0.removeFromSuperview() }
        let width = scrollView.contentSize.width
        let videos = library.playlist.videos
        renderedVideos = videos
        for (index, video) in videos.enumerated() {
            let row = makeRow(video: video, width: width)
            row.frame.origin = NSPoint(x: 0, y: CGFloat(index) * VIDEO_ROW_HEIGHT)
            listView.addSubview(row)
        }
        if videos.isEmpty {
            let empty = NSTextField(labelWithString: "No videos yet. Paste a link above.")
            empty.font = VIDEO_STATUS_FONT
            empty.textColor = TEXT_COLOR.withAlphaComponent(0.45)
            empty.frame = NSRect(x: 10, y: 8, width: width - 20, height: 18)
            listView.addSubview(empty)
        }
        listView.frame = NSRect(x: 0, y: 0, width: width,
                                height: max(scrollView.contentSize.height, CGFloat(videos.count) * VIDEO_ROW_HEIGHT))
    }

    private func makeRow(video: MiniTVVideo, width: CGFloat) -> NSView {
        let row = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: VIDEO_ROW_HEIGHT))
        let isConfirming = confirmingFile == video.file
        let buttonWidth: CGFloat = isConfirming ? 78 : 28

        let title = NSTextField(labelWithString: video.title)
        title.font = VIDEO_TITLE_FONT
        title.textColor = TEXT_COLOR.withAlphaComponent(0.9)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = video.title
        title.frame = NSRect(x: 10, y: (VIDEO_ROW_HEIGHT - 16) / 2, width: width - buttonWidth - 28, height: 16)
        row.addSubview(title)

        let file = video.file
        let button: GlassButton
        if isConfirming {
            button = GlassButton(title: "REMOVE", style: .pill) { [weak self] in self?.confirmRemove(file: file) }
        } else {
            button = GlassButton(title: "Remove \(video.title)", style: .tab, symbolName: "trash") { [weak self] in
                self?.askToRemove(file: file)
            }
            button.toolTip = "Remove from the mini TV"
        }
        button.frame = NSRect(x: width - buttonWidth - 10, y: (VIDEO_ROW_HEIGHT - 24) / 2, width: buttonWidth, height: 24)
        row.addSubview(button)

        let divider = NSView(frame: NSRect(x: 10, y: VIDEO_ROW_HEIGHT - 1, width: width - 20, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        row.addSubview(divider)
        return row
    }

    // MARK: actions

    @objc private func linkFieldSubmitted() { submitLink() }

    private func submitLink() {
        let link = linkField.stringValue
        guard !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if library.add(link: link) { linkField.stringValue = "" }
    }

    private func askToRemove(file: String) {
        confirmingFile = file
        confirmReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.cancelConfirm(); self?.rebuildRows() }
        }
        confirmReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + VIDEO_REMOVE_CONFIRM_SECONDS, execute: reset)
        rebuildRows()
    }

    private func confirmRemove(file: String) {
        cancelConfirm()
        library.remove(file: file)
    }

    private func cancelConfirm() {
        confirmReset?.cancel()
        confirmReset = nil
        confirmingFile = nil
    }

    // Clicks in other apps or in any of our other windows close it
    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self, let target = event.window else { return event }
            if target !== self.window { self.close() }
            return event
        }) {
            monitors.append(local)
        }
    }
}
