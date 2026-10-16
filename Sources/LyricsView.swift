// Kinetic lyric line in the lower-left box, in the style of a Japanese lyric
// video ("stagger rise"): characters rise in one by one out of a blur, a
// karaoke sweep in the genre's color crosses the line over its duration,
// and the line drifts up and fades as the next one arrives. Optional romaji
// sits small underneath. Core Animation does all of it on the GPU.
import AppKit
import QuartzCore

let LYRICS_BOX = NSSize(width: 360, height: 104)
let LYRICS_MARGIN = NSPoint(x: 43, y: 44)  // from the visible frame's bottom-left corner
let LYRICS_OPACITY: Float = 0.85
let LYRICS_FONT_SIZE: CGFloat = 22
let LYRICS_WRAP_FONT_SIZE: CGFloat = 17      // below this a line wraps onto two rows instead
let LYRICS_MIN_FONT_SIZE: CGFloat = 13       // two-row lines shrink to fit, down to this
let LYRICS_TRACKING: CGFloat = 3
let LYRICS_ROMAJI_FONT = NSFont(name: "Baskerville", size: 11) ?? .systemFont(ofSize: 11)
let LYRICS_ROMAJI_TRACKING: CGFloat = 2
let LYRICS_LINE_GAP: CGFloat = 5
let LYRICS_CHAR_STAGGER: CFTimeInterval = 0.045
let LYRICS_ENTRY_DURATION: CFTimeInterval = 0.7
let LYRICS_EXIT_DURATION: CFTimeInterval = 0.4
let LYRICS_ENTRY_RISE: CGFloat = 14
let LYRICS_ENTRY_BLUR: CGFloat = 8
let LYRICS_FADE_DURATION: CFTimeInterval = 0.6  // whole box, on pause or toggle
let LYRICS_JAPANESE_FONT = "HiraMinProN-W6"
let LYRICS_LATIN_FONT = "Baskerville-SemiBold"

func containsJapanese(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
}

final class LyricsView: NSView {
    private let root = CALayer()
    private var current: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.opacity = 0
        layer = root
        wantsLayer = true
        layerUsesCoreImageFilters = true  // for the blur-in
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setVisible(_ visible: Bool) {
        let target: Float = visible ? LYRICS_OPACITY : 0
        guard root.opacity != target else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = root.presentation()?.opacity ?? root.opacity
        fade.toValue = target
        fade.duration = LYRICS_FADE_DURATION
        root.opacity = target
        root.add(fade, forKey: "visibility")
    }

    func clear() {
        retireCurrentLine()
    }

    // Immediate removal once the box is already invisible, freeing every layer
    func removeLine() {
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        current = nil
    }

    // `duration` is how long the line stays up; the karaoke sweep spans it.
    // Long lines wrap onto two rows; the sweep crosses them in reading order.
    func show(text: String, romaji: String?, duration: TimeInterval, accent: NSColor, reducedMotion: Bool) {
        retireCurrentLine()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        let (rows, font) = layoutRows(for: trimmed)
        let rowHeight = ceil(font.ascender - font.descender + font.leading) + 2
        let romajiHeight = romaji == nil ? 0 : ceil(LYRICS_ROMAJI_FONT.ascender - LYRICS_ROMAJI_FONT.descender) + 2

        let container = CALayer()
        container.frame = bounds
        container.shadowColor = SHADOW_COLOR.cgColor
        container.shadowOpacity = 1
        container.shadowRadius = 9
        container.shadowOffset = .zero
        root.addSublayer(container)
        current = container

        // Bottom-up: romaji on the floor of the box, the rows stacked above it
        let now = CACurrentMediaTime()
        let sweepStart = now + (reducedMotion ? 0 : LYRICS_ENTRY_DURATION * 0.8)
        let sweepTotal = max(0.5, duration - (sweepStart - now) - 0.3)
        let totalCharacters = Double(rows.reduce(0) { $0 + $1.count })
        var characterIndex = 0
        var sweepBegin = sweepStart
        for (rowIndex, row) in rows.enumerated() {
            let y = romajiHeight + (romaji == nil ? 0 : LYRICS_LINE_GAP) + CGFloat(rows.count - 1 - rowIndex) * rowHeight
            let line = tracked(row, font: font, tracking: LYRICS_TRACKING, color: TEXT_COLOR)
            for (character, x, width) in characterOffsets(line) {
                defer { characterIndex += 1 }
                guard !character.isWhitespace else { continue }
                let glyph = CATextLayer()
                glyph.string = tracked(String(character), font: font, tracking: 0, color: TEXT_COLOR)
                glyph.contentsScale = scale
                glyph.frame = NSRect(x: x, y: y, width: width + 4, height: rowHeight)
                container.addSublayer(glyph)
                if !reducedMotion { animateEntry(glyph, begin: now + Double(characterIndex) * LYRICS_CHAR_STAGGER) }
            }
            let rowDuration = sweepTotal * Double(row.count) / max(1, totalCharacters)
            addSweep(to: container, line: line, accent: accent,
                     frame: NSRect(x: 0, y: y, width: visibleWidth(line, tracking: LYRICS_TRACKING) + 4, height: rowHeight),
                     begin: sweepBegin, duration: rowDuration, scale: scale)
            sweepBegin += rowDuration
        }
        if let romaji {
            let text = CATextLayer()
            text.string = tracked(romaji, font: LYRICS_ROMAJI_FONT, tracking: LYRICS_ROMAJI_TRACKING,
                                  color: TEXT_COLOR.withAlphaComponent(0.8))
            text.contentsScale = scale
            text.truncationMode = .end
            text.frame = NSRect(x: 0, y: 0, width: bounds.width, height: romajiHeight)
            container.addSublayer(text)
            fadeIn(text, begin: now + (reducedMotion ? 0 : 0.5))
        }
        if reducedMotion { fadeIn(container, begin: now) }
    }

