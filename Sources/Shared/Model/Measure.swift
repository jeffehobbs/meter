import Foundation

/// Ticks per quarter note. Everything in a measure is placed on this grid:
/// steps, swing, flams and humanized micro-timing are all just tick offsets,
/// and MIDI clock falls out of it at every fourth tick (96 / 4 = 24 PPQN).
let ticksPerQuarter = 96

/// A time signature, described the way the composer needs it: how many steps a
/// measure has, how those steps group into pulses, and how long a step is. The
/// grouping is what gives an odd meter its accent pattern — 7/8 is not "seven
/// eighths", it is 2+2+3, and placing hits without knowing that produces
/// something that limps.
struct Signature: Identifiable, Hashable, Codable {
    var name: String
    /// Steps per measure, each `ticksPerStep` long.
    var steps: Int
    /// Steps per pulse group, summing to `steps`.
    var groups: [Int]
    /// How long one step is. Duple meters step in sixteenths; the triplet
    /// variants step in thirds of a quarter, which is what lets a bar change its
    /// subdivision without changing its length. See `subdivisionPartner`.
    var ticksPerStep: Int = Signature.duple

    var id: String { name }
    var ticks: Int { steps * ticksPerStep }

    /// The two subdivisions Meter knows: a sixteenth of a quarter, and a third
    /// of one.
    static let duple = ticksPerQuarter / 4      // 24
    static let triple = ticksPerQuarter / 3     // 32

    /// Group lengths a meter of this subdivision is allowed to use: a quarter or
    /// a dotted quarter in sixteenths, one quarter in triplet eighths.
    var vocabulary: [Int] { ticksPerStep == Signature.triple ? [3] : [4, 6] }

    /// Named from the groups, so a generated meter reads the same way a written
    /// one does. All ten of the meters below reproduce their own names through
    /// this, which is the check that it agrees with how the app already talks.
    init(groups: [Int], ticksPerStep: Int = Signature.duple) {
        let steps = groups.reduce(0, +)
        self.steps = steps
        self.groups = groups
        self.ticksPerStep = ticksPerStep
        if ticksPerStep == Signature.triple {
            name = "\(steps / 3)/4 triplet"
        } else if groups.allSatisfy({ $0 == 4 }) {
            name = "\(groups.count)/4"
        } else {
            name = "\(steps / 2)/8"
        }
    }

    init(name: String, steps: Int, groups: [Int], ticksPerStep: Int = Signature.duple) {
        self.name = name
        self.steps = steps
        self.groups = groups
        self.ticksPerStep = ticksPerStep
    }

    static let all: [Signature] = [
        Signature(name: "4/4",  steps: 16, groups: [4, 4, 4, 4]),
        Signature(name: "3/4",  steps: 12, groups: [4, 4, 4]),
        Signature(name: "5/4",  steps: 20, groups: [4, 4, 4, 4, 4]),
        Signature(name: "7/4",  steps: 28, groups: [4, 4, 4, 4, 4, 4, 4]),
        Signature(name: "5/8",  steps: 10, groups: [4, 6]),
        Signature(name: "6/8",  steps: 12, groups: [6, 6]),
        Signature(name: "7/8",  steps: 14, groups: [4, 4, 6]),
        Signature(name: "9/8",  steps: 18, groups: [6, 6, 6]),
        Signature(name: "11/8", steps: 22, groups: [4, 4, 6, 4, 4]),
        Signature(name: "12/8", steps: 24, groups: [6, 6, 6, 6]),
    ]

    static func named(_ name: String) -> Signature {
        all.first { $0.name == name } ?? all[0]
    }

    // MARK: - Moving

    /// The same bar, subdivided the other way.
    ///
    /// Four quarters in sixteenths is sixteen steps of 24 ticks; four quarters in
    /// triplet eighths is twelve steps of 32. Both are 384 ticks, so the bar keeps
    /// its length and the quarter note never moves — the feel goes from straight
    /// to a shuffle and the listener's foot stays where it was. This is the least
    /// disruptive move in the app, and it is only available to quarter-based
    /// meters: a group of six sixteenths is a dotted quarter, and there is no
    /// whole number of triplet eighths in one.
    var subdivisionPartner: Signature? {
        if ticksPerStep == Signature.triple {
            return Signature(groups: groups.map { _ in 4 }, ticksPerStep: Signature.duple)
        }
        guard groups.allSatisfy({ $0 == 4 }) else { return nil }
        return Signature(groups: groups.map { _ in 3 }, ticksPerStep: Signature.triple)
    }

