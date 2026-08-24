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
    private var bpm: Double = 112
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

    func set(bpm value: Double) {
        queue.async {
            self.bpm = min(240, max(30, value))
            if self.isRunning { self.restartTimer() }
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
            self.restartTimer()
        }
    }

    func stop() {
        queue.async {
            guard self.isRunning else { return }
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
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
            self.timer?.cancel()
            self.timer = nil
            self.midi.stop()
            self.allNotesOff()
        }
    }

    private var tickSeconds: Double { 60.0 / bpm / Double(ticksPerQuarter) }

    /// A repeating timer rather than one shot per tick: dispatch schedules a
    /// repeating source from its original deadline, so it does not accumulate
    /// drift, and at 96 PPQN a fresh source every five milliseconds would be
    /// pure overhead. Tempo changes cancel and re-arm, which costs less than a
    /// tick of phase.
    private func restartTimer() {
        timer?.cancel()
        let interval = tickSeconds
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval,
                   leeway: .nanoseconds(200_000))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        guard isRunning else { return }

        if tickInMeasure == 0 { beginMeasure() }

        // MIDI beat clock: 24 PPQN out of our 96.
        if absTick % 4 == 0 { midi.clockTick() }

        // Anything scheduled for this exact tick, in the order it was queued.
        while let i = pendingFlams.firstIndex(where: { $0.at <= absTick }) {
            let item = pendingFlams.remove(at: i)
            play(item.hit, at: absTick)
        }
        while let i = pendingOffs.firstIndex(where: { $0.at <= absTick }) {
            let item = pendingOffs.remove(at: i)
            midi.noteOff(item.note)
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
        if route != .midi {
            synth.triggers.push(Trigger(voice: hit.voice, lane: lane,
                                        velocity: hit.velocity))
        }
        if route != .synth {
            midi.noteOn(lane.midiNote, velocity: hit.velocity)
            // Drum modules want a real gate, not a zero-length one. Thirty
            // milliseconds is long enough for every module to latch and short
            // enough never to overlap the next step.
            let gate = max(2, Int((0.03 / tickSeconds).rounded()))
            pendingOffs.append((at: absTick + gate, note: lane.midiNote))
        }
    }

    private func allNotesOff() {
        for (_, lane) in kit { midi.noteOff(lane.midiNote) }
        midi.allNotesOff()
        pendingOffs.removeAll()
    }

}
