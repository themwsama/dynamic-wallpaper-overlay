// Texture of the nixie-tube glyphs "0"-"9" and ".", one cell each, left to
// right. Red holds the sharp glyph (the lit cathode), green a blurred copy
// (its orange glow).
import AppKit
import CoreImage
import Metal

enum DigitAtlas {
    static let glyphs = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "."]
    static let cellWidth = 96
    static let cellHeight = 144

    static func makeTexture(device: MTLDevice) -> MTLTexture? {
        let width = cellWidth * glyphs.count
        let height = cellHeight
        guard let sharp = renderGlyphs(width: width, height: height),
              let glow = blurred(sharp, width: width, height: height) else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = sharp[i]
            rgba[i * 4 + 1] = UInt8(min(255, Int(glow[i]) * NIXIE_GLOW_GAIN))
            rgba[i * 4 + 3] = 255
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: rgba, bytesPerRow: width * 4)
        return texture
    }

    private static func renderGlyphs(width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let cg = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            for (i, glyph) in glyphs.enumerated() {
                let text = NSAttributedString(string: glyph, attributes: [.font: NIXIE_FONT, .foregroundColor: NSColor.white])
                let size = text.size()
                text.draw(at: NSPoint(x: CGFloat(i * cellWidth) + (CGFloat(cellWidth) - size.width) / 2,
                                      y: (CGFloat(height) - size.height) / 2))
            }
            return true
        }
        return didDraw ? pixels : nil
    }

    private static func blurred(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8]? {
        let input = CIImage(bitmapData: Data(pixels), bytesPerRow: width,
                            size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
        let blur = input.clampedToExtent().applyingGaussianBlur(sigma: NIXIE_GLOW_SIGMA).cropped(to: input.extent)
        var out = [UInt8](repeating: 0, count: width * height)
        CIContext().render(blur, toBitmap: &out, rowBytes: width, bounds: input.extent, format: .L8, colorSpace: nil)
        return out
    }
}
