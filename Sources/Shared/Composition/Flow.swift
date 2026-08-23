import Foundation

/// Flow — the machine playing itself.
///
/// The director already decides everything about *how* a measure is played. Two
/// numbers were always the player's: tempo and budget. Flow is what happens when
/// you hand those over too, and then leave the room.
///
/// The rules are Thrum's, and the reason for each is the same one:
///
///   * **Nothing is set, only ramped**, on a curve with zero velocity at both
///     ends. A tempo that steps is an event; a tempo that arrives over four
///     minutes is the piece going somewhere.
///   * **Every arc has its own prime period**, so tempo and density never turn
///     over together and the session has no bar line you could point at.
///   * **Narrow ranges.** Flow roams around where the player left things rather
///     than across the whole dial: ±14% of the tempo you set, not 40 to 200.
///
/// What Flow deliberately does *not* touch is anything that changes where a hit
/// lands inside the bar — swing, humanizing, the flam rate. Those drifted once
/// and the result was an instrument whose timing could not be trusted. A slow
/// arc in tempo is a piece breathing; a drifting swing is a fault.
final class FlowDirector {
    /// What Flow wants this measure. Nil fields mean "leave that alone".
    struct Move {
        var tempo: Double?
        var budget: Double?
        var signature: String?
        var notes: [String] = []
    }

    private(set) var isRunning = false
    /// Where Flow roams around. Re-anchored whenever the player takes a control
    /// back, so steering it is a matter of moving a slider rather than
    /// switching it off.
    private(set) var anchorTempo: Double = 112
    private(set) var anchorBudget: Double = 14

    private enum Arc: String, CaseIterable {
        case tempo, density, meter

        /// In measures, and prime, so no two arcs ever turn over together.
        var period: Int {
            switch self {
            case .density: return 17
            case .tempo:   return 29
            case .meter:   return 61
            }
        }
    }

    private var clock: Double = 0
    private var due: [Arc: Double] = [:]
    private var tempoRamp: Ramp?
    private var budgetRamp: Ramp?
    private var tempo: Double = 112
    private var budget: Double = 14
    private var rng: Rng

    /// The meters Flow is allowed to choose. Odd ones are in because they are
    /// the reason the composer knows about pulse groups at all, and because a
    /// machine that only ever plays in four is a machine you stop hearing.
    private static let meters = ["4/4", "4/4", "4/4", "3/4", "6/8", "7/8", "5/4"]

    init(seed: UInt64 = Rng.freshSeed()) {
        rng = Rng(seed: seed)
    }

    func start(tempo: Double, budget: Double) {
        isRunning = true
        clock = 0
        anchorTempo = tempo
        anchorBudget = budget
        self.tempo = tempo
        self.budget = budget
        tempoRamp = nil
        budgetRamp = nil
        // Staggered, so the first minute is not three decisions at once.
        for arc in Arc.allCases { due[arc] = Double(3 + rng.int(arc.period)) }
    }

    func stop() {
        isRunning = false
        tempoRamp = nil
        budgetRamp = nil
    }

    /// The player moved a control while Flow was running. Their number becomes
    /// the new centre rather than being overwritten on the next tick.
    func reanchor(tempo: Double? = nil, budget: Double? = nil) {
        if let tempo {
            anchorTempo = tempo
            self.tempo = tempo
            tempoRamp = nil
            due[.tempo] = clock + Double(6 + rng.int(12))
        }
        if let budget {
            anchorBudget = budget
            self.budget = budget
            budgetRamp = nil
            due[.density] = clock + Double(4 + rng.int(8))
        }
    }

    /// One measure. Returns whatever changed.
    func advance() -> Move {
        guard isRunning else { return Move() }
        clock += 1
        var move = Move()

        if let ramp = tempoRamp {
            tempo = ramp.value(at: clock)
            move.tempo = tempo
            if ramp.done(at: clock) { tempoRamp = nil }
        }
        if let ramp = budgetRamp {
            budget = ramp.value(at: clock)
            move.budget = budget
            if ramp.done(at: clock) { budgetRamp = nil }
        }

        for arc in Arc.allCases {
            guard let at = due[arc], clock >= at else { continue }
            perform(arc, into: &move)
            due[arc] = clock + Double(arc.period) + rng.range(-2, 4)
        }
        return move
    }

    private func perform(_ arc: Arc, into move: inout Move) {
        switch arc {
        case .tempo:
            // Four to ten minutes to cross the range, so nobody catches it
            // moving. The anchor keeps it from wandering off over an hour.
            let target = anchorTempo * rng.range(0.86, 1.14)
            tempoRamp = Ramp(from: tempo, to: min(190, max(44, target)),
                             start: clock, duration: rng.range(24, 70))
            move.notes.append(String(format: "flow: tempo → %.0f", target))

        case .density:
            // The arc that shapes a session: long thin passages and short busy
            // ones, rather than a constant.
            let target = anchorBudget * rng.range(0.45, 1.7)
            budgetRamp = Ramp(from: budget, to: min(48, max(3, target)),
                              start: clock, duration: rng.range(10, 30))
            move.notes.append(target > budget ? "flow: filling in" : "flow: thinning out")

        case .meter:
            // A meter change is a section, not a drift — there is no ramping it.
            // So it happens where a section change belongs: at the thinnest part
            // of a passage, when there is least to interrupt.
            guard budget < anchorBudget * 0.8 else {
                due[.meter] = clock + 4
                return
            }
            let choice = rng.pick(Self.meters)
            move.signature = choice
            move.notes.append("flow: \(choice)")
        }
    }
}
