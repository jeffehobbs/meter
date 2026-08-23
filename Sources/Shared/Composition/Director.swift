import Foundation

/// The four macros a lane exposes, as an addressable thing so the director can
/// drift them.
enum Macro: String, Codable, CaseIterable {
    case tone, fold, grit, decay
    /// Where the lane sits in the room. Drifting it is the slowest gesture in
    /// the app and, on headphones, the most effective: the hats are somewhere
    /// slightly different every time you notice them.
    case pan
}

/// What the director decided this measure. The engine applies it: shares go to
/// the composer, macro moves and repatches go to the kit.
struct DirectorTick {
    var shares: [DrumVoice: Double] = [:]
    var macroMoves: [(voice: DrumVoice, macro: Macro, value: Double)] = []
    var repatches: [(voice: DrumVoice, patch: String)] = []
    /// Lanes whose placement should be re-rolled from scratch rather than
    /// inherited from last measure.
    var reseed: Set<DrumVoice> = []
    /// Placement bias: 0 pushes hits onto strong beats, 1 onto the spaces
    /// between them.
    var temperature: Double = 0.35
    /// Human-readable trace of anything that fired, for the interface.
    var notes: [String] = []
}

/// The budget's politics.
///
/// A measure has a fixed number of attacks in it — the user sets that, and the
/// director never touches it. What the director does is decide who gets them,
/// and keep changing its mind. Because the total is fixed, every decision is
/// zero-sum: the only way for the bright lanes to get busier is for something
/// else to go quiet, which is why the machine's output stays legible at any
/// density instead of just filling up.
///
/// Two rules are inherited from Thrum's Flow, and they are the difference
/// between this and a randomizer:
///
///   * **Nothing is ever set, only ramped.** A share that jumps between two
///     measures is an event the ear catches and resents. The same move spread
///     over four to ten measures on a smootherstep is just the music going
///     somewhere.
///   * **Every gesture runs on its own prime clock.** Transfers every five
///     measures, tilts every seven, dropouts every thirteen, repatching every
///     twenty-nine. Nothing lines up, so nothing is ever a section.
final class Director {
    /// How often and how far the director moves, 0 … 1.
    var motion: Double = 0.5
    /// How evenly the budget is spread. Low concentrates it on a few lanes;
    /// high hands everyone a piece.
    var spread: Double = 0.5
    /// Whether the director may also change what the lanes *sound* like.
    var evolvePatches: Bool = true
    /// Lanes currently in play. A muted lane's share is redistributed rather
    /// than lost — the budget is always spent.
    var enabled: Set<DrumVoice> = Set(DrumVoice.allCases)

    private var weight: [DrumVoice: Double] = [:]
    private var ramps: [DrumVoice: Ramp] = [:]
    private var macroRamps: [String: (voice: DrumVoice, macro: Macro, ramp: Ramp)] = [:]
    private var temperature: Double = 0.35
    private var temperatureRamp: Ramp?
    private var resting: Set<DrumVoice> = []

    private enum Gesture: String, CaseIterable {
        case transfer, tilt, spotlight, rest, churn, shift, repatch, timbre

        /// Prime periods in measures, so no two gestures ever coincide twice.
        var period: Int {
            switch self {
            case .timbre:    return 3
            case .transfer:  return 5
            case .tilt:      return 7
            case .spotlight: return 11
            case .rest:      return 13
            case .churn:     return 17
            case .shift:     return 19
            case .repatch:   return 29
            }
        }
    }

    private var due: [Gesture: Double] = [:]
    private var pending: [(at: Double, run: (inout DirectorTick) -> Void)] = []
    private var clock: Double = 0
    private var rng: Rng

    /// Starting distribution: a kit that already sounds like a kit, so the
    /// first measure is music and the drift has somewhere to drift from.
    private static let seedWeights: [DrumVoice: Double] = [
        .bass: 0.22, .snare: 0.15, .rim: 0.06,
        .lowTom: 0.05, .midTom: 0.06, .highTom: 0.04,
        .closedHat: 0.24, .openHat: 0.09, .cymbal: 0.04,
    ]

