// Metal renderer for the wallpaper: shows the original or glass half of the
// stacked video and plays the transitions in Transition.metal between them.
// One renderer drives the MTKView on every screen.
import AVFoundation
import MetalKit

enum TransitionStyle: Int, CaseIterable {
    case crossfade = 0, stormRewind = 1, worldLineShift = 2

    var displayName: String {
        switch self {
        case .crossfade: return "Crossfade"
        case .stormRewind: return "Storm rewind"
        case .worldLineShift: return "World-line shift"
        }
    }

    var duration: CFTimeInterval {
        switch self {
        case .crossfade: return CROSSFADE_DURATION
        case .stormRewind: return STORM_REWIND_DURATION
        case .worldLineShift: return WORLD_LINE_SHIFT_DURATION
        }
    }

    // Fits under a control center tile
    var shortName: String {
        switch self {
        case .crossfade: return "Fade"
        case .stormRewind: return "Storm"
        case .worldLineShift: return "World-line"
        }
    }

    var next: TransitionStyle {
        TransitionStyle(rawValue: (rawValue + 1) % TransitionStyle.allCases.count) ?? .crossfade
    }
}

// Must match `Uniforms` in Transition.metal field for field
struct TransitionUniforms {
    var viewSize: SIMD2<Float>
    var videoSize: SIMD2<Float>
    var time: Float
    var progress: Float
    var fromSource: Float
    var toSource: Float
    var style: Float
    var digitCount: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var digits: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var glow: GlowUniforms
}

private struct ActiveTransition {
    let style: TransitionStyle
    let fromEffects: Bool
    let start: CFTimeInterval
}

final class TransitionRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let atlas: MTLTexture
    private let textureCache: CVMetalTextureCache
    private let frames: VideoFrameSource
    private let views = NSHashTable<MTKView>.weakObjects()
    private let clockStart = CACurrentMediaTime()
    private let digits: (count: Int, values: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>))
    private var lastBuffer: CVPixelBuffer?
    private var lastPlanes: (luma: CVMetalTexture?, chroma: CVMetalTexture?) = (nil, nil)
    private var active: ActiveTransition?
    private(set) var showsEffects: Bool
    var glow: GlowController?
    private var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    init?(frames: VideoFrameSource, showsEffects: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = Self.makePipeline(device: device),
              let atlas = DigitAtlas.makeTexture(device: device) else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.atlas = atlas
        self.textureCache = cache
        self.frames = frames
        self.showsEffects = showsEffects
        self.digits = Self.encodeDigits(DIVERGENCE_TEXT)
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil)
    }

    // Posted on a background queue when macOS Low Power Mode turns on or off
    @objc private func powerStateChanged() {
        DispatchQueue.main.async {
            self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.updateFramesPerSecond()
        }
    }

    private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        do {
            let source = try String(contentsOf: TRANSITION_SHADER_URL, encoding: .utf8)
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "transitionFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("wallpaper-overlay: transition shader failed: %@", "\(error)")
            return nil
        }
    }

    // e.g. "20.260101" -> digit values for the nixie tubes, "." = 10, max 12 characters
    private static func encodeDigits(_ text: String) -> (count: Int, values: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        let values = text.prefix(12).map { $0 == "." ? Float(10) : Float($0.wholeNumberValue ?? 0) }
        let padded = values + Array(repeating: 0, count: 12 - values.count)
        return (values.count, (SIMD4(padded[0..<4]), SIMD4(padded[4..<8]), SIMD4(padded[8..<12])))
    }

    func makeView(frame: NSRect) -> MTKView {
        let view = MTKView(frame: frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = IDLE_FPS
        // Two drawables instead of three: a wallpaper doesn't need deep buffering
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.delegate = self
        views.add(view)
        return view
    }

    // While hidden: stop drawing, stop decoding, and release every frame texture
    func setPaused(_ paused: Bool) {
        views.allObjects.forEach { $0.isPaused = paused }
        if paused {
            frames.pause()
            lastBuffer = nil
            lastPlanes = (nil, nil)
            CVMetalTextureCacheFlush(textureCache, 0)
        } else {
            frames.resume()
        }
    }

    // Starts a transition to the other half; ignored while one is running
    func transition(toEffects: Bool, style: TransitionStyle) -> Bool {
        guard active == nil, toEffects != showsEffects else { return false }
        active = ActiveTransition(style: style, fromEffects: showsEffects, start: CACurrentMediaTime())
        showsEffects = toEffects
        updateFramesPerSecond()
        return true
    }

    // Full rate while a transition or the music glow is animating, else the video's own
    // rate; Low Power Mode keeps everything at the video's rate
    private func updateFramesPerSecond() {
        let isAnimating = active != nil || glow?.isVisible == true
        let fps = isAnimating && !isLowPowerMode ? TRANSITION_FPS : IDLE_FPS
        for view in views.allObjects where view.preferredFramesPerSecond != fps {
            view.preferredFramesPerSecond = fps
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        var uniforms = makeUniforms(drawableSize: view.drawableSize, now: now)
        // Until the first frame decodes, draw nothing and let the wallpaper show through
        guard let video = currentVideoTextures(hostTime: now),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
        encoder.setFragmentTexture(video.luma, index: 0)
        encoder.setFragmentTexture(video.chroma, index: 2)
        encoder.setFragmentTexture(atlas, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private func makeUniforms(drawableSize: CGSize, now: CFTimeInterval) -> TransitionUniforms {
        var style = TransitionStyle.crossfade
        var progress: Float = 1
        var fromEffects = showsEffects
        if let active {
            let elapsed = (now - active.start) / active.style.duration
            if elapsed >= 1 {
                self.active = nil
            } else {
                style = active.style
                progress = Float(elapsed)
                fromEffects = active.fromEffects
            }
        }
        let glowUniforms = glow?.uniforms(now: now) ?? GlowUniforms()
        updateFramesPerSecond()
        return TransitionUniforms(
            viewSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            videoSize: SIMD2(Float(VIDEO_SIZE.width), Float(VIDEO_SIZE.height)),
            // Wrapped so float precision in the noise functions doesn't degrade over days
            time: Float((now - clockStart).truncatingRemainder(dividingBy: 1000)),
            progress: progress,
            fromSource: fromEffects ? 1 : 0,
            toSource: showsEffects ? 1 : 0,
            style: Float(style.rawValue),
            digitCount: Float(digits.count),
            digits: digits.values,
            glow: glowUniforms)
    }

    // Wraps the newest frame's luma and chroma planes as Metal textures, reused across screens
    private func currentVideoTextures(hostTime: CFTimeInterval) -> (luma: MTLTexture, chroma: MTLTexture)? {
        guard let buffer = frames.pixelBuffer(atHostTime: hostTime) else { return nil }
        if buffer !== lastBuffer {
            lastBuffer = buffer
            lastPlanes = (planeTexture(buffer, plane: 0, format: .r8Unorm), planeTexture(buffer, plane: 1, format: .rg8Unorm))
            // Let the cache release textures for frames we've moved past
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        guard let luma = lastPlanes.luma.flatMap(CVMetalTextureGetTexture),
              let chroma = lastPlanes.chroma.flatMap(CVMetalTextureGetTexture) else { return nil }
        return (luma, chroma)
    }

    private func planeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        return texture
    }
}
