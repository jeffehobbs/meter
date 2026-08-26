import Foundation

/// Where a lane's hits go.
enum Route: String, Codable, CaseIterable, Identifiable {
    case synth, midi, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .synth: return "Rack"
        case .midi:  return "MIDI"
        case .both:  return "Both"
        }
    }
}

/// The clock, and everything that happens on it.
///
/// Time is counted in ticks at 96 per quarter note. Steps, swing, flams and
/// humanized micro-timing are all tick offsets, and MIDI beat clock falls out
/// of the same counter at every fourth tick — 24 PPQN, exactly what the spec
/// asks for. Composing at a coarser resolution and adding a separate clock
/// generator is the arrangement that goes out of step after ten minutes.
///
/// Everything the transport owns is touched only from its own serial queue.
/// Parameter changes from the interface are hopped onto that queue rather than
/// locked, so there is no shared mutable state to get wrong.
final class Transport {
    private let queue = DispatchQueue(label: "meter.transport", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    private let synth: DrumSynth
    private let midi: MIDIOut
    private let director: Director
    private let composer: Composer

    /// Published back to the interface on the main queue.
    var onMeasure: ((Measure, DirectorTick) -> Void)?
    var onStep: ((Int, Int) -> Void)?          // step, measure index

    private(set) var isRunning = false

    // Mirrored parameters, owned by the queue.
    /// The tempo the clock is running at, and the one it is heading for.
    ///
    /// Nothing writes a tempo straight onto the clock any more. A host that
    /// follows a pulse hands over a new figure every few seconds and the
    /// director hands one over at a section, and both used to land as a step:
    /// the timer was cancelled and re-armed from *now*, which threw away
    /// whatever was left of the tick in progress and pushed the whole grid
    /// after it later by up to a tick. Once every few seconds, against an echo
    /// running at a fixed time, that reads as the beat jostling. So the tempo
    /// glides toward the target on the clock's own thread, and every re-arm is
    /// measured from the last tick rather than from the moment somebody asked.
    private var bpm: Double = 112
    private var targetBpm: Double = 112
    /// Seconds for the glide to close about two thirds of the distance. Long
    /// enough to read as the music changing its mind rather than as an edit,
    /// short enough that a slider still feels connected to something.
    private static let glideTau: Double = 1.0
    /// The slowest the glide is allowed to crawl, in bpm per second, so the
    /// last fraction of a beat does not take all evening.
    private static let glideFloor: Double = 0.06
    /// Where the last tick belonged on the grid — not when its handler
    /// happened to run — and the interval the source is armed with.
    private var tickAnchor: DispatchTime = .now()
    private var armedInterval: Double = 0

    /// Clock diagnostics, kept only when someone is watching (`METER_DEBUG`).
    ///
    /// A stumble on a phone is a few milliseconds in a queue nobody can see, so
    /// the clock keeps its own record: how late each tick's handler ran, how
    /// often the grid fell far enough behind to be given up on, and how often
    /// the glide re-armed the source.
    private let watching = AudioOutput.verbose
    private var lateMax: Double = 0
    private var lateSum: Double = 0
    private var lateCount = 0
    private var resets = 0
    private var rearms = 0
    private var lastReport: DispatchTime = .now()
    private var timerResumed = false
    private var budget: Int = 14
    private var route: Route = .synth
    private var kit: [DrumVoice: LaneSettings] = [:]
    private var enabled: Set<DrumVoice> = Set(DrumVoice.allCases)

    private var measure = Measure()
    private var measureIndex = 0
    private var tickInMeasure = 0
    private var absTick = 0
    /// Second attacks and note-offs, keyed by absolute tick so they survive a
    /// measure boundary.
    private var pendingFlams: [(at: Int, hit: Hit)] = []
    private var pendingOffs: [(at: Int, note: Int)] = []

    init(synth: DrumSynth, midi: MIDIOut, director: Director, composer: Composer) {
        self.synth = synth
        self.midi = midi
        self.director = director
        self.composer = composer
        for v in DrumVoice.allCases { kit[v] = .default(for: v) }
    }

    // MARK: - Parameters

    /// Head for a tempo. `glide` off arrives at once, for the cases where
    /// there is nothing to glide from — loading a document, or a machine that
    /// has not started yet.
    func set(bpm value: Double, glide: Bool = true) {
        queue.async {
            self.targetBpm = min(240, max(30, value))
            guard !glide || !self.isRunning else { return }
            self.bpm = self.targetBpm
            if self.isRunning { self.arm() }
        }
    }


    func set(budget value: Int) { queue.async { self.budget = max(0, min(256, value)) } }
    func set(route value: Route) {
        queue.async {
            if value == .synth { self.allNotesOff() }
            self.route = value
        }
    }
    func set(kit value: [DrumVoice: LaneSettings]) {
        queue.async {
            self.kit = value
            self.enabled = Set(value.filter { !$0.value.muted }.keys)
            self.director.enabled = self.enabled
        }
    }
    /// Change the meter, either keeping what the lanes were playing or throwing
    /// it away.
    ///
    /// `keepFigure` is the difference between a meter change that sounds like the
    /// same music in a differently-shaped bar and one that sounds like a new
    /// section: without it every lane re-rolls on the same downbeat. The current
    /// bar always plays out to its end either way — `beginMeasure` composes at the
    /// downbeat and `tick` counts against the measure's own signature, so nothing
    /// here can cut a bar short.
    func set(signature: Signature, keepFigure: Bool = false) {
        queue.async {
            let old = self.composer.signature
            self.composer.signature = signature
            if keepFigure {
                self.composer.remap(from: old, to: signature)
            } else {
                self.composer.reset()
            }
        }
    }

    /// Whether the lanes phase against the bar. See `MeterMotion.rotate`.
    func set(rotates: Bool) { queue.async { self.composer.rotates = rotates } }
    /// Everything else the composer owns, in one hop.
    ///
    /// Written straight through. The director briefly drifted these by a factor
    /// — swing, humanize, how much of last measure survives — and that is the
    /// one kind of change this machine should not make on its own: it is the
    /// difference between an instrument that evolves and one whose timing you
    /// cannot trust.
    func setFeel(swing: Double, humanize: Double, persistence: Double,
                 accent: Double, flam: Double) {
        queue.async {
            self.composer.swing = swing
            self.composer.humanize = humanize
            self.composer.persistence = persistence
            self.composer.accent = accent
            self.composer.flamAmount = flam
        }
    }

    func setDirector(motion: Double, spread: Double, evolvePatches: Bool) {
        queue.async {
            self.director.motion = motion
            self.director.spread = spread
            self.director.evolvePatches = evolvePatches
        }
    }

    func nudge() { queue.async { self.director.nudge() } }
    func reseed() {
        queue.async {
            self.director.reseedShares()
            self.composer.reset()
        }
    }

    /// Play one lane once, for auditioning a patch.
    func audition(_ voice: DrumVoice) {
        queue.async {
            let hit = Hit(voice: voice, step: 0, tick: 0, velocity: 0.92, flam: false)
            self.play(hit, at: self.absTick)
        }
    }

    /// Compose one measure without starting the clock, so the window opens on a
    /// real allocation rather than on an empty grid.
    func prime() {
        queue.async {
            guard !self.isRunning else { return }
            self.beginMeasure()
            self.measureIndex = 0
        }
    }

    // MARK: - Transport

    func start() {
        queue.async {
            guard !self.isRunning else { return }
            self.isRunning = true
            self.tickInMeasure = 0
            self.absTick = 0
            self.pendingFlams.removeAll()
            self.pendingOffs.removeAll()
            self.midi.start()
            self.bpm = self.targetBpm
            self.arm(resettingPhase: true)
        }
    }

    func stop() {
        queue.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.cancelTimer()
            self.midi.stop()
            self.allNotesOff()
            self.synth.silence()
        }
    }

