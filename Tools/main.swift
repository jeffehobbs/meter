import Accelerate
import AVFoundation
import Foundation

// A checkable account of whether Meter does what it claims. Run from the
// project root with Tools/check.sh. Three questions:
//
//   1. Does every measure spend exactly the budget it was given?
//   2. Does the distribution actually move, and keep moving?
//   3. Does every patch make a sound, and does a full-budget measure stay
//      under the ceiling?

setvbuf(stdout, nil, _IONBF, 0)

var failures = 0
func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    let mark = passed ? "  ok " : "FAIL "
    if !passed { failures += 1 }
    print("\(mark)\(label)\(detail.isEmpty ? "" : "  — \(detail)")")
}

// MARK: - 1. Apportionment

print("\n── budget ─────────────────────────────────────────────")

do {
    var worst = 0
    for total in 1...200 {
        var rng = Rng(seed: UInt64(total) &* 7919)
        let weights = (0..<9).map { _ in rng.range(0, 1) }
        let parts = apportion(total: total, weights: weights)
        worst = max(worst, abs(parts.reduce(0, +) - total))
    }
    check("apportion always sums to the total", worst == 0, "worst error \(worst)")

    let zeroed = apportion(total: 12, weights: [0, 0, 1, 0])
    check("a lane with no share gets nothing", zeroed == [0, 0, 12, 0], "\(zeroed)")
}

// MARK: - 2. The machine over time

print("\n── composition ────────────────────────────────────────")

struct Run {
    var spentExact = 0
    var measures = 0
    var overCap = 0
    var offGrid = 0
    var duplicates = 0
    var maxDrift = 0.0
    var stepDrift = 0.0
    var decisions = 0
    var lanesUsed = Set<DrumVoice>()
    var flams = 0
    var histogram: [DrumVoice: Int] = [:]
}

func run(budget: Int, signature: Signature, measures: Int, motion: Double = 0.6) -> Run {
    let director = Director(seed: 0xBEEF &+ UInt64(budget))
    director.motion = motion
    let composer = Composer(seed: 0xCAFE &+ UInt64(budget))
    composer.signature = signature
    var result = Run()
    var first: [DrumVoice: Double] = [:]
    var last: [DrumVoice: Double] = [:]

    for i in 0..<measures {
        let tick = director.advance()
        let measure = composer.compose(index: i, budget: budget, tick: tick,
                                       enabled: Set(DrumVoice.allCases))
        result.measures += 1
        if measure.spent == budget { result.spentExact += 1 }
        var seen = Set<String>()
        for hit in measure.hits {
            if hit.tick < 0 || hit.tick >= signature.ticks { result.offGrid += 1 }
            if !seen.insert("\(hit.voice.rawValue)-\(hit.step)").inserted { result.duplicates += 1 }
            if hit.flam { result.flams += 1 }
            result.lanesUsed.insert(hit.voice)
            result.histogram[hit.voice, default: 0] += 1
        }
        for (voice, count) in measure.counts where count > signature.steps {
            _ = voice
            result.overCap += 1
        }
        result.decisions += tick.notes.count
        if i == 0 { first = tick.shares }
        defer { last = tick.shares }
        if i > 0 {
            result.stepDrift += DrumVoice.allCases.reduce(0.0) { sum, v in
                sum + abs((tick.shares[v] ?? 0) - (last[v] ?? 0))
            } / 2
            // Total variation distance from the opening distribution: how far
            // the director has actually walked.
            let drift = DrumVoice.allCases.reduce(0.0) { sum, v in
                sum + abs((tick.shares[v] ?? 0) - (first[v] ?? 0))
            } / 2
            result.maxDrift = max(result.maxDrift, drift)
        }
    }
    return result
}

for budget in [1, 4, 14, 32, 64] {
    let r = run(budget: budget, signature: .named("4/4"), measures: 240)
    let exact = Double(r.spentExact) / Double(r.measures)
    check("budget \(String(format: "%2d", budget)): every attack spent",
          exact > 0.999, String(format: "%.1f%% of measures exact", exact * 100))
    check("budget \(String(format: "%2d", budget)): nothing off the grid or doubled",
          r.offGrid == 0 && r.duplicates == 0 && r.overCap == 0,
          "offGrid \(r.offGrid) dupes \(r.duplicates) overCap \(r.overCap)")
}

