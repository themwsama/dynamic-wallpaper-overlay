// The name hairline rule and subtitle, right-aligned. The subtitle
// row leaves room at its right end for the gear button (its own window).
import AppKit

final class BlockView: NSView {
    override var isFlipped: Bool { true }

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
        let plainSub = tracked(SUB_TEXT, font: SUB_FONT, tracking: 0, color: TEXT_COLOR)
        let subWidth = nameWidth - GEAR_SIZE - GEAR_GAP
        let subTracking = (subWidth - plainSub.size().width) / CGFloat(SUB_TEXT.count - 1)
        let sub = tracked(SUB_TEXT, font: SUB_FONT, tracking: subTracking, color: TEXT_COLOR)
        sub.draw(at: NSPoint(x: right - nameWidth, y: y))
    }
}