    init(seed: UInt64 = Rng.freshSeed()) {
        rng = Rng(seed: seed)
        // The seed kit, leaned on a little differently each session. The shape
        // is the same — it is still a kit rather than nine random lanes — but
        // the machine no longer opens on exactly the same distribution every
        // time, which it did, audibly, for the first several measures.
        //
        // In `allCases` order, and that matters: `mapValues` walks the dictionary
        // in hash order, and Swift randomizes hash seeds per process. Drawing
        // the jitter that way handed each lane a different number on every run,
        // so the same seed produced different music — which is the one thing a
        // seed is for. The reproducibility check in Tools/ caught it.
        var jittered: [DrumVoice: Double] = [:]
        for voice in DrumVoice.allCases {
            let base = Self.seedWeights[voice] ?? 0.05
            jittered[voice] = min(0.45, max(0.01, base * rng.range(0.6, 1.5)))
        }
        weight = jittered
        // Stagger the first firing of each gesture, so measure one is not a
        // committee meeting.
        for g in Gesture.allCases {
            due[g] = Double(1 + rng.int(g.period))
        }
    }

    // MARK: - Shares

    /// Effective share per enabled lane, normalized to 1. `spread` bends the
    /// raw weights before normalizing: the same weights can read as "one lane
    /// carries this" or "everybody plays a little".
    private func shares() -> [DrumVoice: Double] {
        let gamma = 2.2 - spread * 1.9
        var bent: [DrumVoice: Double] = [:]
        var total = 0.0
        for v in DrumVoice.allCases where enabled.contains(v) {
            let w = max(0, weight[v] ?? 0)
            let b = pow(w, gamma)
            bent[v] = b
            total += b
        }
        guard total > 0 else {
            let even = 1.0 / Double(max(1, enabled.count))
            return Dictionary(uniqueKeysWithValues: enabled.map { ($0, even) })
        }
        return bent.mapValues { $0 / total }
    }

    // MARK: - Advancing

    /// Advance one measure. Resolves every open ramp first, then lets whatever
    /// is due fire — in that order, so a gesture always acts on current values.
    func advance() -> DirectorTick {
        clock += 1
        var tick = DirectorTick()

        for (voice, ramp) in ramps {
            weight[voice] = clamp(ramp.value(at: clock))
            if ramp.done(at: clock) { ramps[voice] = nil }
        }
        for (key, entry) in macroRamps {
            tick.macroMoves.append((entry.voice, entry.macro, entry.ramp.value(at: clock)))
            if entry.ramp.done(at: clock) { macroRamps[key] = nil }
        }
        if let r = temperatureRamp {
            temperature = r.value(at: clock)
            if r.done(at: clock) { temperatureRamp = nil }
        }

        // Anything scheduled for now — the second half of a spotlight, the end
        // of a dropout.
        let ripe = pending.filter { $0.at <= clock }
        pending.removeAll { $0.at <= clock }
        for item in ripe { item.run(&tick) }

        for gesture in Gesture.allCases {
            guard let at = due[gesture], clock >= at else { continue }
            perform(gesture, into: &tick)
            due[gesture] = clock + nextInterval(for: gesture)
        }

        tick.shares = shares()
        tick.temperature = temperature
        return tick
    }

    /// Motion stretches or compresses every clock. At rest the machine still
    /// moves, just slowly; wide open it is restless without ever being random,
    /// because the periods stay in the same prime relationships.
    private func nextInterval(for gesture: Gesture) -> Double {
        let scale = 1.7 - motion * 1.1              // 1.7 … 0.6
        let base = Double(gesture.period) * scale
        return max(2, base + rng.range(-1, 1))
    }

    private func rampLength() -> Double {
        // Long ramps when the director is calm, short when it is busy — but
        // never instant, which is the whole point.
        let calm = 1 - motion
        return rng.range(2 + calm * 5, 5 + calm * 8)
    }

    private func clamp(_ w: Double) -> Double { min(0.45, max(0.004, w)) }

    private func open(_ voice: DrumVoice, to target: Double, over measures: Double) {
        let from = weight[voice] ?? 0.05
        ramps[voice] = Ramp(from: from, to: clamp(target), start: clock, duration: max(1, measures))
    }

    private func after(_ delay: Double, _ run: @escaping (inout DirectorTick) -> Void) {
        pending.append((at: clock + max(1, delay), run: run))
    }

    private var playable: [DrumVoice] {
        DrumVoice.allCases.filter { enabled.contains($0) && !resting.contains($0) }
    }

    // MARK: - The gestures