for signature in Signature.all {
    let r = run(budget: 13, signature: signature, measures: 96)
    let exact = Double(r.spentExact) / Double(r.measures)
    check("\(signature.name) composes cleanly",
          exact > 0.999 && r.offGrid == 0 && r.duplicates == 0,
          String(format: "%.0f%% exact, %d lanes, %d flams", exact * 100,
                 r.lanesUsed.count, r.flams))
}

do {
    // Two fresh sessions should not open on the same bar. This is a real
    // regression rather than a hypothetical: for a while every launch played an
    // identical first three measures, because the lane placement streams were
    // seeded from constants and the opening distribution was fixed.
    func opening(_ seed: UInt64) -> String {
        let director = Director(seed: seed)
        let composer = Composer(seed: seed)
        composer.signature = .named("4/4")
        var text = ""
        for i in 0..<3 {
            let tick = director.advance()
            let measure = composer.compose(index: i, budget: 12, tick: tick,
                                           enabled: Set(DrumVoice.allCases))
            for hit in measure.hits.sorted(by: { ($0.voice.rawValue, $0.step) < ($1.voice.rawValue, $1.step) }) {
                text += "\(hit.voice.short)\(hit.step) "
            }
            text += "|"
        }
        return text
    }
    let first = opening(11), second = opening(12), third = opening(13)
    check("two sessions do not open on the same bar",
          first != second && second != third && first != third,
          "three seeds, three different openings")
    check("a session is reproducible from its seed", opening(11) == first,
          "same seed, same music")

    let r = run(budget: 18, signature: .named("4/4"), measures: 300, motion: 0.6)
    check("the distribution walks a long way from where it started",
          r.maxDrift > 0.35, String(format: "peak total variation %.2f", r.maxDrift))
    check("every lane gets used over five minutes",
          r.lanesUsed.count == DrumVoice.allCases.count,
          "\(r.lanesUsed.count) of \(DrumVoice.allCases.count)")

    let still = run(budget: 18, signature: .named("4/4"), measures: 300, motion: 0.0)
    let busy = Double(r.decisions) / Double(r.measures)
    let calm = Double(still.decisions) / Double(still.measures)
    check("at rest it decides less often",
          calm < busy * 0.75,
          String(format: "%.2f decisions per measure at rest vs %.2f in motion", calm, busy))
    let busyRate = r.stepDrift / Double(r.measures)
    let calmRate = still.stepDrift / Double(still.measures)
    check("at rest it moves more slowly",
          calmRate < busyRate * 0.7 && calmRate > 0.0005,
          String(format: "%.4f share moved per measure at rest vs %.4f in motion",
                 calmRate, busyRate))
}

// MARK: - 3. The rack

