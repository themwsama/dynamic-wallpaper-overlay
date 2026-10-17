// Turns raw audio samples into what the glow needs: smoothed loudness, bass
// energy, beat onsets (bass jumping well above its recent average), and a
// tempo estimate from the spacing of recent beats.
// Pure and allocation-free so it can run on the real-time audio thread.
import Foundation

nonisolated let BASS_CUTOFF_HZ: Float = 150
nonisolated let LEVEL_ATTACK_SECONDS: Float = 0.02
nonisolated let LEVEL_RELEASE_SECONDS: Float = 0.25
nonisolated let BASS_AVERAGE_SECONDS: Float = 1.0
nonisolated let BEAT_RATIO: Float = 1.45          // bass must exceed its average by this factor
nonisolated let BEAT_FLOOR: Float = 0.02          // ...and be at least this loud
nonisolated let BEAT_REFRACTORY: CFTimeInterval = 0.28  // ignore re-triggers faster than ~214 BPM
nonisolated let SILENCE_FLOOR: Float = 0.002
nonisolated let TEMPO_BEAT_HISTORY = 9                  // beats kept; tempo from the median of their gaps
nonisolated let TEMPO_MIN_BPM: Double = 60              // estimates outside this range are halved/doubled
nonisolated let TEMPO_MAX_BPM: Double = 180
nonisolated let TEMPO_MAX_GAP: CFTimeInterval = 2       // a longer silence or beatless stretch forgets the tempo

// Nonisolated: written on the audio IO queue, read by the render loop
nonisolated struct AudioLevels: Sendable {
    var level: Float = 0                 // smoothed loudness, 0..~1
    var bass: Float = 0                  // smoothed bass loudness
    var lastBeat: CFTimeInterval = -.infinity   // CACurrentMediaTime of the last beat
    var lastSound: CFTimeInterval = -.infinity  // last time audio was above silence
    var bpm: Double = 0                  // estimated tempo; 0 until a few beats are heard
}

// Nonisolated: `process` runs on Core Audio's IO queue. Deliberately not Sendable:
// each instance belongs to one IO block and is only used on that block's queue.
nonisolated final class AudioAnalyzer {
    private let sampleRate: Float
    private let lowpassAlpha: Float
    private var lowpass: Float = 0
    private var bassAverage: Float = 0
    // Preallocated so the audio thread never allocates
    private var beatTimes = [CFTimeInterval](repeating: 0, count: TEMPO_BEAT_HISTORY)
    private var beatCount = 0
    private var gapScratch = [CFTimeInterval](repeating: 0, count: TEMPO_BEAT_HISTORY - 1)
    private(set) var levels = AudioLevels()

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        lowpassAlpha = 1 - exp(-2 * .pi * BASS_CUTOFF_HZ / sampleRate)
    }

    // Interleaved float samples; `time` is when this buffer plays
    func process(_ samples: UnsafeBufferPointer<Float>, channels: Int, at time: CFTimeInterval) {
        let frames = samples.count / max(1, channels)
        guard frames > 0 else { return }
        var sumSquares: Float = 0
        var bassSquares: Float = 0
        for frame in 0..<frames {
            var mono: Float = 0
            for channel in 0..<channels { mono += samples[frame * channels + channel] }
            mono /= Float(channels)
            lowpass += lowpassAlpha * (mono - lowpass)
            sumSquares += mono * mono
            bassSquares += lowpass * lowpass
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        let bass = (bassSquares / Float(frames)).squareRoot()
        let dt = Float(frames) / sampleRate

        // A long gap is a pause, a break or a new song: the old tempo must not carry over
        if time - levels.lastBeat > TEMPO_MAX_GAP { forgetTempo() }

        let levelTau = rms > levels.level ? LEVEL_ATTACK_SECONDS : LEVEL_RELEASE_SECONDS
        levels.level += (rms - levels.level) * (1 - exp(-dt / levelTau))
        let bassTau = bass > levels.bass ? LEVEL_ATTACK_SECONDS : LEVEL_RELEASE_SECONDS
        levels.bass += (bass - levels.bass) * (1 - exp(-dt / bassTau))

        if bass > BEAT_FLOOR, bass > bassAverage * BEAT_RATIO, time - levels.lastBeat > BEAT_REFRACTORY {
            recordBeat(at: time)
            levels.lastBeat = time
        }
        // Average updates after the check so a beat doesn't raise its own bar
        bassAverage += (bass - bassAverage) * (1 - exp(-dt / BASS_AVERAGE_SECONDS))
        if rms > SILENCE_FLOOR { levels.lastSound = time }
    }

    private func forgetTempo() {
        beatCount = 0
        levels.bpm = 0
    }

    private func recordBeat(at time: CFTimeInterval) {
        if beatCount == TEMPO_BEAT_HISTORY {
            for i in 1..<TEMPO_BEAT_HISTORY { beatTimes[i - 1] = beatTimes[i] }
            beatCount -= 1
        }
        beatTimes[beatCount] = time
        beatCount += 1
        guard beatCount >= 4 else { return }
        levels.bpm = foldTempo(60 / medianGap())
    }

    // Median is robust to a missed or extra beat; insertion sort on the scratch buffer
    private func medianGap() -> CFTimeInterval {
        let gaps = beatCount - 1
        for i in 0..<gaps {
            let gap = beatTimes[i + 1] - beatTimes[i]
            var j = i
            while j > 0 && gapScratch[j - 1] > gap {
                gapScratch[j] = gapScratch[j - 1]
                j -= 1
            }
            gapScratch[j] = gap
        }
        return gapScratch[gaps / 2]
    }

    // Detected kicks are often on half or double time; keep the estimate in a musical range
    private func foldTempo(_ bpm: Double) -> Double {
        var folded = bpm
        while folded < TEMPO_MIN_BPM { folded *= 2 }
        while folded > TEMPO_MAX_BPM { folded /= 2 }
        return folded
    }
}