    private func perform(_ gesture: Gesture, into tick: inout DirectorTick) {
        switch gesture {
        case .transfer:  transfer(&tick)
        case .tilt:      tilt(&tick)
        case .spotlight: spotlight(&tick)
        case .rest:      rest(&tick)
        case .churn:     churn(&tick)
        case .shift:     shift(&tick)
        case .repatch:   repatch(&tick)
        case .timbre:    timbre(&tick)
        }
    }

    /// Move a slice of one lane's budget to another. The donor is picked in
    /// proportion to what it holds and the recipient in inverse proportion, so
    /// the flow is usually from the busy lanes to the neglected ones — which is
    /// what stops the machine from converging on a favorite.
    private func transfer(_ tick: inout DirectorTick) {
        let lanes = playable
        guard lanes.count >= 2 else { return }
        let held = lanes.map { max(0.001, weight[$0] ?? 0) }
        guard let donor = rng.pick(lanes, weights: held) else { return }
        let others = lanes.filter { $0 != donor }
        let hunger = others.map { 1.0 / max(0.01, weight[$0] ?? 0.01) }
        guard let recipient = rng.pick(others, weights: hunger) else { return }

        let slice = (weight[donor] ?? 0) * rng.range(0.12, 0.5) * (0.45 + 0.7 * motion)
        let over = rampLength()
        open(donor, to: (weight[donor] ?? 0) - slice, over: over)
        open(recipient, to: (weight[recipient] ?? 0) + slice, over: over)
        tick.notes.append("transfer \(donor.label) → \(recipient.label)")
    }

    /// Slide the whole distribution along the low→high axis of the kit. This is
    /// the gesture you actually hear as the music "going somewhere": the same
    /// number of attacks per measure, gradually landing higher up the rack.
    private func tilt(_ tick: inout DirectorTick) {
        let center = rng.range(0.15, 0.9)
        let width = rng.range(0.28, 0.6)
        let pull = rng.range(0.18, 0.6) * (0.5 + 0.75 * motion)
        let over = rampLength()
        for voice in playable {
            let d = (voice.register - center) / width
            let bump = exp(-d * d)
            let current = weight[voice] ?? 0.05
            // Blend toward the bump rather than replacing: a tilt is a lean,
            // not a reset, and the kit keeps its character through it.
            let target = current * (1 - pull) + (0.03 + 0.35 * bump) * pull
            open(voice, to: target, over: over)
        }
        tick.notes.append(center > 0.55 ? "tilt upward" : "tilt downward")
    }

    /// Hand one lane an outsized share for a few measures, then give it back.
    private func spotlight(_ tick: inout DirectorTick) {
        let lanes = playable
        guard !lanes.isEmpty else { return }
        // Favor a lane that is currently quiet — a spotlight on the busiest
        // lane is not a change.
        let hunger = lanes.map { 1.0 / max(0.02, weight[$0] ?? 0.02) }
        guard let voice = rng.pick(lanes, weights: hunger) else { return }
        let before = weight[voice] ?? 0.05
        let up = 1 + rng.range(0.7, 2.2) * (0.5 + 0.7 * motion)
        let rise = rng.range(1.5, 3)
        open(voice, to: before * up, over: rise)
        after(rise + rng.range(2, 6)) { [weak self] t in
            guard let self else { return }
            self.open(voice, to: before, over: self.rampLength())
            t.notes.append("spotlight off \(voice.label)")
        }
        tick.notes.append("spotlight \(voice.label)")
    }

    /// Take a lane out entirely for a while. Its share is redistributed by the
    /// normalizing, so the measure stays exactly as dense — this is an
    /// arrangement change, not a thinning out, and it is the single most useful
    /// thing the director does.
    private func rest(_ tick: inout DirectorTick) {
        let lanes = playable
        guard lanes.count > 3 else { return }
        // The lowest lane anchors the measure; rest it rarely, and only when it
        // is not the one carrying the music.
        let weights = lanes.map { voice -> Double in
            let base = voice == .bass ? 0.25 : 1.0
            return base * (0.4 + (weight[voice] ?? 0))
        }
        guard let voice = rng.pick(lanes, weights: weights) else { return }
        let before = weight[voice] ?? 0.05
        resting.insert(voice)
        open(voice, to: 0.004, over: rng.range(1, 2.5))
        after(rng.range(3, 9)) { [weak self] t in
            guard let self else { return }
            self.resting.remove(voice)
            self.open(voice, to: before, over: self.rampLength())
            t.notes.append("\(voice.label) returns")
        }
        tick.notes.append("rest \(voice.label)")
    }