    /// Called on the way out, synchronously, so an external instrument is never
    /// left holding a note because the app got to exit first.
    func shutdown() {
        queue.sync {
            self.isRunning = false
            self.cancelTimer()
            self.midi.stop()
            self.allNotesOff()
        }
    }

    private var tickSeconds: Double { 60.0 / bpm / Double(ticksPerQuarter) }

    /// When this tick should be *heard*: where it belongs on the grid, plus the
    /// lead the graph needs to place it on a sample rather than on whichever
    /// buffer boundary noticed it. Both routes are told the same moment, so an
    /// external instrument and the rack stay together whatever the output
    /// latency happens to be.
    private var moment: Double { Self.seconds(of: tickAnchor) + synth.scheduleLead }

    /// One step of the tempo glide, run on the clock itself so it moves with
    /// the music rather than with whatever rate the interface publishes at.
    ///
    /// Exponential, with a floor: a tempo that has somewhere to go covers most
    /// of the distance in a second or so and then eases in, which is what a
    /// tempo change sounds like when a person makes one.
    private func glideTempo(over elapsed: Double) {
        guard bpm != targetBpm else { return }
        let distance = targetBpm - bpm
        if abs(distance) < 0.01 {
            bpm = targetBpm
        } else {
            let eased = distance * min(1, elapsed / Self.glideTau)
            let crawl = Self.glideFloor * elapsed * (distance < 0 ? -1 : 1)
            bpm += abs(eased) > abs(crawl) ? eased : crawl
            // Never step past the target, however coarse the tick.
            if (targetBpm - bpm) * distance < 0 { bpm = targetBpm }
        }
        // Re-arming the source is a system call, so it happens when the glide
        // has moved the interval by a fifth of a percent rather than on every
        // tick. Below that the difference is a couple of microseconds.
        guard armedInterval > 0,
              abs(tickSeconds - armedInterval) / armedInterval > 0.002 else { return }
        arm()
    }

