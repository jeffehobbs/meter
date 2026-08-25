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

// MARK: - 2b. Moving between meters

// A meter change cannot be ramped: the bar is either sixteen steps long or it is
// twenty. So the question is not whether it is smooth but how much of the music
// survives it, and that is measurable. Retention here is the fraction of the
// figure — which lane, on which sixteenth of the shared head of the bar — that
// is the same either side of a bar line. Compare the value across a bar where
// the meter changed against the value across an ordinary bar and the ratio is
// the whole answer: 1.0 means the change is indistinguishable from any other
// bar, and `sections` is in here as the thing to beat.

print("\n── the vocabulary ─────────────────────────────────────")

do {
    var mismatched: [String] = []
    for signature in Signature.all {
        let rebuilt = Signature(groups: signature.groups, ticksPerStep: signature.ticksPerStep)
        if rebuilt.name != signature.name { mismatched.append("\(signature.name) → \(rebuilt.name)") }
        if rebuilt.steps != signature.steps { mismatched.append("\(signature.name) steps") }
    }
    check("a generated meter is named the way a written one is",
          mismatched.isEmpty, mismatched.isEmpty ? "all ten round-trip" : mismatched.joined(separator: ", "))

    // The pivot's whole claim: the bar keeps its length, so the quarter note
    // never moves. If that is not exact it is not a pivot.
    var pivots = 0
    var broken: [String] = []
    for signature in Signature.all {
        guard let partner = signature.subdivisionPartner else { continue }
        pivots += 1
        if partner.ticks != signature.ticks {
            broken.append("\(signature.name) \(signature.ticks) → \(partner.name) \(partner.ticks)")
        }
        if partner.subdivisionPartner != signature {
            broken.append("\(signature.name) does not come back")
        }
    }
    check("a subdivision pivot keeps the bar exactly as long",
          broken.isEmpty && pivots >= 4,
          broken.isEmpty ? "\(pivots) meters pivot, every one length-preserving" : broken.joined(separator: "; "))

    // The one-edit rule: an edit only ever touches the tail, so everything
    // before the last group is untouched. That is what makes a walk seamless.
    var offenders: [String] = []
    for signature in Signature.all {
        for neighbor in signature.neighbors where neighbor.ticksPerStep == signature.ticksPerStep {
            let head = signature.groups.dropLast()
            if !neighbor.groups.starts(with: head) {
                offenders.append("\(signature.name) → \(neighbor.name)")
            }
        }
    }
    check("every neighbor keeps the head of the bar", offenders.isEmpty,
          offenders.isEmpty ? "only the last group is ever edited" : offenders.joined(separator: ", "))

    // Remapping is by tick, and the tick is what has to survive.
    var worst = 0
    for from in Signature.all {
        for to in Signature.all {
            for step in 0..<from.steps {
                guard let mapped = to.step(matching: step, in: from) else { continue }
                worst = max(worst, abs(step * from.ticksPerStep - mapped * to.ticksPerStep))
            }
        }
    }
    check("remapping a figure moves it less than half a step",
          worst <= Signature.triple / 2, "worst \(worst) ticks of \(Signature.triple)")
}

print("\n── the seam ───────────────────────────────────────────")

struct MeterBar {
    var signature: Signature
    var measure: Measure
    var asked: Int
    var changed: Bool
}

