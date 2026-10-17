// Drives the music glow at the bottom of the wallpaper: fades it in while
// Spotify is audibly playing and out when it stops, blends to the current
// genre's colors, and turns loudness and beats into pulse and ember speed.
// Values from the Claude Design "Music Glow Study" canvas.
import AppKit
import QuartzCore

let GLOW_FADE_IN_SECONDS: Double = 0.9    // time constant; ~2.5 s to full
let GLOW_FADE_OUT_SECONDS: Double = 1.2
let GLOW_COLOR_BLEND_SECONDS: Double = 0.5  // time constant; ~1.5 s to the new genre
let GLOW_SILENCE_GRACE: CFTimeInterval = 1.5  // gaps between tracks don't drop the glow
let GLOW_BEAT_DECAY: Double = 0.18
let GLOW_LEVEL_GAIN: Float = 5             // typical music RMS ~0.1-0.2 -> energy ~0.5-1
let GLOW_INTENSITY: Float = 0.22
let GLOW_HEIGHT: Float = 0.34              // fraction of screen height
let GLOW_SPARK_COUNT: Float = 8
let GLOW_TEMPO_BLEND_SECONDS: Double = 1.0 // tempo changes ease in rather than jump
// Spotify says it's playing but the tap hears nothing (e.g. the audio permission was
// denied, which yields silent buffers): after this long, pulse from the play state
let GLOW_TAP_SILENCE_FALLBACK: CFTimeInterval = 3
let GLOW_PATH_BLEND_SECONDS: Double = 0.5  // crossfade between the real and simulated pulse
let GLOW_SIMULATED_ENERGY: Float = 0.5

struct GenreLook {
    let colorA: SIMD3<Float>
    let colorB: SIMD3<Float>
    let bpm: Double          // only paces the pulse when the audio tap is unavailable
    let punch: Float         // how hard beats kick the glow
}

func hexColor(_ hex: UInt32) -> SIMD3<Float> {
    SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
}

let GENRE_LOOKS: [GenreBucket: GenreLook] = [
    .lofiChill: GenreLook(colorA: hexColor(0x7AA2FF), colorB: hexColor(0xB48CFF), bpm: 75, punch: 0.5),
    .pop: GenreLook(colorA: hexColor(0xFF8FB8), colorB: hexColor(0xFFC29A), bpm: 116, punch: 0.9),
    .hipHopRnb: GenreLook(colorA: hexColor(0x8A5CFF), colorB: hexColor(0xFFC46B), bpm: 92, punch: 1.0),
    .electronic: GenreLook(colorA: hexColor(0x2EE6FF), colorB: hexColor(0xFF3DF0), bpm: 128, punch: 1.0),
    .rockMetal: GenreLook(colorA: hexColor(0xFF4A2E), colorB: hexColor(0xFF9A3D), bpm: 140, punch: 0.9),
    .classical: GenreLook(colorA: hexColor(0xFFD58A), colorB: hexColor(0xFFF1C9), bpm: 60, punch: 0.35),
    .jazzSoul: GenreLook(colorA: hexColor(0xFFB35C), colorB: hexColor(0xC97A4A), bpm: 90, punch: 0.5),
    .animeJpopGame: GenreLook(colorA: hexColor(0xFFB7D5), colorB: hexColor(0x9FD8FF), bpm: 130, punch: 0.7),
    .worshipGospel: GenreLook(colorA: hexColor(0xFFE3A3), colorB: hexColor(0xA8D8FF), bpm: 72, punch: 0.4),
    .defaultMix: GenreLook(colorA: hexColor(0x6F86FF), colorB: hexColor(0xA07CFF), bpm: 100, punch: 0.6),
]

// Packed for Transition.metal's `Uniforms` glow fields
struct GlowUniforms {
    var colorA = SIMD4<Float>(0, 0, 0, 0)
    var colorB = SIMD4<Float>(0, 0, 0, 0)
    var params = SIMD4<Float>(0, 0, 0, 0)  // presence, energy, beat, sparkTime (in beats)
    var shape = SIMD4<Float>(GLOW_HEIGHT, GLOW_SPARK_COUNT, GLOW_INTENSITY, 0)
}

final class GlowController {
    private let audioLevels: () -> AudioLevels?   // nil when the tap isn't running or isn't healthy
    private let isSpotifyPlaying: () -> Bool
    private var look = GENRE_LOOKS[.defaultMix]!
    private var colorA = GENRE_LOOKS[.defaultMix]!.colorA
    private var colorB = GENRE_LOOKS[.defaultMix]!.colorB
    private var presence: Double = 0
    private var energy: Float = 0
    private var sparkTime: Double = 0
    private var tempo: Double = 100
    private var lastUpdate: CFTimeInterval?
    private var realWeight: Double = 0  // 1 = driven by the tap, 0 = simulated from the play state
    private var lastRealLevels: AudioLevels?  // what the real side fades out from
    private var wasSpotifyPlaying = false
    private var playStartedAt: CFTimeInterval = -.infinity
    var isEnabled = true  // the control center's Glow tile; turning it off fades the glow out