    /// Point the clock at its next tick.
    ///
    /// A repeating source rather than one shot per tick: dispatch schedules the
    /// repeats from the original deadline, so it does not accumulate drift, and
    /// at 96 PPQN a fresh source every five milliseconds would be pure
    /// overhead. The source is made once and re-armed in place, and the
    /// deadline comes off the grid rather than off `.now()` — which is the
    /// whole difference between a tempo change and a stumble. Re-arming from
    /// now restarts the tick that was already part-way through, so every tempo
    /// change nudged the grid later by whatever was left of it; re-arming from
    /// the moment the handler *ran* is just as wrong the other way, since a
    /// glide re-arms dozens of times a second and each one would fold its own
    /// scheduling latency in for good.
    private func arm(resettingPhase: Bool = false) {
        if watching && isRunning && !resettingPhase { rearms += 1 }
        let interval = tickSeconds
        armedInterval = interval
        let source: DispatchSourceTimer
        if let existing = timer {
            source = existing
        } else {
            let fresh = DispatchSource.makeTimerSource(queue: queue)
            fresh.setEventHandler { [weak self] in self?.tick() }
            timer = fresh
            source = fresh
        }
        let now = DispatchTime.now()
        if resettingPhase { tickAnchor = now }
        // A shortened interval can put the next tick in the past. That tick is
        // simply due, so it goes out now rather than being skipped.
        let deadline = max(tickAnchor + interval, now)
        source.schedule(deadline: deadline, repeating: interval,
                        leeway: .nanoseconds(200_000))
        if !timerResumed {
            timerResumed = true
            source.resume()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        timerResumed = false
        armedInterval = 0
    }

    private func tick() {
        guard isRunning else { return }
        let firedAt = DispatchTime.now()
        // Where this tick belonged, rather than when its handler got to run.
        tickAnchor = tickAnchor + armedInterval
        if watching { record(late: Self.seconds(from: tickAnchor, to: firedAt)) }
        // If the grid has fallen a long way behind — the app suspended, the
        // queue stalled — there is nothing to be gained by playing the ticks
        // that were missed, so it starts again from here.
        if tickAnchor + 0.25 < DispatchTime.now() {
            if watching {
                resets += 1
                AudioOutput.note(String(format: "clock: grid %.0f ms behind, re-anchoring",
                                        Self.seconds(from: tickAnchor, to: .now()) * 1000))
            }
            tickAnchor = .now()
        }
        glideTempo(over: armedInterval)

        if tickInMeasure == 0 { beginMeasure() }

        // MIDI beat clock: 24 PPQN out of our 96.
        if absTick % 4 == 0 { midi.clockTick(at: moment) }

        // Anything scheduled for this exact tick, in the order it was queued.
        while let i = pendingFlams.firstIndex(where: { $0.at <= absTick }) {
            let item = pendingFlams.remove(at: i)
            play(item.hit, at: absTick)
        }
        while let i = pendingOffs.firstIndex(where: { $0.at <= absTick }) {
            let item = pendingOffs.remove(at: i)
            midi.noteOff(item.note, at: moment)
        }

        for hit in measure.hits where hit.tick == tickInMeasure {
            play(hit, at: absTick)
            if hit.flam {
                // The second attack of a flam: four ticks later, softer and a
                // touch brighter, which is what makes it read as one gesture
                // with a stutter rather than as two hits.
                var second = hit
                second.flam = false
                second.velocity = hit.velocity * 0.72
                pendingFlams.append((at: absTick + 4, hit: second))
            }
        }

        let per = measure.signature.ticksPerStep
        if tickInMeasure % per == 0 {
            let step = tickInMeasure / per
            let index = measureIndex
            DispatchQueue.main.async { self.onStep?(step, index) }
        }

        absTick += 1
        tickInMeasure += 1
        if tickInMeasure >= measure.signature.ticks { tickInMeasure = 0 }
    }

    /// The whole measure is composed at its downbeat: the director moves, then
    /// the composer spends the new distribution. Composing a measure ahead would
    /// let a flam on step zero start before the bar does, which is not worth the
    /// bookkeeping — a flam that delays its second attack sounds the same.
    private func beginMeasure() {
        let tick = director.advance()
        measure = composer.compose(index: measureIndex, budget: budget,
                                   tick: tick, enabled: enabled)
        let published = measure
        DispatchQueue.main.async { self.onMeasure?(published, tick) }
        measureIndex += 1
    }

    // MARK: - Playing one hit

    private func play(_ hit: Hit, at absTick: Int) {
        guard let lane = kit[hit.voice], !lane.muted else { return }
        let when = moment
        if route != .midi {
            synth.triggers.push(Trigger(at: when, voice: hit.voice, lane: lane,
                                        velocity: hit.velocity))
        }
        if route != .synth {
            midi.noteOn(lane.midiNote, velocity: hit.velocity, at: when)
            // Drum modules want a real gate, not a zero-length one. Thirty
            // milliseconds is long enough for every module to latch and short
            // enough never to overlap the next step.
            let gate = max(2, Int((0.03 / tickSeconds).rounded()))
            pendingOffs.append((at: absTick + gate, note: lane.midiNote))
        }
    }

    /// Seconds between two dispatch times, signed. `DispatchTime` subtraction
    /// is unsigned and would wrap on a tick that ran early.
    private static func seconds(from a: DispatchTime, to b: DispatchTime) -> Double {
        (Double(b.uptimeNanoseconds) - Double(a.uptimeNanoseconds)) / 1e9
    }

    /// Mach uptime seconds, the clock the engine timestamps its buffers with.
    private static func seconds(of t: DispatchTime) -> Double {
        Double(t.uptimeNanoseconds) / 1e9
    }

    /// Roll one tick's lateness into the running figures, and report once a
    /// second. Reporting per tick would itself be the stall it is looking for.
    private func record(late: Double) {
        lateMax = max(lateMax, late)
        lateSum += late
        lateCount += 1
        guard Self.seconds(from: lastReport, to: .now()) >= 1 else { return }
        lastReport = .now()
        AudioOutput.note(String(format:
            "clock: %d ticks, late mean %.2f ms max %.2f ms, %d re-arms, %d re-anchors, %.2f→%.2f bpm",
            lateCount, lateSum / Double(max(1, lateCount)) * 1000, lateMax * 1000,
            rearms, resets, bpm, targetBpm))
        let v = synth.takePlacement()
        AudioOutput.note(String(format:
            "voices: %d starts, placement mean %.3f ms max %.3f ms, %d missed, lead %.1f ms, %d contended drains",
            v.count, v.mean * 1000, v.max * 1000, v.missed, v.lead * 1000, v.skipped))
        lateMax = 0; lateSum = 0; lateCount = 0; rearms = 0; resets = 0
    }

    private func allNotesOff() {
        for (_, lane) in kit { midi.noteOff(lane.midiNote) }
        midi.allNotesOff()
        pendingOffs.removeAll()
    }

}