/// One host's worth of bars: the director, the composer and the meter arc wired
/// together the way `FlowHost` and `MeterEngine` wire them, including the order —
/// the arc decides after the bar it is looking at has been composed, so a change
/// always lands on the next downbeat.
func runMotion(_ motion: MeterMotion, bars: Int, seed: UInt64, budget: Int = 14) -> [MeterBar] {
    let director = Director(seed: seed)
    director.motion = 0.5
    let composer = Composer(seed: seed)
    // Off, so this measures placement rather than the scatter on top of it.
    composer.humanize = 0
    composer.swing = 0
    composer.rotates = motion.rotatesLanes
    let arc = MeterArc(seed: seed)
    arc.motion = motion
    var signature = Signature.named("4/4")
    composer.signature = signature
    arc.reanchor(signature)

    let home = Double(Signature.named("4/4").ticks)
    var out: [MeterBar] = []
    for i in 0..<bars {
        let tick = director.advance()
        let asked = motion.holdsDensity
            ? max(1, Int((Double(budget) * Double(signature.ticks) / home).rounded()))
            : budget
        let measure = composer.compose(index: i, budget: asked, tick: tick,
                                       enabled: Set(DrumVoice.allCases))
        var changed = false
        // `quiet: true` on purpose: the gate is what decides *when* a change is
        // allowed, and this is measuring what happens *when* one lands.
        let decision = arc.advance(current: signature, quiet: true)
        if let target = decision.signature, target != signature {
            let old = signature
            signature = target
            composer.signature = target
            if decision.keepsFigure {
                composer.remap(from: old, to: target)
            } else {
                composer.reset()
            }
            changed = true
        }
        out.append(MeterBar(signature: measure.signature, measure: measure,
                            asked: asked, changed: changed))
    }
    return out
}

/// Which lane on which sixteenth, over the part of the bar the two share.
func figure(_ bar: MeterBar, limit: Int, lanes: Set<DrumVoice>? = nil) -> Set<String> {
    var out = Set<String>()
    for hit in bar.measure.hits {
        if let lanes, !lanes.contains(hit.voice) { continue }
        let tick = hit.step * bar.signature.ticksPerStep
        guard tick < limit else { continue }
        out.insert("\(hit.voice.rawValue)@\(tick / Signature.duple)")
    }
    return out
}

func retention(_ a: MeterBar, _ b: MeterBar, lanes: Set<DrumVoice>? = nil) -> Double {
    let limit = min(a.signature.ticks, b.signature.ticks)
    let x = figure(a, limit: limit, lanes: lanes)
    let y = figure(b, limit: limit, lanes: lanes)
    let union = x.union(y).count
    return union == 0 ? 1 : Double(x.intersection(y).count) / Double(union)
}

struct Seam {
    var changes = 0
    var atSeam = 0.0
    var ordinary = 0.0
    var densityJump = 0.0
    var offGrid = 0
    var short = 0
    var meters = Set<String>()

    var seamMean: Double { changes == 0 ? 0 : atSeam / Double(changes) }
    var ordinaryMean: Double { ordinary }
    /// 1.0 means a meter change looks like any other bar line.
    var ratio: Double { ordinaryMean == 0 ? 0 : seamMean / ordinaryMean }
}

func seam(_ motion: MeterMotion, bars: Int = 1_400, seed: UInt64 = 0x5EED) -> Seam {
    let run = runMotion(motion, bars: bars, seed: seed)
    var result = Seam()
    var ordinaryTotal = 0.0
    var ordinaryCount = 0
    let home = Double(Signature.named("4/4").ticks)
    for bar in run {
        result.meters.insert(bar.signature.name)
        if bar.measure.spent != bar.asked { result.short += 1 }
        for hit in bar.measure.hits where hit.tick < 0 || hit.tick >= bar.signature.ticks {
            _ = hit
            result.offGrid += 1
        }
    }
    for i in 0..<(run.count - 1) {
        let value = retention(run[i], run[i + 1])
        if run[i].changed {
            result.changes += 1
            result.atSeam += value
            // Attacks per bar-length-of-four-four, either side.
            let before = Double(run[i].measure.spent) * home / Double(run[i].signature.ticks)
            let after = Double(run[i + 1].measure.spent) * home / Double(run[i + 1].signature.ticks)
            result.densityJump += abs(after - before) / max(1, before)
        } else {
            ordinaryTotal += value
            ordinaryCount += 1
        }
    }
    result.ordinary = ordinaryCount == 0 ? 0 : ordinaryTotal / Double(ordinaryCount)
    if result.changes > 0 { result.densityJump /= Double(result.changes) }
    return result
}