    /// Meters one edit away, where an edit only ever touches the *tail* of the
    /// bar: append a group, drop the last one, relength the last one, or pivot the
    /// subdivision. That restriction is the whole point. `[4,4,4,4]` → `[4,4,4,4,4]`
    /// is 4/4 → 5/4 in which the first sixteen steps are literally identical and a
    /// beat is appended; relengthening an interior group would shift everything
    /// after it, which is the kind of change the ear catches.
    var neighbors: [Signature] {
        var out: [Signature] = []
        let vocab = vocabulary
        if groups.count < 7 {
            for len in vocab { out.append(Signature(groups: groups + [len], ticksPerStep: ticksPerStep)) }
        }
        if groups.count > 2 {
            out.append(Signature(groups: Array(groups.dropLast()), ticksPerStep: ticksPerStep))
        }
        for len in vocab where len != groups.last {
            out.append(Signature(groups: Array(groups.dropLast()) + [len], ticksPerStep: ticksPerStep))
        }
        if let partner = subdivisionPartner { out.append(partner) }
        return out.filter { $0.steps >= 6 && $0 != self }
    }

    /// Where a step of `other` lands in this meter, by tick rather than by index.
    ///
    /// One rule covers both kinds of move, which is why it is the only one here.
    /// Across a subdivision pivot the tick is what has to survive — step 8 of
    /// sixteen is beat three, and so is step 6 of twelve. Across a bar-length
    /// change the step index is what has to survive, and preserving the tick does
    /// exactly that, because the step is the same length on both sides.
    func step(matching step: Int, in other: Signature) -> Int? {
        let tick = step * other.ticksPerStep
        let mapped = Int((Double(tick) / Double(ticksPerStep)).rounded())
        return mapped < steps ? mapped : nil
    }

    /// Metric weight per step, 0 … 1. The downbeat is 1, each group's head is
    /// strong, the middle of a group is medium and the sixteenths between are
    /// weak. Composition multiplies the corpus prior by this, which is what
    /// keeps an odd meter's placement honest even though the corpus is all 4/4.
    var stepWeights: [Double] {
        var w = [Double](repeating: 0.18, count: steps)
        var i = 0
        for (g, len) in groups.enumerated() {
            guard i < steps else { break }
            w[i] = g == 0 ? 1.0 : 0.70
            // The middle of the group — the "and" of the beat.
            if len >= 4 {
                let mid = i + len / 2
                if mid < steps { w[mid] = max(w[mid], 0.40) }
            }
            if len == 6, i + 2 < steps, i + 4 < steps {
                // A group of three eighths has two inner pulses, not one.
                w[i + 2] = max(w[i + 2], 0.36)
                w[i + 4] = max(w[i + 4], 0.36)
            }
            i += len
        }
        // The halfway point of the measure carries weight of its own in any
        // meter that has one.
        if steps % 2 == 0 { w[steps / 2] = max(w[steps / 2], 0.62) }
        return w
    }

    /// Step indices that begin a pulse group, for the grid's dividers.
    var groupStarts: Set<Int> {
        var result: Set<Int> = []
        var i = 0
        for len in groups { result.insert(i); i += len }
        return result
    }
}

/// One scheduled hit.
struct Hit: Identifiable, Hashable {
    var voice: DrumVoice
    var step: Int
    /// Tick within the measure, after swing, humanizing and flam offsets.
    var tick: Int
    var velocity: Double
    /// A flam is a second attack a few ticks later. It costs two units of
    /// budget, because it is two attacks — which is the whole reason the budget
    /// is counted in attacks rather than in notes.
    var flam: Bool

    var id: String { "\(voice.rawValue)-\(step)-\(tick)" }
    var cost: Int { flam ? 2 : 1 }
}

/// One measure of music, plus the accounting that produced it.
struct Measure {
    var index: Int = 0
    var signature: Signature = .named("4/4")
    var hits: [Hit] = []
    /// Budget in attacks, and the share each lane was given of it.
    var budget: Int = 0
    var counts: [DrumVoice: Int] = [:]
    var shares: [DrumVoice: Double] = [:]

    var spent: Int { hits.reduce(0) { $0 + $1.cost } }

    /// Hits for a lane at a step — a flam still reads as one cell in the grid.
    func hit(_ voice: DrumVoice, step: Int) -> Hit? {
        hits.first { $0.voice == voice && $0.step == step }
    }
}
