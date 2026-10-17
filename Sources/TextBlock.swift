// The name hairline rule and subtitle, right-aligned. The subtitle
// row leaves room at its right end for the gear button (its own window).
import AppKit

let SUB_MIN_FONT_SCALE: CGFloat = 0.6  // a long subtitle shrinks to this fraction, then overflows

// How the subtitle is drawn: possibly shrunk to fit, then letter-spaced to span `available`
struct SubtitleLayout {
    let font: NSFont
    let tracking: CGFloat
    let isShrunk: Bool
    let overflows: Bool
}

func subtitleLayout(text: String, font: NSFont, available: CGFloat) -> SubtitleLayout {
    func width(_ f: NSFont) -> CGFloat { tracked(text, font: f, tracking: 0, color: TEXT_COLOR).size().width }
    let natural = width(font)
    var fitted = font
    if natural > available, natural > 0 {
        let scale = max(SUB_MIN_FONT_SCALE, available / natural)
        fitted = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
    }
    let fittedWidth = width(fitted)
    let gaps = text.count - 1
    // Fewer than two characters have no gaps to spread; never negative tracking
    let tracking = gaps >= 1 ? max(0, (available - fittedWidth) / CGFloat(gaps)) : 0
    return SubtitleLayout(font: fitted, tracking: tracking,
                          isShrunk: fitted !== font, overflows: fittedWidth > available)
}

final class BlockView: NSView {
    override var isFlipped: Bool { true }
    private static var hasLoggedSubtitleFit = false

    static func nameWidth() -> CGFloat {
        visibleWidth(tracked(NAME_TEXT, font: NAME_FONT, tracking: NAME_TRACKING, color: TEXT_COLOR),
                     tracking: NAME_TRACKING)
    }

    static func blockSize() -> NSSize {
        let name = tracked(NAME_TEXT, font: NAME_FONT, tracking: NAME_TRACKING, color: TEXT_COLOR)
        let sub = tracked(SUB_TEXT, font: SUB_FONT, tracking: 0, color: TEXT_COLOR)
        let height = name.size().height + RULE_GAP + RULE_WIDTH + SUB_GAP + sub.size().height
        return NSSize(width: nameWidth() + BLOCK_PADDING * 2, height: height + BLOCK_PADDING * 2)
    }

    // The subtitle row's vertical extent, measured down from the block's top edge
    static func subtitleRow() -> (top: CGFloat, height: CGFloat) {
        let name = tracked(NAME_TEXT, font: NAME_FONT, tracking: NAME_TRACKING, color: TEXT_COLOR)
        let sub = tracked(SUB_TEXT, font: SUB_FONT, tracking: 0, color: TEXT_COLOR)
        return (BLOCK_PADDING + name.size().height + RULE_GAP + RULE_WIDTH + SUB_GAP, sub.size().height)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBlock(shadowColor: SHADOW_COLOR, blur: 14)
        drawBlock(shadowColor: GLOW_COLOR, blur: 5)
    }

    private func drawBlock(shadowColor: NSColor, blur: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let shadow = NSShadow()
        shadow.shadowColor = shadowColor
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = .zero
        shadow.set()

        let right = bounds.width - BLOCK_PADDING
        let name = tracked(NAME_TEXT, font: NAME_FONT, tracking: NAME_TRACKING, color: TEXT_COLOR)
        let nameWidth = visibleWidth(name, tracking: NAME_TRACKING)
        var y = BLOCK_PADDING
        name.draw(at: NSPoint(x: right - nameWidth, y: y))
        y += name.size().height + RULE_GAP

        RULE_COLOR.setFill()
        NSRect(x: right - nameWidth, y: y, width: nameWidth, height: RULE_WIDTH).fill()
        y += RULE_WIDTH + SUB_GAP

        // Track the subtitle so it spans the name's width, minus the gear at its end
        let layout = subtitleLayout(text: SUB_TEXT, font: SUB_FONT, available: nameWidth - GEAR_SIZE - GEAR_GAP)
        logSubtitleFitOnce(layout)
        let sub = tracked(SUB_TEXT, font: layout.font, tracking: layout.tracking, color: TEXT_COLOR)
        sub.draw(at: NSPoint(x: right - nameWidth, y: y))
    }

    // draw() runs often; say it once
    private func logSubtitleFitOnce(_ layout: SubtitleLayout) {
        guard layout.isShrunk || layout.overflows, !Self.hasLoggedSubtitleFit else { return }
        Self.hasLoggedSubtitleFit = true
        NSLog("wallpaper-overlay: subtitle is wider than the name; %@",
              layout.overflows ? "shrunk to the minimum size and still overflows, shorten it" : "shrunk to fit")
    }
}
