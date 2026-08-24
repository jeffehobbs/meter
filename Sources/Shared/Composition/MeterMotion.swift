import Foundation

/// How — and whether — the machine moves between time signatures.
///
/// A meter change is the one gesture in Meter that cannot be ramped. Everything
/// else the director does is a slide: a share, a macro, a tempo. The bar is
/// either sixteen steps long or it is twenty, and there is no halfway. So the
/// question is not how to smooth it but where to hide it, and these are five
/// different answers to that, exactly one of which is running at a time.
///
/// They are all here rather than one of them because the only way to know which
/// works is to listen to it for twenty minutes, and `fixed` is the default so
/// that finding out costs nothing.
enum MeterMotion: String, Codable, CaseIterable, Identifiable {
    /// Never. The bar is whatever it was set to.
    case fixed
    /// Pick a meter by name at the thinnest part of a passage. What the Mac app
    /// did before any of this, kept so the others have something to lose to.
    case sections
    /// Same bar length, other subdivision: 4/4 ⇄ 4/4 triplet. The quarter note
    /// does not move, so the pulse is untouched and only the feel changes.
    case pivot
    /// Keep the meter and steal or add one beat for a single bar, then give it
    /// back. Meter change as ornament rather than as section.
    case elide
    /// A random walk over meters one tail-edit apart — append a beat, drop a
    /// beat, relength the last one. Every step keeps the head of the bar intact,
    /// so the walk can get a long way from four without a seam.
    case walk
    /// Never change the meter at all. Instead let each lane's figure run on a
    /// cycle that is not the bar length, so the kit phases against itself. The
    /// only option here that cannot disrupt the beat, because nothing global
    /// ever changes.
    case rotate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fixed:    return "fixed"
        case .sections: return "sections"
        case .pivot:    return "pivot"
        case .elide:    return "elide"
        case .walk:     return "walk"
        case .rotate:   return "rotate"
        }
    }

    var hint: String {
        switch self {
        case .fixed:
            return "The bar stays as you set it."
        case .sections:
            return "Pick a new meter outright, at the thinnest part of a passage. Loses the figure and changes the felt density with it — the honest baseline for the others."
        case .pivot:
            return "4/4 ⇄ 4/4 triplet: the bar keeps its length and the quarter note never moves, so straight becomes a shuffle with nothing to catch."
        case .elide:
            return "Steal or add one beat for a single bar, then give it back. A bar of 7/8 inside four."
        case .walk:
            return "Walk to a meter one edit away — a beat appended, dropped or relengthened — keeping the head of the bar. Over an hour it gets a long way from four."
        case .rotate:
            return "Never changes the meter. Each lane's figure runs on its own cycle against the bar, so the kit phases instead. The low end holds the bar."
        }
    }

    /// Whether this one ever hands a new signature to the transport.
    var changesSignature: Bool { self != .fixed && self != .rotate }

    /// Whether the lanes phase against the bar instead.
    var rotatesLanes: Bool { self == .rotate }

    /// Whether a lane keeps the figure it was playing across the change —
    /// including across one the player makes by hand.
    ///
    /// False for `fixed` as well as for `sections`, and that is the point of the
    /// default rather than an oversight: with nothing turned on, a meter change
    /// does exactly what it did before any of this existed, down to wiping the
    /// composer's memory. Nothing here is on until it is chosen.
    var keepsFigure: Bool {
        switch self {
        case .fixed, .sections: return false
        case .pivot, .elide, .walk, .rotate: return true
        }
    }

    /// Whether the budget is rescaled so attacks-per-second survives the change.
    /// Without this a move to a shorter bar arrives wearing a density change,
    /// and the two together read as an edit.
    var holdsDensity: Bool { keepsFigure }

    /// Whether the change waits for a quiet moment. An elision does not: it is
    /// an ornament, and it wants the groove to be there to interrupt.
    var needsQuiet: Bool { self != .elide }

    /// Bars between attempts, prime, so this never lines up with a gesture clock.
    var period: Int { self == .elide ? 17 : 61 }
}

/// The meter arc.
///
/// Split out of `FlowDirector` so that the iOS build — which owns its own tempo
/// and density and wants none of Flow's opinions about them — can have the meter
/// without the rest, and so that both hosts are running the same code rather
/// than two versions of it.
final class MeterArc {
    var motion: MeterMotion = .fixed

    /// What one bar decided. `signature` nil means "leave the bar alone".
    struct Decision {
        var signature: Signature?
        /// Multiply the budget by this to keep the density where it was.
        var densityScale: Double = 1
        /// Whether the lanes keep their figures through the change.
        var keepsFigure: Bool = true
        var notes: [String] = []
    }

    /// What `sections` is allowed to pick from. Four is in three times because a
    /// machine that plays odd meters two thirds of the time is a novelty.
    private static let namedMeters = ["4/4", "4/4", "4/4", "3/4", "6/8", "7/8", "5/4"]

    private var rng: Rng
    private var clock = 0
    private var due = 0
    private var lastChange = -99
    private var restore: (at: Int, signature: Signature)?
    private var home = Signature.named("4/4")

