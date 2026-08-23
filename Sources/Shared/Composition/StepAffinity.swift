import Foundation

/// Where hits *want* to go.
///
/// The budget decides how many attacks a lane gets in a measure. It says nothing
/// about where they land, and this is what answers that: a placement prior
/// learned from 214 transcribed drum-machine patterns (Stephen Handley's
/// transcription of the "260 Drum Machine Patterns" book, the same corpus
/// Phonotropic sequenced literally).
///
/// Meter does not play those patterns. It reads them as statistics — for each
/// lane, at each density, how likely is a hit on each step — and then composes
/// its own measures against that prior. That is the whole difference between a
/// pattern player and a machine that composes: the corpus supplies idiom, the
/// budget supplies form, and no measure is ever a pattern from the book.
///
/// Density matters more than it looks. A lane with two hits in a measure and a
/// lane with nine hits do not place them in scaled-up versions of the same
/// places — two kicks go on the downbeat and the middle, nine kicks go
/// somewhere else entirely — so the prior is conditioned on how many hits the
/// lane has.
final class StepAffinity {
    /// Corpus resolution. Everything in the book is sixteen steps.
    private static let sourceSteps = 16
    /// Hit-count buckets: sparse, moderate, busy, saturated.
    private static let bucketEdges = [2, 4, 8]

    /// voice -> bucket -> 16-step probability, normalized so its peak is 1.
    private var table: [DrumVoice: [[Double]]] = [:]
    /// How many corpus lanes landed in each bucket, so a thinly-populated
    /// bucket can be blended back toward the lane's overall shape.
    private var support: [DrumVoice: [Int]] = [:]

    private(set) var patternCount = 0

    static func bucket(forCount k: Int) -> Int {
        for (i, edge) in bucketEdges.enumerated() where k <= edge { return i }
        return bucketEdges.count
    }
    private static var bucketCount: Int { bucketEdges.count + 1 }

    init() { load() }

    /// The bundled corpus, or — when running headless from the check tool,
    /// where there is no app bundle — the copy in the source tree.
    private static func corpusURL() -> URL? {
        if let url = Bundle.main.url(forResource: "patterns", withExtension: "json") { return url }
        let fallbacks = ["Resources/patterns.json", "../Resources/patterns.json"]
        for path in fallbacks where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private struct RawPattern: Decodable {
        let title: String
        let length: Int
        let tracks: [String: [Int]]
    }

    private func load() {
        var counts: [DrumVoice: [[Double]]] = [:]
        var sup: [DrumVoice: [Int]] = [:]
        for v in DrumVoice.allCases {
            counts[v] = Array(repeating: Array(repeating: 0, count: Self.sourceSteps),
                              count: Self.bucketCount)
            sup[v] = Array(repeating: 0, count: Self.bucketCount)
        }

        if let url = Self.corpusURL(),
           let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode([RawPattern].self, from: data) {
            patternCount = raw.count
            for pattern in raw where pattern.length == Self.sourceSteps {
                // Two corpus tracks can land on one lane (clap and rim shot);
                // merge them before bucketing, or the density is understated.
                var merged: [DrumVoice: [Int]] = [:]
                for (name, steps) in pattern.tracks {
                    guard let voice = DrumVoice.fromPatternTrack(name) else { continue }
                    if var existing = merged[voice] {
                        for i in 0..<min(existing.count, steps.count) {
                            existing[i] = max(existing[i], steps[i])
                        }
                        merged[voice] = existing
                    } else {
                        merged[voice] = steps
                    }
                }
                for (voice, steps) in merged {
                    // A flam is two attacks, so it counts double here too.
                    let k = steps.reduce(0) { $0 + ($1 == 2 ? 2 : ($1 > 0 ? 1 : 0)) }
                    guard k > 0 else { continue }
                    let b = Self.bucket(forCount: k)
                    sup[voice]![b] += 1
                    for (i, value) in steps.enumerated() where value > 0 && i < Self.sourceSteps {
                        counts[voice]![b][i] += value == 2 ? 1.4 : 1.0
                    }
                }
            }
        } else {
            NSLog("Meter: patterns.json missing — falling back to metric priors only")
        }

        // Normalize, and blend a thin bucket toward the lane's overall shape so
        // a lane with three examples at that density doesn't produce a prior
        // that is really just those three patterns.
        for voice in DrumVoice.allCases {
            var buckets = counts[voice]!
            let overall = (0..<Self.sourceSteps).map { i in
                buckets.reduce(0.0) { $0 + $1[i] }
            }
            let overallPeak = overall.max() ?? 0
            for b in 0..<Self.bucketCount {
                let n = sup[voice]![b]
                let confidence = min(1.0, Double(n) / 12.0)
                var row = buckets[b]
                let peak = row.max() ?? 0
                for i in 0..<Self.sourceSteps {
                    let own = peak > 0 ? row[i] / peak : 0
                    let general = overallPeak > 0 ? overall[i] / overallPeak : 0
                    // A floor, so no step is ever completely forbidden — the
                    // corpus is a prior, not a rulebook.
                    row[i] = 0.06 + 0.94 * (confidence * own + (1 - confidence) * general)
                }
                buckets[b] = row
            }
            table[voice] = buckets
            support[voice] = sup[voice]
        }
    }

    /// The prior for a lane at a given hit count, resampled to `steps`.
    ///
    /// Resampling is by phase: step *i* of an eleven-step measure sits at the
    /// same fraction through the bar as some fractional position in the corpus's
    /// sixteen, and the prior is read there with linear interpolation. It is a
    /// stretch rather than a truncation, so a 7/8 measure inherits the corpus's
    /// sense of "early in the bar" instead of the first fourteen slots of a 4/4
    /// pattern.
    func prior(for voice: DrumVoice, count: Int, steps: Int) -> [Double] {
        guard let row = table[voice]?[Self.bucket(forCount: count)] else {
            return Array(repeating: 1, count: steps)
        }
        guard steps != Self.sourceSteps else { return row }
        var out = [Double](repeating: 0, count: steps)
        for i in 0..<steps {
            let x = Double(i) / Double(steps) * Double(Self.sourceSteps)
            let lo = Int(x) % Self.sourceSteps
            let hi = (lo + 1) % Self.sourceSteps
            let frac = x - Double(Int(x))
            out[i] = row[lo] * (1 - frac) + row[hi] * frac
        }
        return out
    }
}
