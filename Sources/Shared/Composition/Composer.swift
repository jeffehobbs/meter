import Foundation

/// Turns a budget and a distribution into an actual measure.
///
/// The division of labor is the point of the whole program. The director says
/// *how much* each lane gets. The corpus prior says *where* a lane of that
/// density likes to put its hits. The meter's own accent pattern says which
/// steps are strong. The composer is what negotiates between those three and
/// spends the budget down to the last attack.
final class Composer {
    let affinity = StepAffinity()

    var signature: Signature = .named("4/4")
    /// Off-sixteenths pushed later, 0 straight … 1 hard shuffle.
    var swing: Double = 0
    /// Timing scatter in ticks, so the grid stops being a grid.
    var humanize: Double = 0.3
    /// Chance a lane turns two of its attacks into one flam.
    var flamAmount: Double = 0.12
    /// How much of last measure a lane keeps. This is what gives the music a
    /// figure to recognize; at zero every measure is a stranger.
    var persistence: Double = 0.72
    /// Depth of the dynamics, 0 flat … 1 full.
    var accent: Double = 0.7

    /// What each lane played last measure, so a measure can be an edit of the
    /// one before rather than a fresh roll.
    private var previous: [DrumVoice: Set<Int>] = [:]
    /// Per-lane stepping seed. Each lane advances by a different prime, so two
    /// lanes never re-roll in step.
    private var seed: [DrumVoice: Int] = [:]
    private var rng: Rng
    /// This session's own number, mixed into every placement decision.
    ///
    /// Without it the machine opened on the same bar every time it was launched.
    /// The lane streams were seeded from fixed constants and the measure index,
    /// so the first measure of a session was a pure function of the budget — and
    /// since the director's opening distribution was fixed too, so were the
    /// second and the third. An app you leave running is one you start often,
    /// and starting is the part you hear most.
    private let salt: UInt64

    init(seed: UInt64 = Rng.freshSeed()) {
        rng = Rng(seed: seed)
        salt = seed
        for v in DrumVoice.allCases {
            self.seed[v] = 1 + rng.int(9_973)
        }
    }

    func reset() {
        previous.removeAll()
    }

    // MARK: - Composing