    init(seed: UInt64 = Rng.freshSeed()) {
        rng = Rng(seed: seed)
        due = 3 + rng.int(61)
    }

    /// Re-centre. The meter the player last chose is the one a walk is pulled
    /// back toward, the same way Flow re-anchors on a tempo you set by hand.
    func reanchor(_ signature: Signature) {
        home = signature
        restore = nil
        due = clock + 6 + rng.int(motion.period)
    }

    /// Whether the bar that just played is thin enough to change the meter under.
    ///
    /// Both builds ask this of the measure, and the Mac ORs in Flow's own test —
    /// the bottom of one of its long quiet passages — when Flow is running. What
    /// stands in for that otherwise is the director having thinned the bar itself:
    /// the bass out, which is the one gesture that leaves no downbeat to
    /// contradict, or most of the kit sitting out at once. Both are rare, which is
    /// what a meter change should be.
    static func isQuiet(_ measure: Measure) -> Bool {
        if (measure.counts[.bass] ?? 0) == 0 { return true }
        let playing = measure.counts.values.filter { $0 > 0 }.count
        return Double(playing) < Double(DrumVoice.allCases.count) * 0.55
    }

    /// One bar. `quiet` is the host saying that now is a thin moment — see
    /// `isQuiet`, and what each build adds to it.
    func advance(current: Signature, quiet: Bool) -> Decision {
        clock += 1

        // A one-bar elision puts itself back before anything else may fire.
        if let pending = restore, clock >= pending.at {
            restore = nil
            return decide(to: pending.signature, from: current,
                          note: "meter back to \(pending.signature.name)")
        }

        guard motion.changesSignature, clock >= due else { return Decision() }

        // The gates, cheapest first: not twice in a row, a quiet moment if this
        // motion wants one, and a bar the ear can count to.
        let soonEnough = clock - lastChange >= 8
        let rightMoment = quiet || !motion.needsQuiet
        // The one place in the app that wants a round number. A meter change on
        // bar seventeen of a phrase is a mistake; on bar sixteen it is a
        // decision, and four bars is as much structure as this machine admits to.
        let onPhrase = clock % 4 == 0
        // Next bar, not four bars on. Adding four to a bar that is not already a
        // multiple of four lands on another bar that is not, forever — which is
        // exactly what it did, and why nothing ever changed meter. Once the arc
        // is due it is looking for a moment, so it looks every bar until it
        // finds one.
        guard soonEnough, rightMoment, onPhrase else {
            due = clock + 1
            return Decision()
        }

        due = clock + motion.period + Int(rng.range(-4, 8))
        lastChange = clock

        switch motion {
        case .fixed, .rotate:
            return Decision()

        case .sections:
            let choice = Signature.named(rng.pick(Self.namedMeters))
            guard choice != current else { return Decision() }
            return decide(to: choice, from: current, note: "meter → \(choice.name)")

        case .pivot:
            // A meter with no triplet partner — anything with a dotted-quarter
            // group — pivots by going home first, where there is one.
            let target = current.subdivisionPartner ?? home
            guard target != current else { return Decision() }
            return decide(to: target, from: current, note: "meter → \(target.name)")

        case .walk:
            guard let target = pickNeighbor(of: current) else { return Decision() }
            return decide(to: target, from: current, note: "meter → \(target.name)")

        case .elide:
            // Only ever a bar-length edit, never a subdivision pivot: changing
            // the feel for exactly one bar and changing it back is a stumble
            // rather than an ornament.
            let candidates = current.neighbors.filter { $0.ticksPerStep == current.ticksPerStep }
            guard !candidates.isEmpty else { return Decision() }
            let target = rng.pick(candidates)
            restore = (at: clock + 1, signature: current)
            return decide(to: target, from: current, note: "one bar of \(target.name)")
        }
    }

    /// Neighbors, weighted toward home. Without the pull a walk wanders out to
    /// seven-four triplet and has no reason ever to come back; with it the
    /// machine roams and returns, which is what a long session wants.
    private func pickNeighbor(of current: Signature) -> Signature? {
        let candidates = current.neighbors
        guard !candidates.isEmpty else { return nil }
        let weights = candidates.map { candidate -> Double in
            let awayNow = abs(current.ticks - home.ticks)
            let awayThen = abs(candidate.ticks - home.ticks)
            // Closer to home is always allowed; further away gets harder the
            // further out we already are.
            let pull = awayThen <= awayNow ? 1.0 : 1.0 / (1.0 + Double(awayThen) / 192.0)
            // And a mild preference for keeping the subdivision, so the walk is
            // mostly about bar length and the pivot stays a rarer event.
            return pull * (candidate.ticksPerStep == current.ticksPerStep ? 1.0 : 0.35)
        }
        return rng.pick(candidates, weights: weights)
    }

    private func decide(to target: Signature, from current: Signature, note: String) -> Decision {
        var decision = Decision()
        decision.signature = target
        decision.keepsFigure = motion.keepsFigure
        if motion.holdsDensity {
            decision.densityScale = Double(target.ticks) / Double(max(1, current.ticks))
        }
        decision.notes.append(note)
        return decision
    }
}
