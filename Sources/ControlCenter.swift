// The control center: a glass popover of toggle tiles that opens from the
// gear button beside the subtitle, iOS Control Center style. Clicking
// anywhere outside it closes it.
import AppKit

struct ControlTile {
    let symbol: String?          // SF Symbol name
    let glyph: String?           // text icon when no symbol fits (e.g. "あ")
    let title: () -> String
    let isOn: () -> Bool
    let isReadOnly: Bool
    let action: () -> Void
}

final class TileButton: NSView {
    private let tile: ControlTile
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    init(tile: ControlTile, frame: NSRect) {
        self.tile = tile
        super.init(frame: frame)
        toolTip = tile.isReadOnly ? "Set by macOS" : nil
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // The overlay never becomes the active app, so take the very first click
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = !tile.isReadOnly }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = !tile.isReadOnly }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        if wasPressed && bounds.contains(convert(event.locationInWindow, from: nil)) { tile.action() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let isOn = tile.isOn()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: TILE_CORNER_RADIUS, yRadius: TILE_CORNER_RADIUS)
        let fillAlpha: CGFloat = isOn ? (isPressed ? 0.7 : 0.86) : (isPressed ? 0.2 : isHovered ? 0.14 : 0.08)
        NSColor.white.withAlphaComponent(fillAlpha).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(isOn ? 0.6 : 0.16).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let ink = isOn ? TILE_ON_INK : TEXT_COLOR.withAlphaComponent(0.82)
        drawIcon(ink: ink)
        let label = NSAttributedString(string: tile.title(), attributes: [.font: TILE_LABEL_FONT, .foregroundColor: ink])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 12))
    }

    private func drawIcon(ink: NSColor) {
        let iconCenterY = bounds.height * 0.4
        if let name = tile.symbol,
           let image = NSImage(systemSymbolName: name, accessibilityDescription: tile.title())?
               .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: TILE_ICON_SIZE, weight: .regular)
                   .applying(NSImage.SymbolConfiguration(paletteColors: [ink]))) {
            let size = image.size
            image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: iconCenterY - size.height / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let glyph = tile.glyph {
            let text = NSAttributedString(string: glyph, attributes: [
                .font: NSFont(name: "Hiragino Mincho ProN", size: TILE_ICON_SIZE + 2) ?? .systemFont(ofSize: TILE_ICON_SIZE),
                .foregroundColor: ink])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: iconCenterY - size.height / 2))
        }
    }
}

final class ControlCenterPanel {
    private let tiles: [ControlTile]
    private let exemptWindows: () -> [NSWindow]  // e.g. the gear buttons, which toggle it themselves
    private var window: NSWindow?
    private var tileViews: [TileButton] = []
    private var monitors: [Any] = []
    var onOpenChange: ((Bool) -> Void)?

    var isOpen: Bool { window != nil }

    init(tiles: [ControlTile], exemptWindows: @escaping () -> [NSWindow]) {
        self.tiles = tiles
        self.exemptWindows = exemptWindows
    }

    static func size(tileCount: Int) -> NSSize {
        let rows = CGFloat((tileCount + PANEL_COLUMNS - 1) / PANEL_COLUMNS)
        let columns = CGFloat(PANEL_COLUMNS)
        return NSSize(
            width: PANEL_PADDING * 2 + columns * TILE_SIZE.width + (columns - 1) * TILE_GAP,
            height: PANEL_PADDING * 2 + PANEL_HEADER_HEIGHT + rows * TILE_SIZE.height + (rows - 1) * TILE_GAP)
    }

    // `topRight` is where the panel's top-right corner goes, in screen coordinates
    func toggle(topRight: NSPoint) {
        if isOpen { close() } else { open(topRight: topRight) }
    }

    func refresh() {
        tileViews.forEach { $0.needsDisplay = true }
    }

    func open(topRight: NSPoint) {
        let size = Self.size(tileCount: tiles.count)
        let frame = NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height)
        let panel = ClickThroughFocusPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = PANEL_LEVEL
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.contentView = makeGlassCard(
            frame: NSRect(origin: .zero, size: size), content: makeGrid(size: size), cornerRadius: PANEL_CORNER_RADIUS)

        // Fade in while settling up from just below
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY - PANEL_RISE))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PANEL_ANIMATION_DURATION
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(frame.origin)
        }
        window = panel
        installMonitors()
        onOpenChange?(true)
    }

    func close() {
        guard let panel = window else { return }
        window = nil
        tileViews = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PANEL_ANIMATION_DURATION * 0.7
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
        onOpenChange?(false)
    }

    private func makeGrid(size: NSSize) -> NSView {
        let grid = FlippedView(frame: NSRect(origin: .zero, size: size))
        let header = NSTextField(labelWithAttributedString: tracked(
            "OVERLAY", font: PANEL_HEADER_FONT, tracking: 3, color: TEXT_COLOR))
        header.frame = NSRect(x: PANEL_PADDING + 4, y: PANEL_PADDING - 2, width: size.width / 2, height: PANEL_HEADER_HEIGHT)
        grid.addSubview(header)
        tileViews = tiles.enumerated().map { index, tile in
            let column = CGFloat(index % PANEL_COLUMNS)
            let row = CGFloat(index / PANEL_COLUMNS)
            let origin = NSPoint(x: PANEL_PADDING + column * (TILE_SIZE.width + TILE_GAP),
                                 y: PANEL_PADDING + PANEL_HEADER_HEIGHT + row * (TILE_SIZE.height + TILE_GAP))
            let view = TileButton(tile: tile, frame: NSRect(origin: origin, size: TILE_SIZE))
            grid.addSubview(view)
            return view
        }
        return grid
    }

    // Clicks in other apps, or in our windows other than the panel and gears, close it.
    // Mouse-only global monitors need no Accessibility permission.
    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.close() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self, let target = event.window else { return event }
            if target !== self.window && !self.exemptWindows().contains(where: { $0 === target }) { self.close() }
            return event
        }) {
            monitors.append(local)
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