    func compose(index: Int, budget: Int, tick: DirectorTick,
                 enabled: Set<DrumVoice>) -> Measure {
        let steps = signature.steps
        let lanes = DrumVoice.allCases.filter { enabled.contains($0) }
        var measure = Measure(index: index, signature: signature, budget: budget)
        measure.shares = tick.shares
        guard budget > 0, !lanes.isEmpty else {
            previous = [:]
            return measure
        }

        // --- spend the budget ------------------------------------------------
        let weights = lanes.map { tick.shares[$0] ?? 0 }
        var units = apportion(total: budget, weights: weights)

        // A lane can hold at most one attack per step, plus one more per step it
        // flams. Anything over that has to go somewhere else, or the budget
        // silently evaporates.
        var overflow = 0
        for i in lanes.indices {
            let cap = lanes[i].allowsFlam ? steps * 2 : steps
            if units[i] > cap {
                overflow += units[i] - cap
                units[i] = cap
            }
        }
        var guard_ = 0
        while overflow > 0 && guard_ < 64 {
            guard_ += 1
            var placed = false
            for i in lanes.indices where overflow > 0 {
                let cap = lanes[i].allowsFlam ? steps * 2 : steps
                if units[i] < cap { units[i] += 1; overflow -= 1; placed = true }
            }
            if !placed { break }
        }

        let metric = signature.stepWeights
        // Placement bias. A negative exponent is not a bug: it turns the metric
        // weighting inside out, so the same machinery that puts hits on the
        // beat puts them in the gaps when the director asks for that.
        let exponent = 1.8 - tick.temperature * 2.6

        for (i, voice) in lanes.enumerated() {
            let allocated = units[i]
            guard allocated > 0 else {
                previous[voice] = []
                measure.counts[voice] = 0
                continue
            }

            // Attacks split into hits and flams: a flam is two attacks on one
            // step, which is how a lane spends more than one attack per step.
            var flamBudget = 0
            var count = allocated
            if count > steps {
                flamBudget = count - steps
                count = steps
            }

            let prior = affinity.prior(for: voice, count: count, steps: steps)
            var weight = [Double](repeating: 0, count: steps)
            for s in 0..<steps {
                let m = pow(max(0.04, metric[s]), exponent)
                weight[s] = max(0.0001, prior[s] * m)
            }

            // Each lane gets its own deterministic stream, stepped by its own
            // prime, so lanes decorrelate over measures instead of all changing
            // their mind on the same bar.
            let laneSeed = seed[voice] ?? 1
            seed[voice] = laneSeed + Primes.small[abs(laneSeed) % Primes.small.count]
            var laneRng = Rng(seed: salt
                              ^ UInt64(truncatingIfNeeded: laneSeed &* 2_654_435_761)
                              &+ UInt64(truncatingIfNeeded: index &* 40_503))

            var chosen = Set<Int>()
            // Inherit from last measure unless the director asked for a churn.
            if !tick.reseed.contains(voice), let last = previous[voice] {
                // `.sorted()`, not the set's own order. Swift randomizes hash
                // seeds per process, so walking a Set draws the random numbers in
                // a different order every run — and a seeded composer that plays
                // different music each launch is not seeded at all.
                for s in last.sorted() where s < steps {
                    if laneRng.chance(persistence) { chosen.insert(s) }
                }
            }
            if chosen.count > count {
                // Too many survivors: drop the weakest.
                // Ties broken by step, so the order is the music's rather than
                // the hash table's.
                let ordered = chosen.sorted { (weight[$0], $0) < (weight[$1], $1) }
                for s in ordered.prefix(chosen.count - count) { chosen.remove(s) }
            }

            // Fill up to count, with repulsion so hits spread out. Repulsion has
            // to relax as the lane gets busy — at fourteen hits in sixteen steps
            // "don't sit next to anything" is not satisfiable.
            let sparsity = max(0, 1 - Double(count) / Double(steps))
            var available = weight
            for s in chosen.sorted() {
                available[s] = 0
                applyRepulsion(&available, around: s, steps: steps, strength: sparsity)
            }
            while chosen.count < count {
                let candidates = (0..<steps).filter { !chosen.contains($0) }
                guard !candidates.isEmpty else { break }
                let w = candidates.map { max(0.000001, available[$0]) }
                let pick = laneRng.pick(candidates, weights: w) ?? candidates[0]
                chosen.insert(pick)
                available[pick] = 0
                applyRepulsion(&available, around: pick, steps: steps, strength: sparsity)
            }

            previous[voice] = chosen
            measure.counts[voice] = chosen.count

            // --- flams -------------------------------------------------------
            var flamSteps = Set<Int>()
            if voice.allowsFlam {
                // Overflow attacks have to become flams — that is what they are
                // for — and beyond those, an occasional one by choice.
                let ordered = chosen.sorted { (weight[$0], $1) > (weight[$1], $0) }
                for s in ordered.prefix(flamBudget) { flamSteps.insert(s) }
                if flamBudget == 0, chosen.count >= 2, laneRng.chance(flamAmount * 0.5) {
                    // Paid for by giving up a hit, so the budget still balances.
                    if let weakest = chosen.min(by: { (weight[$0], $0) < (weight[$1], $1) }),
                       let host = chosen.filter({ $0 != weakest }).randomElement(using: &laneRng) {
                        chosen.remove(weakest)
                        flamSteps.insert(host)
                        previous[voice] = chosen
                        measure.counts[voice] = chosen.count
                    }
                }
            }

            // --- to hits -----------------------------------------------------
            for s in chosen.sorted() {
                let strong = metric[s]
                // Loud on the strong steps, quiet in the gaps; `accent` decides
                // how much that matters.
                let shape = 0.46 + 0.5 * strong + laneRng.range(-0.05, 0.05)
                let velocity = min(1, max(0.12, 1 - accent * (1 - shape)))
                measure.hits.append(Hit(voice: voice, step: s,
                                        tick: tickFor(step: s, rng: &laneRng),
                                        velocity: velocity,
                                        flam: flamSteps.contains(s)))
            }
        }

        measure.hits.sort { $0.tick < $1.tick }
        return measure
    }

    private func applyRepulsion(_ weights: inout [Double], around step: Int, steps: Int, strength: Double) {
        guard strength > 0 else { return }
        for (offset, factor) in [(1, 0.62), (-1, 0.62), (2, 0.28), (-2, 0.28)] {
            let s = ((step + offset) % steps + steps) % steps
            weights[s] *= 1 - factor * strength
        }
    }

    /// Where a step actually lands: swing pushes the off-sixteenths late, then
    /// everything gets a few ticks of scatter. The downbeat is never allowed to
    /// arrive early — a bar that starts before it starts sounds like a mistake
    /// rather than like a human.
    private func tickFor(step: Int, rng: inout Rng) -> Int {
        let per = signature.ticksPerStep
        var t = step * per
        if step % 2 == 1 { t += Int(swing * 0.5 * Double(per)) }
        if humanize > 0 {
            let scatter = Int(rng.range(-1, 1) * humanize * 4.5)
            t += scatter
        }
        if step == 0 { t = max(0, t) }
        return max(0, min(signature.ticks - 1, t))
    }
}

private extension Set where Element == Int {
    /// Deterministic pick from our own stream — `randomElement()` would reach
    /// for the system RNG and make a session unreproducible.
    func randomElement(using rng: inout Rng) -> Int? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        return sorted[rng.int(sorted.count)]
    }
}
