// Stand-ins for the few Style.swift symbols LyricsView.swift uses, so the suite
// doesn't pull in the config and the rest of the app.
import AppKit

let TEXT_COLOR = NSColor.white
let SHADOW_COLOR = NSColor.black

func tracked(_ text: String, font: NSFont, tracking: CGFloat, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
}

func visibleWidth(_ s: NSAttributedString, tracking: CGFloat) -> CGFloat { s.size().width - tracking }