    /// Re-roll placement on a couple of lanes without touching their budget.
    /// Same density, same distribution, different figure — the cheapest way to
    /// keep a long session from feeling like one pattern with variations.
    private func churn(_ tick: inout DirectorTick) {
        let lanes = playable
        guard !lanes.isEmpty else { return }
        let n = 1 + rng.int(2)
        for _ in 0..<n { tick.reseed.insert(rng.pick(lanes)) }
        tick.notes.append("churn " + tick.reseed.map(\.short).joined(separator: " "))
    }

    /// Move the placement bias between the beat and the spaces around it.
    private func shift(_ tick: inout DirectorTick) {
        let target = rng.range(0.12, 0.7)
        temperatureRamp = Ramp(from: temperature, to: target, start: clock,
                               duration: rampLength())
        tick.notes.append(target > temperature ? "pushing off the beat" : "settling on the beat")
    }

    /// Repatch a module. Only ever a lane that is currently quiet, so the new
    /// sound arrives under the music instead of announcing itself — the same
    /// reasoning as Flow's rule about never changing an audible quality.
    private func repatch(_ tick: inout DirectorTick) {
        guard evolvePatches else { return }
        let lanes = playable
        guard !lanes.isEmpty else { return }
        let hunger = lanes.map { 1.0 / max(0.02, weight[$0] ?? 0.02) }
        guard let voice = rng.pick(lanes, weights: hunger) else { return }
        let patch = rng.pick(Patch.bank).name
        tick.repatches.append((voice, patch))
        tick.notes.append("repatch \(voice.label) ← \(patch)")
    }

    // Neither the room nor the echo is in this list any more, and that is a
    // decision rather than an omission. Both were drifting for a while — the
    // echo's depth on one clock and its subdivision on another — and the result
    // was an app whose *timing* had become unreliable to listen to. Anything
    // that moves a hit, or a repeat of a hit, now stays exactly where the player
    // put it; what drifts is what things sound like, not when they happen.

    /// Small, constant timbre drift. Every few measures one lane's macro starts
    /// a slow slide. Nobody notices any single one; over twenty minutes the kit
    /// is not the kit you started with.
    private func timbre(_ tick: inout DirectorTick) {
        guard evolvePatches else { return }
        let lanes = playable
        guard !lanes.isEmpty else { return }
        let voice = rng.pick(lanes)
        let macro = rng.pick(Macro.allCases)
        // Ranges deliberately narrower than the knobs allow: these are the
        // values that stay listenable for an hour, not the values that exist.
        let bounds: (Double, Double)
        switch macro {
        // Mostly downward. Upward is where the drums start sounding like a
        // xylophone, and the pitch ceiling in `Trigger` is a backstop rather
        // than somewhere to live.
        case .tone:  bounds = (0.7, 1.12)
        case .fold:  bounds = (0.4, 1.7)
        case .grit:  bounds = (0.3, 1.5)
        case .decay: bounds = (0.6, 1.6)
        case .pan:   bounds = (-0.85, 0.85)
        }
        let target = rng.range(bounds.0, bounds.1)
        let key = "\(voice.rawValue).\(macro.rawValue)"
        let from = macroRamps[key]?.ramp.value(at: clock) ?? 1.0
        macroRamps[key] = (voice, macro,
                           Ramp(from: from, to: target, start: clock,
                                duration: rng.range(4, 14)))
    }

    // MARK: - Player input

    /// "Do something now." Fires a transfer and a tilt immediately, and brings
    /// every other clock forward, so the button does something audible without
    /// abandoning the structure.
    func nudge() {
        var tick = DirectorTick()
        transfer(&tick)
        if rng.chance(0.5) { spotlight(&tick) } else { tilt(&tick) }
        for g in Gesture.allCases {
            due[g] = min(due[g] ?? clock, clock + Double(1 + rng.int(3)))
        }
    }

    /// Reset the distribution to the seed kit, keeping the clocks running.
    func reseedShares() {
        ramps.removeAll()
        pending.removeAll()
        resting.removeAll()
        weight = Self.seedWeights
    }
}