print("  " + pad("motion", 10) + " changes   at seam   ordinary    ratio   density    meters")
var seams: [MeterMotion: Seam] = [:]
for motion in MeterMotion.allCases {
    let s = seam(motion)
    seams[motion] = s
    print("  " + pad(motion.label, 10)
          + String(format: " %7d   %7.3f   %8.3f   %6.2f   %+6.1f%%   %7d",
                   s.changes, s.seamMean, s.ordinaryMean, s.ratio,
                   s.densityJump * 100, s.meters.count))
}

do {
    // Every motion, including the ones inventing meters nobody wrote down, has
    // to keep the promise the whole program is built on.
    for motion in MeterMotion.allCases {
        let s = seams[motion]!
        check("\(motion.label): still spends every attack, on the grid",
              s.short == 0 && s.offGrid == 0,
              "\(s.short) short, \(s.offGrid) off grid")
    }

    let sections = seams[.sections]!
    for motion in [MeterMotion.pivot, .walk, .elide] {
        let s = seams[motion]!
        check("\(motion.label) keeps more of the figure than sections does",
              s.changes > 0 && s.seamMean > sections.seamMean * 1.5,
              String(format: "%.3f vs %.3f at the seam", s.seamMean, sections.seamMean))
    }

    // The pivot's bar never changes length, so holding the density is a no-op
    // for it — which is the proof that it is the gentle one.
    check("a pivot needs no density correction at all",
          seams[.pivot]!.densityJump < 0.02,
          String(format: "%.2f%% density change across a pivot", seams[.pivot]!.densityJump * 100))
    check("holding the density is doing something",
          seams[.walk]!.densityJump < sections.densityJump * 0.6,
          String(format: "walk %.1f%% vs sections %.1f%%",
                 seams[.walk]!.densityJump * 100, sections.densityJump * 100))

    // A walk should get somewhere. One that only ever plays four is not a walk.
    check("a walk visits more meters than sections picks from",
          seams[.walk]!.meters.count >= 6, "\(seams[.walk]!.meters.count) meters over 1,400 bars")
    check("nothing but rotate and fixed leaves the bar alone",
          seams[.fixed]!.meters.count == 1 && seams[.rotate]!.meters.count == 1,
          "fixed \(seams[.fixed]!.meters.count), rotate \(seams[.rotate]!.meters.count)")

    // Rotation needs its own two measurements, because position retention is the
    // wrong question to ask of it. A figure slid one sixteenth along has almost
    // no positions in common with where it was, and that is the feature. So:
    //
    //   * *where* — position retention, which rotation should collapse.
    //   * *what*  — the multiset of gaps between a lane's hits, which is
    //     invariant under sliding, and which rotation should therefore leave
    //     roughly where holding still leaves it.
    //
    // The pair is the whole claim: the same figure, somewhere else. Either alone
    // is satisfied by a randomizer.
    let low: Set<DrumVoice> = [.bass, .snare]
    let upper = Set(DrumVoice.allCases).subtracting(low)

    /// A lane's figure as the cyclic gaps between its hits — its shape, with its
    /// position thrown away.
    func gaps(_ bar: MeterBar, lane: DrumVoice) -> [Int] {
        let steps = bar.measure.hits.filter { $0.voice == lane }.map(\.step).sorted()
        guard steps.count >= 2 else { return [] }
        let span = bar.signature.steps
        return steps.indices.map { i in
            ((steps[(i + 1) % steps.count] - steps[i]) % span + span) % span
        }.sorted()
    }

    func shared(_ a: [Int], _ b: [Int]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1 : 0 }
        var counts: [Int: Int] = [:]
        for x in a { counts[x, default: 0] += 1 }
        var matched = 0
        for x in b where (counts[x] ?? 0) > 0 {
            counts[x]! -= 1
            matched += 1
        }
        return Double(2 * matched) / Double(a.count + b.count)
    }

    func phasing(_ motion: MeterMotion, lanes: Set<DrumVoice>) -> (where_: Double, what: Double) {
        let run = runMotion(motion, bars: 400, seed: 0x0A5E)
        var position = 0.0
        var shape = 0.0
        var shapeCount = 0
        for i in 0..<(run.count - 1) {
            position += retention(run[i], run[i + 1], lanes: lanes)
            for lane in lanes {
                let before = gaps(run[i], lane: lane), after = gaps(run[i + 1], lane: lane)
                guard !before.isEmpty, !after.isEmpty else { continue }
                shape += shared(before, after)
                shapeCount += 1
            }
        }
        return (position / Double(run.count - 1),
                shapeCount == 0 ? 0 : shape / Double(shapeCount))
    }

    let rotatedUpper = phasing(.rotate, lanes: upper)
    let rotatedLow = phasing(.rotate, lanes: low)
    let stillUpper = phasing(.fixed, lanes: upper)
    print(String(format: "\n  %@  where    what", pad("", 10)))
    print(String(format: "  %@%7.3f %7.3f", pad("upper kit", 10), rotatedUpper.where_, rotatedUpper.what))
    print(String(format: "  %@%7.3f %7.3f", pad("low end", 10), rotatedLow.where_, rotatedLow.what))
    print(String(format: "  %@%7.3f %7.3f", pad("fixed", 10), stillUpper.where_, stillUpper.what))

    check("rotation moves the upper kit somewhere else",
          rotatedUpper.where_ < stillUpper.where_ * 0.6,
          String(format: "%.3f of positions kept, vs %.3f held still",
                 rotatedUpper.where_, stillUpper.where_))
    check("and it is the same figure when it gets there",
          rotatedUpper.what > stillUpper.what * 0.8,
          String(format: "%.3f of the shape kept, vs %.3f held still",
                 rotatedUpper.what, stillUpper.what))
    check("rotation leaves the bass and snare where they are",
          rotatedLow.where_ > rotatedUpper.where_ * 1.5,
          String(format: "low end keeps %.3f, upper kit %.3f",
                 rotatedLow.where_, rotatedUpper.where_))
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

