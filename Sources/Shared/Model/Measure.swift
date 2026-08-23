import Foundation

/// Ticks per quarter note. Everything in a measure is placed on this grid:
/// steps, swing, flams and humanized micro-timing are all just tick offsets,
/// and MIDI clock falls out of it at every fourth tick (96 / 4 = 24 PPQN).
let ticksPerQuarter = 96

/// A time signature, described the way the composer needs it: how many steps a
/// measure has, and how those steps group into pulses. The grouping is what
/// gives an odd meter its accent pattern — 7/8 is not "seven eighths", it is
/// 2+2+3, and placing hits without knowing that produces something that limps.
struct Signature: Identifiable, Hashable, Codable {
    var name: String
    /// Sixteenth-note steps per measure.
    var steps: Int
    /// Steps per pulse group, summing to `steps`.
    var groups: [Int]

    var id: String { name }
    var ticksPerStep: Int { ticksPerQuarter / 4 }
    var ticks: Int { steps * ticksPerStep }

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
