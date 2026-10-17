// Metal renderer for the wallpaper: shows the original or glass half of the
// stacked video and plays the transitions in Transition.metal between them.
// One renderer drives the MTKView on every screen.
import AVFoundation
import MetalKit

enum TransitionStyle: Int, CaseIterable {
    case crossfade = 0, stormRewind = 1, worldLineShift = 2, worldLine2 = 3

    var displayName: String {
        switch self {
        case .crossfade: return "Crossfade"
        case .stormRewind: return "Storm rewind"
        case .worldLineShift: return "World-line shift"
        case .worldLine2: return "Worldline 2"
        }
    }

    var duration: CFTimeInterval {
        switch self {
        case .crossfade: return CROSSFADE_DURATION
        case .stormRewind: return STORM_REWIND_DURATION
        case .worldLineShift: return WORLD_LINE_SHIFT_DURATION
        case .worldLine2: return WORLD_LINE_2_DURATION
        }
    }

    // Fits under a control center tile
    var shortName: String {
        switch self {
        case .crossfade: return "Fade"
        case .stormRewind: return "Storm"
        case .worldLineShift: return "World-line"
        case .worldLine2: return "Worldline 2"
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

// What one frame shows of the transition; `progress` 1 means none is running
private struct TransitionFrame {
    var style = TransitionStyle.crossfade
    var progress: Float = 1
    var fromEffects: Bool
}

let UNIFORMS_STRIDE = 160  // must equal Metal's sizeof(Uniforms); see Transition.metal
let NIXIE_MAX_DIGITS = 12
let NIXIE_POINT_INDEX = 10  // atlas cell after the digits 0-9
// Drawable pixels per video pixel (aspect-fill). The video has no detail beyond
// 1x, so idle frames render slightly above it and let the compositor scale
let IDLE_DRAWABLE_SCALE_CAP: CGFloat = 1.25

// MTKView that tells its renderer when it needs resizing or when its own
// window is covered, so each screen can pause on its own
final class BackdropView: MTKView {
    weak var owner: TransitionRenderer?
    fileprivate(set) var isOccluded = false
    private var occlusionObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        occlusionObserver.map(NotificationCenter.default.removeObserver)
        occlusionObserver = nil
        guard let window else { return }
        owner?.updateDrawableSize(of: self)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            // Delivered on `.main`, so this really is on the main actor
            MainActor.assumeIsolated { self?.syncOcclusion() }
        }
        // A window created under a full-screen app may never post a change, so seed
        // the state now and again once the window has been ordered front
        syncOcclusion()
        DispatchQueue.main.async { [weak self] in self?.syncOcclusion() }
    }

    private func syncOcclusion() {
        guard let window else { return }
        owner?.setWindowOccluded(window, !window.occlusionState.contains(.visible))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        owner?.updateDrawableSize(of: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        owner?.updateDrawableSize(of: self)
    }

    // Isolated: the observer token is main-actor state (views are released on main)
    isolated deinit {
        occlusionObserver.map(NotificationCenter.default.removeObserver)
    }
}

final class TransitionRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let worldLine2Pipeline: MTLRenderPipelineState
    private let atlas: MTLTexture
    private let textureCache: CVMetalTextureCache
    private let frames: VideoFrameSource
    private let views = NSHashTable<BackdropView>.weakObjects()
    private let clockStart = CACurrentMediaTime()
    private let digits: (count: Int, values: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>))
    private var lastBuffer: CVPixelBuffer?
    private var lastPlanes: (luma: CVMetalTexture?, chroma: CVMetalTexture?) = (nil, nil)
    private var active: ActiveTransition?
    private var isPaused = false  // global: asleep, locked, or every screen covered
    private(set) var showsEffects: Bool
    var glow: GlowController?
    private var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    init?(frames: VideoFrameSource, showsEffects: Bool) {
        // The uniform struct is copied byte for byte into the shader
        precondition(MemoryLayout<TransitionUniforms>.stride == UNIFORMS_STRIDE,
                     "TransitionUniforms must match Uniforms in Transition.metal")
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipelines = Self.makePipelines(device: device),
              let atlas = DigitAtlas.makeTexture(device: device) else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipelines.normal
        self.worldLine2Pipeline = pipelines.worldLine2
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

    // Posted on a background queue when macOS Low Power Mode turns on or off.
    // Nonisolated: Swift 6 checks the actor in @objc entry points, so a main-actor
    // method would trap when the notification arrives off main; it hops instead.
    @objc nonisolated private func powerStateChanged() {
        DispatchQueue.main.async {
            self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            self.updateFramesPerSecond()
        }
    }

    // Existing user shaders retain styles 0–2. Worldline 2 uses the bundled
    // shader unless the user's copy explicitly declares support for style 3.
    private static func makePipelines(
        device: MTLDevice, configShader: URL = TRANSITION_SHADER_URL,
        bundledShader: URL? = Bundle.main.url(forResource: "Transition", withExtension: "metal")
    ) -> (normal: MTLRenderPipelineState, worldLine2: MTLRenderPipelineState)? {
        var custom: MTLRenderPipelineState?
        var customSupportsWorldLine2 = false
        if FileManager.default.fileExists(atPath: configShader.path) {
            do {
                let source = try String(contentsOf: configShader, encoding: .utf8)
                custom = try buildPipeline(device: device, source: source, sourceName: configShader.lastPathComponent)
                customSupportsWorldLine2 = source.contains("// WORLDLINE2_SHADER_V1")
            } catch {
                NSLog("wallpaper-overlay: transition shader %@ failed, using the bundled copy: %@",
                      configShader.path, "\(error)")
            }
        }
        if customSupportsWorldLine2, let custom { return (custom, custom) }
        guard let bundledShader else {
            NSLog("wallpaper-overlay: transition shader failed: Worldline 2 requires a bundled shader")
            return nil
        }
        do {
            let bundled = try buildPipeline(device: device, source: bundledShader)
            return (custom ?? bundled, bundled)
        } catch {
            NSLog("wallpaper-overlay: transition shader failed: %@", "\(error)")
            return nil
        }
    }

    private struct ShaderError: Error, CustomStringConvertible {
        let description: String
    }

    private static func buildPipeline(device: MTLDevice, source url: URL) throws -> MTLRenderPipelineState {
        let source = try String(contentsOf: url, encoding: .utf8)
        return try buildPipeline(device: device, source: source, sourceName: url.lastPathComponent)
    }

    private static func buildPipeline(device: MTLDevice, source: String, sourceName: String) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "transitionFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        var reflection: MTLRenderPipelineReflection?
        let state = try device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo], reflection: &reflection)
        // A shader whose Uniforms differ in size from the Swift struct would read garbage
        if let size = uniformsBufferSize(reflection), size != MemoryLayout<TransitionUniforms>.stride {
            throw ShaderError(description: "Uniforms is \(size) bytes in \(sourceName) but "
                              + "TransitionUniforms is \(MemoryLayout<TransitionUniforms>.stride)")
        }
        return state
    }

    private static func uniformsBufferSize(_ reflection: MTLRenderPipelineReflection?) -> Int? {
        let argument = reflection?.fragmentBindings.first { $0.type == .buffer && $0.index == 0 }
        return (argument as? MTLBufferBinding)?.bufferDataSize
    }

    // e.g. "20.260101" -> digit values for the nixie tubes, "." = 10, max 12 characters.
    // Anything but ASCII 0-9 and "." is skipped, so the shader's atlas index stays in 0...10
    static func encodeDigits(_ text: String) -> (count: Int, values: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        let values: [Float] = text.compactMap { character in
            if character == "." { return Float(NIXIE_POINT_INDEX) }
            guard let ascii = character.asciiValue, ascii >= 48, ascii <= 57 else { return nil }
            return Float(ascii - 48)
        }.prefix(NIXIE_MAX_DIGITS).map { min(max($0, 0), Float(NIXIE_POINT_INDEX)) }
        let padded = values + Array(repeating: 0, count: NIXIE_MAX_DIGITS - values.count)
        return (values.count, (SIMD4(padded[0..<4]), SIMD4(padded[4..<8]), SIMD4(padded[8..<12])))
    }

    // Drawable pixels for a view of `native` pixels: never more than `scaleCap`
    // drawable pixels per video pixel once the video is aspect-filled to the view
    static func cappedDrawableSize(native: CGSize, videoSize: CGSize = VIDEO_SIZE, scaleCap: CGFloat?) -> CGSize {
        guard let scaleCap, native.width > 0, native.height > 0, videoSize.width > 0, videoSize.height > 0 else { return native }
        let fill = max(native.width / videoSize.width, native.height / videoSize.height)
        let factor = min(1, scaleCap / fill)
        return CGSize(width: max(1, (native.width * factor).rounded()), height: max(1, (native.height * factor).rounded()))
    }

    func makeView(frame: NSRect) -> MTKView {
        let view = BackdropView(frame: frame, device: device)
        view.owner = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = IDLE_FPS
        // Sized by updateDrawableSize so idle frames can be cheaper than native
        view.autoResizeDrawable = false
        // Two drawables instead of three: a wallpaper doesn't need deep buffering
        (view.layer as? CAMetalLayer)?.maximumDrawableCount = 2
        view.delegate = self
        view.isPaused = isPaused
        views.add(view)
        updateDrawableSize(of: view)
        return view
    }

    func updateDrawableSize(of view: MTKView) {
        // Full resolution only while a transition plays; the effects are pixel-level
        let cap = active == nil ? IDLE_DRAWABLE_SCALE_CAP : nil
        let target = Self.cappedDrawableSize(native: view.convertToBacking(view.bounds).size, scaleCap: cap)
        guard target.width >= 1, target.height >= 1, view.drawableSize != target else { return }
        view.drawableSize = target
    }

    // While hidden: stop drawing, stop decoding, and release every frame texture
    func setPaused(_ paused: Bool) {
        isPaused = paused
        views.allObjects.forEach(applyPause)
        if paused {
            frames.pause()
            lastBuffer = nil
            lastPlanes = (nil, nil)
            CVMetalTextureCacheFlush(textureCache, 0)
        } else {
            frames.resume()
        }
    }

    // One screen's window is covered (or not): only that screen stops drawing
    func setWindowOccluded(_ window: NSWindow, _ occluded: Bool) {
        for view in views.allObjects where view.window === window && view.isOccluded != occluded {
            view.isOccluded = occluded
            applyPause(view)
        }
    }

    private func applyPause(_ view: BackdropView) {
        view.isPaused = isPaused || view.isOccluded
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
        // Progress first: an expired transition must be cleared before the size
        // is chosen, so the drawable shrinks on the first idle frame
        let frame = advanceTransition(now: now)
        updateDrawableSize(of: view)
        var uniforms = makeUniforms(drawableSize: view.drawableSize, now: now, frame: frame)
        // Until the first frame decodes, draw nothing and let the wallpaper show through
        guard let video = currentVideoTextures(hostTime: now),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(frame.style == .worldLine2 ? worldLine2Pipeline : pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
        encoder.setFragmentTexture(video.luma, index: 0)
        encoder.setFragmentTexture(video.chroma, index: 2)
        encoder.setFragmentTexture(atlas, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // The GPU reads these planes after we return; a pause or the next frame may drop our own references.
        // nonisolated(unsafe): the completion handler (Metal's thread) only keeps the
        // array alive and never touches its contents
        nonisolated(unsafe) let held = video.held
        commands.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        commands.present(drawable)
        commands.commit()
    }

    // Clears the running transition once it is over
    private func advanceTransition(now: CFTimeInterval) -> TransitionFrame {
        guard let active else { return TransitionFrame(fromEffects: showsEffects) }
        let elapsed = (now - active.start) / active.style.duration
        guard elapsed < 1 else {
            self.active = nil
            return TransitionFrame(fromEffects: showsEffects)
        }
        return TransitionFrame(style: active.style, progress: Float(elapsed), fromEffects: active.fromEffects)
    }

    private func makeUniforms(drawableSize: CGSize, now: CFTimeInterval, frame: TransitionFrame) -> TransitionUniforms {
        let glowUniforms = glow?.uniforms(now: now) ?? GlowUniforms()
        updateFramesPerSecond()
        return TransitionUniforms(
            viewSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
            videoSize: SIMD2(Float(VIDEO_SIZE.width), Float(VIDEO_SIZE.height)),
            // Wrapped so float precision in the noise functions doesn't degrade over days
            time: Float((now - clockStart).truncatingRemainder(dividingBy: 1000)),
            progress: frame.progress,
            fromSource: frame.fromEffects ? 1 : 0,
            toSource: showsEffects ? 1 : 0,
            style: Float(frame.style.rawValue),
            digitCount: Float(digits.count),
            digits: digits.values,
            glow: glowUniforms)
    }

    private struct VideoTextures {
        let luma: MTLTexture
        let chroma: MTLTexture
        let held: [AnyObject]  // CVMetalTextures and their pixel buffer, kept until the GPU is done
    }

    // Wraps the newest frame's luma and chroma planes as Metal textures, reused across screens
    private func currentVideoTextures(hostTime: CFTimeInterval) -> VideoTextures? {
        guard let buffer = frames.pixelBuffer(atHostTime: hostTime) else { return nil }
        if buffer !== lastBuffer {
            lastBuffer = buffer
            lastPlanes = (planeTexture(buffer, plane: 0, format: .r8Unorm), planeTexture(buffer, plane: 1, format: .rg8Unorm))
            // Let the cache release textures for frames we've moved past
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        guard let lumaPlane = lastPlanes.luma, let chromaPlane = lastPlanes.chroma,
              let luma = CVMetalTextureGetTexture(lumaPlane),
              let chroma = CVMetalTextureGetTexture(chromaPlane) else { return nil }
        return VideoTextures(luma: luma, chroma: chroma, held: [lumaPlane, chromaPlane, buffer])
    }

    private func planeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        return texture
    }
}
