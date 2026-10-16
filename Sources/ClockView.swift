// Liquid Glass card with a stopwatch / timer: mode tabs, the time, and
// Reset / -  + / Start buttons. Scrolling over the time also sets the timer.
import AppKit

enum ButtonStyle {
    case pill, tab
}

final class GlassButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    private let style: ButtonStyle
    private let symbolName: String?
    var action: () -> Void
    var secondaryAction: (() -> Void)?  // right-click
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }

    // With a symbolName, draws that SF Symbol instead of the title text
    init(title: String, style: ButtonStyle, symbolName: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.symbolName = symbolName
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The overlay never becomes the active app, so take the very first click
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { isPressed = isEnabled }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if wasPressed && inside { action() }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let secondaryAction, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        secondaryAction()
    }

    override func draw(_ dirtyRect: NSRect) {
        if style == .pill { drawPillBackground() }
        if let symbolName {
            drawSymbol(symbolName)
            return
        }
        let label = tracked(title, font: CLOCK_LABEL_FONT, tracking: CLOCK_LABEL_TRACKING, color: labelColor())
        let size = label.size()
        let x = (bounds.width - (size.width - CLOCK_LABEL_TRACKING)) / 2
        label.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
        if style == .tab && isSelected {
            TEXT_COLOR.withAlphaComponent(0.7).setFill()
            NSRect(x: x, y: 1, width: size.width - CLOCK_LABEL_TRACKING, height: 1).fill()
        }
    }

    private func labelColor() -> NSColor {
        guard isEnabled else { return TEXT_COLOR.withAlphaComponent(0.25) }
        if style == .tab { return TEXT_COLOR.withAlphaComponent(isSelected || isHovered ? 0.95 : 0.5) }
        return TEXT_COLOR
    }

    private func drawSymbol(_ name: String) {
        let config = NSImage.SymbolConfiguration(pointSize: EFFECTS_SYMBOL_SIZE, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [labelColor()]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                              width: size.width, height: size.height))
    }

    private func drawPillBackground() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let fillAlpha: CGFloat = !isEnabled ? 0.04 : isPressed ? 0.28 : isHovered ? 0.18 : 0.1
        NSColor.white.withAlphaComponent(fillAlpha).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(isEnabled ? 0.28 : 0.1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class ClockView: NSView {
    private let model: ClockModel
    private let timeLabel = NSTextField(labelWithString: "")
    private var stopwatchTab: GlassButton!
    private var timerTab: GlassButton!
    private var resetButton: GlassButton!
    private var startButton: GlassButton!
    private var minusButton: GlassButton!
    private var plusButton: GlassButton!
    private var scrollAccumulator: CGFloat = 0

    override var isFlipped: Bool { true }

    init(frame: NSRect, model: ClockModel) {
        self.model = model
        super.init(frame: frame)
        buildSubviews()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildSubviews() {
        let w = bounds.width
        stopwatchTab = GlassButton(title: "STOPWATCH", style: .tab) { [model] in model.setMode(.stopwatch) }
        timerTab = GlassButton(title: "TIMER", style: .tab) { [model] in model.setMode(.timer) }
        stopwatchTab.frame = NSRect(x: w / 2 - 118, y: 14, width: 110, height: 22)
        timerTab.frame = NSRect(x: w / 2 + 8, y: 14, width: 110, height: 22)

        timeLabel.font = CLOCK_DIGIT_FONT
        timeLabel.textColor = TEXT_COLOR
        timeLabel.alignment = .center
        timeLabel.frame = NSRect(x: 0, y: 40, width: w, height: 66)

        resetButton = GlassButton(title: "RESET", style: .pill) { [model] in model.reset() }
        startButton = GlassButton(title: "START", style: .pill) { [model] in model.toggleRunning() }
        minusButton = GlassButton(title: "\u{2212}", style: .pill) { [model] in model.adjustDuration(minutes: -1) }
        plusButton = GlassButton(title: "+", style: .pill) { [model] in model.adjustDuration(minutes: 1) }
        resetButton.frame = NSRect(x: 22, y: 114, width: 100, height: 30)
        startButton.frame = NSRect(x: w - 122, y: 114, width: 100, height: 30)
        minusButton.frame = NSRect(x: w / 2 - 48, y: 114, width: 40, height: 30)
        plusButton.frame = NSRect(x: w / 2 + 8, y: 114, width: 40, height: 30)

        [stopwatchTab, timerTab, timeLabel, resetButton, startButton, minusButton, plusButton]
            .forEach { addSubview($0!) }
    }

    func refresh() {
        let isTimer = model.mode == .timer
        stopwatchTab.isSelected = !isTimer
        timerTab.isSelected = isTimer
        // Countdown rounds up so it reads 25:00 at the start and 00:01 in the last second
        let time = isTimer ? ceil(model.displayTime) : model.displayTime
        timeLabel.stringValue = formatClock(time, showTenths: !isTimer)
        timeLabel.textColor = model.isFinished ? CLOCK_FINISHED_COLOR : TEXT_COLOR
        startButton.title = model.isRunning ? "PAUSE" : "START"
        minusButton.isHidden = !isTimer
        plusButton.isHidden = !isTimer
        minusButton.isEnabled = model.canAdjustDuration
        plusButton.isEnabled = model.canAdjustDuration
    }

    // Scroll over the card to set the timer, one minute per notch
    override func scrollWheel(with event: NSEvent) {
        guard model.canAdjustDuration else { return }
        scrollAccumulator += event.scrollingDeltaY
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        while abs(scrollAccumulator) >= step {
            model.adjustDuration(minutes: scrollAccumulator > 0 ? 1 : -1)
            scrollAccumulator -= scrollAccumulator > 0 ? step : -step
        }
    }
}

// Real Liquid Glass on macOS 26+, frosted blur as the fallback
func makeGlassCard(frame: NSRect, content: NSView, cornerRadius: CGFloat = CLOCK_CORNER_RADIUS) -> NSView {
    content.frame = NSRect(origin: .zero, size: frame.size)
    content.autoresizingMask = [.width, .height]
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = cornerRadius
        glass.contentView = content
        return glass
    }
    let blur = NSVisualEffectView(frame: frame)
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = cornerRadius
    blur.layer?.masksToBounds = true
    blur.addSubview(content)
    return blur
}
