import Foundation
func check(_ c: Bool, _ m: String) { print(c ? "PASS" : "FAIL", m); if !c { exit(1) } }
let sr: Float = 48000, block = 512
// Synth: kick (60 Hz, 120 ms decay) every 0.5 s over quiet hi-hat noise; stereo interleaved
func render(seconds: Float, bpm: Float, kick: Bool, gain: Float) -> [Float] {
    let n = Int(seconds * sr); var out = [Float](repeating: 0, count: n * 2)
    let period = Int(60 / bpm * sr)
    for i in 0..<n {
        let t = Float(i % period) / sr
        var s = kick ? sin(2 * .pi * 60 * t) * exp(-t / 0.12) * 0.6 : 0
        s += (Float.random(in: -1...1)) * 0.03
        out[i * 2] = s * gain; out[i * 2 + 1] = s * gain
    }
    return out
}
func run(_ samples: [Float]) -> (beats: [Double], analyzer: AudioAnalyzer) {
    let a = AudioAnalyzer(sampleRate: sr); var beats: [Double] = []; var last = -Double.infinity
    samples.withUnsafeBufferPointer { buf in
        var f = 0
        while f * 2 < buf.count {
            let end = min(buf.count, (f + block) * 2)
            let t = Double(f) / Double(sr)
            a.process(UnsafeBufferPointer(rebasing: buf[(f * 2)..<end]), channels: 2, at: t)
            if a.levels.lastBeat != last { last = a.levels.lastBeat; beats.append(last) }
            f += block
        }
    }
    return (beats, a)
}
let (beats, a) = run(render(seconds: 10, bpm: 120, kick: true, gain: 1))
let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }
let median = intervals.sorted()[intervals.count / 2]
print("beats", beats.count, "median interval", median)
check(beats.count >= 17 && beats.count <= 21, "detects ~20 kicks in 10 s at 120 BPM")
check(abs(median - 0.5) < 0.03, "beat spacing matches tempo")
check(a.levels.level > 0.05, "level rises with music")
let (quiet, q) = run(render(seconds: 5, bpm: 120, kick: false, gain: 1))
check(quiet.count <= 1, "no beats from hi-hat noise alone")
check(q.levels.lastSound > 4, "noise counts as sound")
let (_, s) = run([Float](repeating: 0, count: Int(sr) * 2))
check(s.levels.level < 0.0001 && s.levels.lastSound == -.infinity, "silence stays silent")
let (soft, _) = run(render(seconds: 10, bpm: 120, kick: true, gain: 0.15))
check(soft.count >= 15, "still finds beats at low volume (\(soft.count))")
let (fast, _) = run(render(seconds: 10, bpm: 174, kick: true, gain: 1))
check(fast.count >= 25, "keeps up with 174 BPM (\(fast.count))")
func tempo(_ bpm: Float) -> Double { run(render(seconds: 10, bpm: bpm, kick: true, gain: 1)).analyzer.levels.bpm }
for target in [90, 120, 128, 174] as [Float] {
    let est = tempo(target)
    check(abs(est - Double(target)) < 3, "tempo \(Int(target)) BPM estimated as \(String(format: "%.1f", est))")
}
check(tempo(50) > 95 && tempo(50) < 105, "50 BPM folds into range as ~100")
check(q.levels.bpm == 0, "no tempo from noise alone")