    init(audioLevels: @escaping () -> AudioLevels?, isSpotifyPlaying: @escaping () -> Bool) {
        self.audioLevels = audioLevels
        self.isSpotifyPlaying = isSpotifyPlaying
    }

    // The genre color currently showing, mid-blend included; the lyric sweep uses it
    var accentColor: NSColor {
        NSColor(srgbRed: CGFloat(colorA.x), green: CGFloat(colorA.y), blue: CGFloat(colorA.z), alpha: 1)
    }

    func setGenre(_ genre: GenreBucket) {
        look = GENRE_LOOKS[genre] ?? GENRE_LOOKS[.defaultMix]!
    }

    // True while anything is still visible, so the renderer can run at full frame rate
    var isVisible: Bool { presence > 0.002 }

    // Called once per drawn frame; safe to call from several screens per frame
    func uniforms(now: CFTimeInterval) -> GlowUniforms {
        let dt = min(0.1, max(0, now - (lastUpdate ?? now)))
        lastUpdate = now
        let spotifyPlaying = isSpotifyPlaying()
        if spotifyPlaying && !wasSpotifyPlaying { playStartedAt = now }
        wasSpotifyPlaying = spotifyPlaying
        let levels = realLevels(now: now, spotifyPlaying: spotifyPlaying)
        // Linear, so a switch in either direction lands in GLOW_PATH_BLEND_SECONDS with no pop
        let step = dt / GLOW_PATH_BLEND_SECONDS
        realWeight = levels == nil ? max(0, realWeight - step) : min(1, realWeight + step)
        let w = Float(realWeight)
        if let levels { lastRealLevels = levels }
        let fading = levels ?? lastRealLevels

        let isPlaying = isEnabled && (levels.map { now - $0.lastSound < GLOW_SILENCE_GRACE } ?? spotifyPlaying)
        let realBeat = fading.map { Float(exp(-max(0, now - $0.lastBeat) / GLOW_BEAT_DECAY)) } ?? 0
        let beat = simulatedBeat(now) * (1 - w) + realBeat * w
        let realEnergy = fading.map { min(1, $0.level * GLOW_LEVEL_GAIN) } ?? 0
        let targetEnergy = GLOW_SIMULATED_ENERGY * (1 - w) + realEnergy * w

        presence = approach(presence, isPlaying ? 1 : 0, dt: dt,
                            tau: isPlaying ? GLOW_FADE_IN_SECONDS : GLOW_FADE_OUT_SECONDS)
        energy += (targetEnergy - energy) * Float(1 - exp(-dt / 0.08))
        let colorStep = Float(1 - exp(-dt / GLOW_COLOR_BLEND_SECONDS))
        colorA += (look.colorA - colorA) * colorStep
        colorB += (look.colorB - colorB) * colorStep
        // The ember clock counts beats of the song's tempo (measured from the audio,
        // else the genre's typical tempo), with a small surge on each beat
        let measured = levels.map { $0.bpm } ?? 0
        tempo = approach(tempo, measured > 0 ? measured : look.bpm, dt: dt, tau: GLOW_TEMPO_BLEND_SECONDS)
        sparkTime += dt * tempo / 60 * Double(1 + 0.3 * beat * look.punch)

        var out = GlowUniforms()
        out.colorA = SIMD4(colorA, 0)
        out.colorB = SIMD4(colorB, 0)
        out.params = SIMD4(Float(presence), energy, beat * look.punch, Float(sparkTime.truncatingRemainder(dividingBy: 10_000)))
        return out
    }

    // The tap's levels, or nil when the simulated path should drive the glow: no
    // healthy tap, or Spotify has been "playing" for a while with no sound at all.
    // Silence is counted from the play start too, since a resumed tap reports none yet.
    private func realLevels(now: CFTimeInterval, spotifyPlaying: Bool) -> AudioLevels? {
        guard let levels = audioLevels() else { return nil }
        let silentFor = now - max(levels.lastSound, playStartedAt)
        return spotifyPlaying && silentFor > GLOW_TAP_SILENCE_FALLBACK ? nil : levels
    }

    // Without the audio tap, pulse at the genre's typical tempo instead
    private func simulatedBeat(_ now: CFTimeInterval) -> Float {
        let phase = (now * look.bpm / 60).truncatingRemainder(dividingBy: 1)
        return Float(exp(-phase * 60 / look.bpm / GLOW_BEAT_DECAY))
    }

    private func approach(_ value: Double, _ target: Double, dt: Double, tau: Double) -> Double {
        value + (target - value) * (1 - exp(-dt / tau))
    }
}