/// The pitch a patch leaves ringing, and how strongly.
///
/// A drum hit is a transient with a spread spectrum; a beep is one partial that
/// outlasts the transient. So this looks at the *tail* — everything after the
/// first sixty milliseconds — and asks how much of it is a single frequency.
/// Prominence is that partial's magnitude over the mean of the spectrum: a few
/// times over for a drum, tens or hundreds for a tone.
func tonality(_ trigger: Trigger) -> (hz: Double, prominence: Double, tail: Double) {
    // Its own rate rather than the global below it: top-level code in main.swift
    // runs in order, and this section is above where that one is declared.
    let sampleRate = 48_000.0
    let synth = DrumSynth()
    synth.prepare(sampleRate: sampleRate)
    synth.masterVolume = 1
    synth.triggers.push(trigger)
    let lanes = DrumVoice.allCases.count
    let stride = 1_024
    let buses = UnsafeMutablePointer<Float>.allocate(capacity: lanes * stride)
    defer { buses.deallocate() }

    let n = 16_384
    var signal = [Float](repeating: 0, count: n)
    var written = 0
    var lastLoud = 0
    while written < n {
        let frames = min(512, n - written)
        for lane in 0..<lanes {
            synth.render(lane: lane, frames: frames, into: buses + lane * stride)
        }
        for i in 0..<frames {
            var v: Float = 0
            for lane in 0..<lanes { v += buses[lane * stride + i] }
            signal[written + i] = v
            if abs(v) > 0.002 { lastLoud = written + i }
        }
        written += frames
    }

    // The tail only: a hit's attack is broadband by definition.
    let start = Int(0.06 * sampleRate)
    guard lastLoud > start + 2_048 else {
        return (0, 0, Double(lastLoud) / sampleRate)
    }
    let length = 8_192
    var tail = [Float](repeating: 0, count: length)
    for i in 0..<length where start + i < n { tail[i] = signal[start + i] }
    // Hann, so a partial between bins does not smear across the spectrum.
    var window = [Float](repeating: 0, count: length)
    vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
    vDSP_vmul(tail, 1, window, 1, &tail, 1, vDSP_Length(length))

    let log2n = vDSP_Length(log2(Double(length)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return (0, 0, Double(lastLoud) / sampleRate)
    }
    defer { vDSP_destroy_fftsetup(setup) }
    var real = [Float](repeating: 0, count: length / 2)
    var imaginary = [Float](repeating: 0, count: length / 2)
    var magnitudes = [Float](repeating: 0, count: length / 2)
    real.withUnsafeMutableBufferPointer { realPointer in
        imaginary.withUnsafeMutableBufferPointer { imagPointer in
            var split = DSPSplitComplex(realp: realPointer.baseAddress!,
                                        imagp: imagPointer.baseAddress!)
            tail.withUnsafeBufferPointer { input in
                input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: length / 2) {
                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(length / 2))
                }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(length / 2))
        }
    }

    var peak: Float = 0
    var peakBin = 0
    // Skip the lowest bins: a drum's fundamental is not what makes it a beep.
    for bin in 4..<(length / 2) where magnitudes[bin] > peak {
        peak = magnitudes[bin]
        peakBin = bin
    }
    let mean = magnitudes[4...].reduce(0, +) / Float(magnitudes.count - 4)
    let hz = Double(peakBin) * sampleRate / Double(length)
    return (hz, mean > 0 ? Double(peak / mean) : 0, Double(lastLoud) / sampleRate)
}

print("\n── pitch ──────────────────────────────────────────────")
print("  " + pad("patch", 10) + "  ringing at   prominence   tail")
for patch in Patch.bank {
    let lane = LaneSettings(patchName: patch.name)
    let result = tonality(Trigger(voice: .bass, lane: lane, velocity: 0.9))
    // A tone is a single partial, high, that outlasts the transient.
    let beepy = result.prominence > 60 && result.hz > 500 && result.tail > 0.18
    print("  " + pad(patch.name, 10)
          + String(format: "  %6.0f Hz  %10.0f×  %5.2fs%@",
                   result.hz, result.prominence, result.tail, beepy ? "   ← reads as a tone" : ""))
    check("\(patch.name) is a drum rather than a tone", !beepy,
          String(format: "%.0f Hz, %.0f× prominence, %.2fs", result.hz, result.prominence, result.tail))
}

print("\n── rack ───────────────────────────────────────────────")

let sampleRate = 48_000.0