    // One row at the largest size that fits; failing that, two rows split at
    // the space nearest the middle (or the middle character), shrunk to fit
    private func layoutRows(for text: String) -> ([String], NSFont) {
        let name = containsJapanese(text) ? LYRICS_JAPANESE_FONT : LYRICS_LATIN_FONT
        if let font = largestFittingFont(name: name, rows: [text], minimum: LYRICS_WRAP_FONT_SIZE) {
            return ([text], font)
        }
        let rows = splitNearMiddle(text)
        let font = largestFittingFont(name: name, rows: rows, minimum: LYRICS_MIN_FONT_SIZE)
            ?? NSFont(name: name, size: LYRICS_MIN_FONT_SIZE) ?? .systemFont(ofSize: LYRICS_MIN_FONT_SIZE)
        return (rows, font)
    }

    private func largestFittingFont(name: String, rows: [String], minimum: CGFloat) -> NSFont? {
        var size = LYRICS_FONT_SIZE
        while size >= minimum {
            let font = NSFont(name: name, size: size) ?? .systemFont(ofSize: size)
            let widest = rows.map {
                visibleWidth(tracked($0, font: font, tracking: LYRICS_TRACKING, color: TEXT_COLOR), tracking: LYRICS_TRACKING)
            }.max() ?? 0
            if widest <= bounds.width { return font }
            size -= 1
        }
        return nil
    }

    private func splitNearMiddle(_ text: String) -> [String] {
        let characters = Array(text)
        let middle = characters.count / 2
        let spaces = characters.indices.filter { characters[$0].isWhitespace }
        let cut = spaces.min { abs($0 - middle) < abs($1 - middle) } ?? middle
        let first = String(characters[..<cut]).trimmingCharacters(in: .whitespaces)
        let second = String(characters[cut...]).trimmingCharacters(in: .whitespaces)
        return [first, second].filter { !$0.isEmpty }
    }

    // Each character's x and advance from Core Text, so per-character layers
    // land exactly where the whole-line sweep layer draws them
    private func characterOffsets(_ line: NSAttributedString) -> [(Character, CGFloat, CGFloat)] {
        let ctLine = CTLineCreateWithAttributedString(line)
        let text = line.string
        var result: [(Character, CGFloat, CGFloat)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let start = CTLineGetOffsetForStringIndex(ctLine, text.utf16.distance(from: text.utf16.startIndex, to: index.samePosition(in: text.utf16) ?? text.utf16.startIndex), nil)
            let end = CTLineGetOffsetForStringIndex(ctLine, text.utf16.distance(from: text.utf16.startIndex, to: next.samePosition(in: text.utf16) ?? text.utf16.endIndex), nil)
            result.append((text[index], start, max(0, end - start)))
            index = next
        }
        return result
    }

    private func animateEntry(_ glyph: CALayer, begin: CFTimeInterval) {
        let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 0])
        blur?.name = "blur"
        glyph.filters = blur.map { [$0] }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -LYRICS_ENTRY_RISE  // y points up: start below
        rise.toValue = 0
        let sharpen = CABasicAnimation(keyPath: "filters.blur.inputRadius")
        sharpen.fromValue = LYRICS_ENTRY_BLUR
        sharpen.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise, sharpen]
        group.beginTime = begin
        group.duration = LYRICS_ENTRY_DURATION
        group.fillMode = .backwards
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
        glyph.add(group, forKey: "entry")
        // A filtered layer keeps an offscreen buffer; drop the blur once it's sharp
        let settle = begin - CACurrentMediaTime() + LYRICS_ENTRY_DURATION + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak glyph] in glyph?.filters = nil }
    }

    // The line again in the accent color, revealed left to right by a growing mask
    private func addSweep(to container: CALayer, line: NSAttributedString, accent: NSColor, frame: NSRect,
                          begin: CFTimeInterval, duration: TimeInterval, scale: CGFloat) {
        let colored = NSMutableAttributedString(attributedString: line)
        colored.addAttribute(.foregroundColor, value: accent, range: NSRange(location: 0, length: colored.length))
        let sweep = CATextLayer()
        sweep.string = colored
        sweep.contentsScale = scale
        sweep.frame = frame
        sweep.shadowColor = accent.cgColor
        sweep.shadowOpacity = 0.9
        sweep.shadowRadius = 7
        sweep.shadowOffset = .zero
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.anchorPoint = .zero
        mask.frame = NSRect(x: 0, y: -8, width: 0, height: frame.height + 16)
        sweep.mask = mask
        container.addSublayer(sweep)

        let grow = CABasicAnimation(keyPath: "bounds.size.width")
        grow.fromValue = 0
        grow.toValue = frame.width
        grow.beginTime = begin
        grow.duration = max(0.5, duration - (begin - CACurrentMediaTime()) - 0.3)
        grow.fillMode = .both
        grow.isRemovedOnCompletion = false
        mask.add(grow, forKey: "sweep")
    }

    private func fadeIn(_ layer: CALayer, begin: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = begin
        fade.duration = 0.6
        fade.fillMode = .backwards
        layer.add(fade, forKey: "fadeIn")
    }

    // The outgoing line drifts up and fades, then is removed
    private func retireCurrentLine() {
        guard let old = current else { return }
        current = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = old.presentation()?.opacity ?? 1
        fade.toValue = 0
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = 0
        drift.toValue = 10  // y points up: drift upward
        let group = CAAnimationGroup()
        group.animations = [fade, drift]
        group.duration = LYRICS_EXIT_DURATION
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        old.opacity = 0
        old.add(group, forKey: "exit")
        CATransaction.commit()
    }
}