// And the same thing through a moving bar. The arithmetic above is all at
// sixteen steps of twenty-four ticks; a walk generates meters nobody wrote down
// and a pivot changes how long a step *is*, so this renders one actually through
// the room and the limiter rather than trusting that it would.
do {
    /// Bars that a walk produced, rendered end to end at a fixed tempo. Silence
    /// would mean the tick arithmetic came apart somewhere a bar length changed;
    /// a gap would mean a bar was rendered short.
    func mixWalk(_ motion: MeterMotion) -> (peak: Float, rms: Float, clipped: Int, seconds: Double, meters: Int) {
        let run = runMotion(motion, bars: 170, seed: 0x11CE)
        var kit: [DrumVoice: LaneSettings] = [:]
        for v in DrumVoice.allCases { kit[v] = .default(for: v) }
        let output = AudioOutput(offline: true)
        output.synth.masterVolume = 0.85
        output.reverbMix = 14

        let tickSeconds = 60.0 / 128.0 / Double(ticksPerQuarter)
        var peak: Float = 0
        var energy: Double = 0
        var samples = 0
        var clipped = 0
        var seconds = 0.0
        var meters = Set<String>()

        func take(_ length: Double) {
            guard length > 0 else { return }
            seconds += length
            output.renderOffline(seconds: length) { l, r, n in
                for i in 0..<n {
                    peak = max(peak, max(abs(l[i]), abs(r[i])))
                    energy += Double(l[i]) * Double(l[i])
                    samples += 1
                    if abs(l[i]) > 0.999 || abs(r[i]) > 0.999 { clipped += 1 }
                }
            }
        }

        for bar in run {
            meters.insert(bar.signature.name)
            var previous = 0
            for hit in bar.measure.hits {
                take(Double(hit.tick - previous) * tickSeconds)
                previous = hit.tick
                guard let lane = kit[hit.voice] else { continue }
                output.synth.triggers.push(Trigger(voice: hit.voice, lane: lane,
                                                   velocity: hit.velocity))
            }
            take(max(0.001, Double(bar.signature.ticks - previous) * tickSeconds))
        }
        return (peak, Float((energy / Double(max(1, samples))).squareRoot()),
                clipped, seconds, meters.count)
    }

    for motion in [MeterMotion.pivot, .walk, .elide, .rotate] {
        let m = mixWalk(motion)
        check("\(motion.label) renders through the room without clipping",
              m.peak > 0.3 && m.rms > 0.02 && m.peak < 1.0 && m.clipped == 0,
              String(format: "peak %.3f, rms %.3f, %d clipped, %.1fs of %d meters",
                     m.peak, m.rms, m.clipped, m.seconds, m.meters))
    }
}