func renderOne(_ trigger: Trigger, seconds: Double = 3.0) -> (peak: Float, rms: Float, tail: Double, dc: Float, bad: Bool) {
    let synth = DrumSynth()
    synth.prepare(sampleRate: sampleRate)
    synth.masterVolume = 1
    synth.triggers.push(trigger)
    let frames = 512
    let stride = 1_024
    var peak: Float = 0
    var sum: Double = 0
    var dcSum: Double = 0
    var count = 0
    var lastLoud = 0
    var bad = false
    let lanes = DrumVoice.allCases.count
    let buses = UnsafeMutablePointer<Float>.allocate(capacity: lanes * stride)
    defer { buses.deallocate() }
    let blocks = Int(seconds * sampleRate) / frames
    for b in 0..<blocks {
        // The kernel renders one mono bus per lane, independently; the spatial
        // stage is what mixes them, so measuring the rack alone means asking for
        // each lane and summing them here.
        for lane in 0..<lanes {
            synth.render(lane: lane, frames: frames, into: buses + lane * stride)
        }
        for i in 0..<frames {
            var v: Float = 0
            for lane in 0..<lanes { v += buses[lane * stride + i] }
            if !v.isFinite { bad = true; continue }
            let m = abs(v)
            if m > peak { peak = m }
            if m > 0.001 { lastLoud = b * frames + i }
            sum += Double(v) * Double(v)
            dcSum += Double(v)
            count += 1
        }
    }
    let rms = Float((sum / Double(max(1, count))).squareRoot())
    return (peak, rms, Double(lastLoud) / sampleRate, Float(dcSum / Double(max(1, count))), bad)
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
print("  " + pad("patch", 10) + "   peak      rms   tail s        dc")
for patch in Patch.bank {
    var lane = LaneSettings(patchName: patch.name)
    lane.pan = 0
    let hard = renderOne(Trigger(voice: .bass, lane: lane, velocity: 1.0))
    let soft = renderOne(Trigger(voice: .bass, lane: lane, velocity: 0.35))
    print("  " + pad(patch.name, 10)
          + String(format: " %6.3f  %7.4f  %6.3f  %+8.5f",
                   hard.peak, hard.rms, hard.tail, hard.dc))
    check("\(patch.name) makes a sound", hard.peak > 0.05 && !hard.bad,
          String(format: "peak %.3f", hard.peak))
    check("\(patch.name) is quieter when hit softer", soft.peak < hard.peak,
          String(format: "%.3f vs %.3f", soft.peak, hard.peak))
    check("\(patch.name) leaves no DC", abs(hard.dc) < 0.004,
          String(format: "%.5f", hard.dc))
    check("\(patch.name) ends", hard.tail < 2.9, String(format: "%.2fs", hard.tail))
}

// MARK: - 4. A full-budget measure through the whole chain

print("\n── mix ────────────────────────────────────────────────")

func mix(budget: Int, measures: Int) -> (peak: Float, rms: Float, clipped: Int) {
    let director = Director(seed: 42)
    director.motion = 0.7
    let composer = Composer(seed: 42)
    composer.signature = .named("4/4")
    var kit: [DrumVoice: LaneSettings] = [:]
    for v in DrumVoice.allCases { kit[v] = .default(for: v) }

    let output = AudioOutput(offline: true)
    output.synth.masterVolume = 0.85
    output.reverbMix = 14

    // Every hit fired at the tick it was composed for, rendered through the
    // room and the limiter — the actual output, not the voice bank.
    let bpm = 128.0
    let tickSeconds = 60.0 / bpm / Double(ticksPerQuarter)
    var peak: Float = 0
    var energy: Double = 0
    var samples = 0
    var clipped = 0
    for m in 0..<measures {
        let tick = director.advance()
        let measure = composer.compose(index: m, budget: budget, tick: tick,
                                       enabled: Set(DrumVoice.allCases))
        var previous = 0
        for hit in measure.hits {
            let gap = Double(hit.tick - previous) * tickSeconds
            previous = hit.tick
            if gap > 0 {
                output.renderOffline(seconds: gap) { l, r, n in
                    for i in 0..<n {
                        peak = max(peak, max(abs(l[i]), abs(r[i])))
                        energy += Double(l[i]) * Double(l[i])
                        samples += 1
                        if abs(l[i]) > 0.999 || abs(r[i]) > 0.999 { clipped += 1 }
                    }
                }
            }
            guard let lane = kit[hit.voice] else { continue }
            output.synth.triggers.push(Trigger(voice: hit.voice, lane: lane,
                                               velocity: hit.velocity))
        }
        let rest = Double(measure.signature.ticks - previous) * tickSeconds
        output.renderOffline(seconds: max(0.001, rest)) { l, r, n in
            for i in 0..<n {
                peak = max(peak, max(abs(l[i]), abs(r[i])))
                energy += Double(l[i]) * Double(l[i])
                samples += 1
                if abs(l[i]) > 0.999 || abs(r[i]) > 0.999 { clipped += 1 }
            }
        }
    }
    return (peak, Float((energy / Double(max(1, samples))).squareRoot()), clipped)
}

for budget in [6, 14, 48] {
    let m = mix(budget: budget, measures: 12)
    check("budget \(budget) is loud enough to be the output",
          m.peak > 0.3 && m.rms > 0.02,
          String(format: "peak %.3f, rms %.3f", m.peak, m.rms))
    check("budget \(budget) stays under the ceiling", m.peak < 1.0 && m.clipped == 0,
          String(format: "peak %.3f, %d clipped samples", m.peak, m.clipped))
}

print("\n\(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")\n")
exit(failures == 0 ? 0 : 1)