print("\n── the clock ──────────────────────────────────────────")

// The one real-time section. Everything above is rendered offline, but a
// tempo change is a scheduling question and there is no offline way to ask it:
// the bug this exists to catch is a tempo change that re-arms the timer from
// *now* and so displaces the grid by whatever was left of the tick in
// progress. Once every few seconds, which is what following a pulse produces,
// that is the beat jostling.
//
// Steps arrive on the main queue, so the figures carry a couple of
// milliseconds of run-loop jitter; the tolerances below are set well outside
// it and the assertions are about drift and arrival rather than about any one
// interval.
do {
    let synth = DrumSynth()
    synth.prepare(sampleRate: 48_000)
    let transport = Transport(synth: synth, midi: MIDIOut(),
                              director: Director(), composer: Composer())
    var stamps: [Double] = []
    let t0 = Date()
    transport.onStep = { _, _ in stamps.append(Date().timeIntervalSince(t0)) }
    transport.set(bpm: 100, glide: false)
    transport.set(budget: 8)
    transport.set(route: .synth)
    transport.start()

    Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in transport.set(bpm: 130) }
    RunLoop.main.run(until: Date().addingTimeInterval(12))
    transport.stop()

    func tempo(between start: Double, and end: Double) -> Double {
        let window = stamps.filter { $0 >= start && $0 <= end }
        guard let first = window.first, let last = window.last, window.count > 2 else { return 0 }
        // Four sixteenths to the beat.
        return 60 * Double(window.count - 1) / ((last - first) * 4)
    }

    let steady = tempo(between: 0.5, and: 2.9)
    check("the clock holds the tempo it was given",
          abs(steady - 100) < 0.6, String(format: "%.2f bpm over 2.4s, asked for 100", steady))

    let arrived = tempo(between: 8, and: 11.9)
    check("a tempo change arrives where it was sent",
          abs(arrived - 130) < 1.0, String(format: "%.2f bpm, asked for 130", arrived))

    // The glide itself: every sixteenth through the change, and none of them
    // out of line with its neighbours. A grid that has been displaced shows up
    // here as one interval far longer than the two either side of it.
    var worst = 0.0
    var worstAt = 0.0
    for i in 2..<stamps.count {
        let before = stamps[i - 1] - stamps[i - 2]
        let after = stamps[i] - stamps[i - 1]
        let jump = abs(after - before) / before
        if jump > worst { worst = jump; worstAt = stamps[i] }
    }
    check("no step is displaced by the change",
          worst < 0.09, String(format: "worst neighbouring sixteenths differ by %.1f%% (t=%.2fs)",
                               worst * 100, worstAt))

    // And it is a glide rather than a jump: partway through, the tempo has to
    // be somewhere between the two.
    let midway = tempo(between: 3.4, and: 4.0)
    check("the tempo glides rather than jumps",
          midway > 103 && midway < 127, String(format: "%.2f bpm half a second in", midway))
}

print("\n\(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")\n")
exit(failures == 0 ? 0 : 1)
