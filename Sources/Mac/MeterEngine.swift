import AppKit
import CoreMIDI
import Foundation
import SwiftUI

/// Top-level state: owns the rack, the clock, MIDI out and the director, and
/// republishes what they are doing for SwiftUI.
///
/// The user owns two numbers — tempo and budget — and the machine owns
/// everything else. That split is deliberate: those two are the ones you
/// actually want your hands on while it plays, and every other decision is more
/// interesting when something else is making it.
/// How the machine ships. Kept in one place so that the properties below and
/// `factoryReset()` cannot drift apart — the usual way a reset button ends up
/// restoring values that were the defaults two versions ago.
enum Factory {
    static let bpm = 112.0
    static let budget = 14.0
    static let signature = "4/4"
    static let swing = 0.12
    static let humanize = 0.35
    static let drift = 0.28
    static let accent = 0.70
    static let flam = 0.12
    static let motion = 0.50
    static let spread = 0.50
    static let evolvePatches = true
    static let route = Route.synth
    static let midiChannel = 10
    static let sendsClock = false
    static let volume = 0.85
    static let reverb = 14.0
    static let echo = 0.0
}

@MainActor
final class MeterEngine: ObservableObject {
    // Transport
    @Published var running = false { didSet { running ? transport.start() : transport.stop() } }
    @Published var bpm: Double = Factory.bpm {
        didSet {
            transport.set(bpm: bpm)
            syncDelay()
            // A hand on the slider re-centres Flow rather than fighting it.
            if flowing && !flowIsWriting { flow.reanchor(tempo: bpm) }
            save()
        }
    }
    /// Attacks per measure. The whole program in one number.
    @Published var budget: Double = Factory.budget {
        didSet {
            transport.set(budget: Int(budget))
            if flowing && !flowIsWriting { flow.reanchor(budget: budget) }
            save()
        }
    }
    @Published var signatureName: String = Factory.signature {
        didSet { transport.set(signature: Signature.named(signatureName)); save() }
    }

    // Feel
    @Published var swing: Double = Factory.swing { didSet { syncFeel(); save() } }
    @Published var humanize: Double = Factory.humanize { didSet { syncFeel(); save() } }
    /// How much of last measure a lane throws away. The inverse of what the
    /// composer holds on to — "drift" is the knob you want to reach for.
    @Published var drift: Double = Factory.drift { didSet { syncFeel(); save() } }
    @Published var accent: Double = Factory.accent { didSet { syncFeel(); save() } }
    @Published var flam: Double = Factory.flam { didSet { syncFeel(); save() } }

    // Director
    @Published var motion: Double = Factory.motion { didSet { syncDirector(); save() } }
    @Published var spread: Double = Factory.spread { didSet { syncDirector(); save() } }
    @Published var evolvePatches = Factory.evolvePatches { didSet { syncDirector(); save() } }

    /// Flow — the machine playing itself, including the two numbers that were
    /// always yours. Off, tempo and budget are exactly where you left them.
    @Published var flowing = false {
        didSet {
            if flowing {
                flow.start(tempo: bpm, budget: budget)
                activity.insert("flow began", at: 0)
            } else {
                flow.stop()
                activity.insert("flow ended", at: 0)
            }
            save()
        }
    }

    // Rack and output
    @Published var kit: [DrumVoice: LaneSettings] = [:] {
        didSet {
            transport.set(kit: kit)
            // Pan is a position in the room now, not a gain pair, so it is the
            // graph that has to be told rather than the next trigger.
            audio.place(kit)
        }
    }
    @Published var route: Route = Factory.route { didSet { transport.set(route: route); save() } }
    @Published var midiChannel: Int = Factory.midiChannel { didSet { midi.channel = UInt8(max(1, min(16, midiChannel)) - 1); save() } }
    @Published var sendsClock = Factory.sendsClock { didSet { midi.sendsClock = sendsClock; save() } }
    @Published var destinations: [MIDIDestinationInfo] = []
    @Published var selectedDestination: MIDIUniqueID?
    @Published var volume: Double = Factory.volume { didSet { audio.synth.masterVolume = Float(volume); save() } }
    @Published var reverb: Double = Factory.reverb { didSet { audio.reverbMix = Float(reverb); save() } }
    @Published var echo: Double = Factory.echo { didSet { syncDelay(); save() } }

    // What the machine is doing
    @Published var measure = Measure()
    @Published var measureIndex = 0
    /// The playhead, and separately the level and hit lamps. Both are kept off
    /// this object so that many updates a second do not re-lay-out the window.
    let pulse = Pulse()
    let levels = Levels()
    @Published var shares: [DrumVoice: Double] = [:]
    @Published var temperature: Double = 0.35
    /// Recent director decisions, newest first. Showing them is not decoration:
    /// a machine that reallocates silently is indistinguishable from one that is
    /// broken.
    @Published var activity: [String] = []
    /// The lane whose module is showing in the rack panel.
    @Published var selectedLane: DrumVoice = .bass

    private let audio = AudioOutput()
    private let midi = MIDIOut()
    private let director = Director()
    private let composer = Composer()
    private let transport: Transport
    private let flow = FlowDirector()
    /// Set while Flow is writing tempo or budget, so the `didSet` on those
    /// properties can tell its own change from the player reaching for a slider.
    private var flowIsWriting = false
    private var meterTimer: Timer?

    private let defaults = UserDefaults.standard
    /// save() writes every key at once, so while load() assigns properties one
    /// by one it has to stay quiet — otherwise setting the first one writes the
    /// defaults back over everything still unread.
    private var isLoading = false

    init() {
        transport = Transport(synth: audio.synth, midi: midi,
                              director: director, composer: composer)
        for v in DrumVoice.allCases { kit[v] = .default(for: v) }

        transport.onMeasure = { [weak self] measure, tick in
            MainActor.assumeIsolated { self?.apply(measure, tick) }
        }
        transport.onStep = { [weak self] step, index in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pulse.step = step
                if self.measureIndex != index { self.measureIndex = index }
            }
        }
        midi.onDestinationsChanged = { [weak self] in
            MainActor.assumeIsolated { self?.refreshDestinations() }
        }

        load()
        sync()
        audio.start()
        refreshDestinations()
        transport.prime()

        // 20 Hz is enough for a level meter and a hit flash, and cheap enough
        // that the interface never competes with the audio thread.
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let peak = self.audio.synth.peak
                if peak != self.levels.peak { self.levels.peak = peak }
                // Only republish the lamps when they actually differ, so a
                // stopped machine redraws nothing at all.
                let glow = self.audio.synth.laneEnergy
                if glow != self.levels.glow { self.levels.glow = glow }
            }
        }

        // Never leave an external instrument holding a note.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.transport.shutdown() }
        }
    }

    // MARK: - What came back from the machine

    private func apply(_ measure: Measure, _ tick: DirectorTick) {
        self.measure = measure
        shares = tick.shares
        temperature = tick.temperature
        applyFlow()


        // The director's own edits to the rack. Applying them here, on the main
        // thread, is what lets the interface show the knobs moving on their own.
        var changed = false
        for move in tick.macroMoves {
            guard var lane = kit[move.voice] else { continue }
            switch move.macro {
            case .tone:  lane.tone = move.value
            case .fold:  lane.fold = move.value
            case .grit:  lane.grit = move.value
            case .decay: lane.decay = move.value
            // Pan is a position in the room, so the graph has to be told as
            // well as the model — see `place`.
            case .pan:   lane.pan = move.value
            }
            kit[move.voice] = lane
            changed = true
        }
        for repatch in tick.repatches {
            guard var lane = kit[repatch.voice] else { continue }
            lane.patchName = repatch.patch
            kit[repatch.voice] = lane
            changed = true
        }
        if changed { transport.set(kit: kit) }

        if !tick.notes.isEmpty {
            activity = (tick.notes.map { "\(measure.index + 1) · \($0)" } + activity).prefix(9).map { $0 }
        }
    }

    /// One measure of Flow, if it is running.
    private func applyFlow() {
        guard flowing else { return }
        let move = flow.advance()
        flowIsWriting = true
        if let tempo = move.tempo { bpm = tempo }
        if let budget = move.budget { self.budget = budget }
        if let signature = move.signature, signature != signatureName {
            signatureName = signature
        }
        flowIsWriting = false
        if !move.notes.isEmpty {
            activity = (move.notes + activity).prefix(9).map { $0 }
        }
    }

    // MARK: - Player actions

    func toggleTransport() { running.toggle() }
    func nudge() { transport.nudge() }
    func reseed() { transport.reseed() }
    func audition(_ voice: DrumVoice) { transport.audition(voice) }

    func setPatch(_ name: String, for voice: DrumVoice) {
        guard var lane = kit[voice] else { return }
        lane.patchName = name
        kit[voice] = lane
        transport.set(kit: kit)
        saveKit()
        audition(voice)
    }

    func update(_ voice: DrumVoice, _ change: (inout LaneSettings) -> Void) {
        guard var lane = kit[voice] else { return }
        change(&lane)
        kit[voice] = lane
        transport.set(kit: kit)
        saveKit()
    }

    /// Repatch every lane at once. The most modular thing in the app: a whole
    /// new rack, same budget, same groove shape.
    func randomizeKit() {
        var rng = Rng(seed: Rng.freshSeed())
        for voice in DrumVoice.allCases {
            guard var lane = kit[voice] else { continue }
            // Bias each lane toward patches that sit in its register, so a
            // random rack is still a kit and not nine cymbals.
            let candidates = Patch.bank.filter { patch in
                let bright = patch.baseHz > 240 || patch.metalLevel > 0.3 || patch.filterMode == .highpass
                return voice.register > 0.6 ? bright : !bright || rng.chance(0.25)
            }
            lane.patchName = (candidates.isEmpty ? Patch.bank : candidates).randomPick(&rng).name
            lane.tone = rng.range(0.85, 1.2)
            lane.fold = rng.range(0.6, 1.4)
            lane.grit = rng.range(0.6, 1.3)
            lane.decay = rng.range(0.8, 1.25)
            kit[voice] = lane
        }
        transport.set(kit: kit)
        saveKit()
    }

    /// Back to how it shipped: every control, the whole rack, the allocation,
    /// and the stored state behind them.
    ///
    /// `isLoading` is borrowed here for the reason it exists — each property's
    /// `didSet` writes the whole settings block, so assigning seventeen of them
    /// one at a time would persist sixteen half-finished states on the way.
    func factoryReset() {
        isLoading = true
        bpm = Factory.bpm
        budget = Factory.budget
        signatureName = Factory.signature
        swing = Factory.swing
        humanize = Factory.humanize
        drift = Factory.drift
        accent = Factory.accent
        flam = Factory.flam
        motion = Factory.motion
        spread = Factory.spread
        evolvePatches = Factory.evolvePatches
        flowing = false
        route = Factory.route
        midiChannel = Factory.midiChannel
        sendsClock = Factory.sendsClock
        volume = Factory.volume
        reverb = Factory.reverb
        echo = Factory.echo
        for voice in DrumVoice.allCases { kit[voice] = .default(for: voice) }
        selectedLane = .bass
        isLoading = false

        for key in Key.all { defaults.removeObject(forKey: key) }
        select(destination: nil)
        sync()
        transport.set(kit: kit)
        transport.reseed()
        activity.removeAll()
        save()
        saveKit()
    }

    var destinationLabel: String {
        guard let uid = selectedDestination,
              let match = destinations.first(where: { $0.id == uid }) else { return "Meter Out" }
        return match.name
    }

    func refreshDestinations() {
        destinations = midi.destinations()
        if let selected = selectedDestination, !destinations.contains(where: { $0.id == selected }) {
            select(destination: nil)
        }
    }

    func select(destination uid: MIDIUniqueID?) {
        midi.select(uid)
        selectedDestination = uid
        // Choosing a destination means you want to hear it there.
        if uid != nil, route == .synth { route = .both }
        save()
    }

    // MARK: - Syncing

    private func syncFeel() {
        transport.setFeel(swing: swing, humanize: humanize,
                          persistence: 1 - drift, accent: accent, flam: flam)
    }

    private func syncDirector() {
        transport.setDirector(motion: motion, spread: spread, evolvePatches: evolvePatches)
    }

    /// Keep the echo musical, and let the director move it: the subdivision is
    /// whatever it has drifted to, and the depth scales what the player asked
    /// for. The room is not in here on purpose — that one stays put.
    /// Keep the echo musical: a dotted eighth at the current tempo, which is the
    /// delay that makes a sparse kit sound like a bigger one.
    ///
    /// The time is re-derived only when the tempo has actually moved a useful
    /// amount. A delay line asked to change length re-reads its buffer at a
    /// different rate and warbles, so nudging it on every small tempo change —
    /// which is what following a pulse produces — is audible as a fault.
    private func syncDelay() {
        audio.delayMix = Float(min(100, max(0, echo)))
        let target = min(2, (60.0 / max(30, bpm)) * 0.75)
        if abs(target - audio.delaySeconds) / max(0.05, audio.delaySeconds) > 0.06 {
            audio.delaySeconds = target
        }
    }

    /// Push every setting into the machine. `didSet` only fires for values that
    /// were actually stored, so without this the engine could quietly disagree
    /// with the interface after a load.
    private func sync() {
        transport.set(bpm: bpm)
        transport.set(budget: Int(budget))
        transport.set(signature: Signature.named(signatureName))
        transport.set(route: route)
        transport.set(kit: kit)
        audio.place(kit)
        syncFeel()
        syncDirector()
        syncDelay()
        midi.channel = UInt8(max(1, min(16, midiChannel)) - 1)
        midi.sendsClock = sendsClock
        audio.synth.masterVolume = Float(volume)
        audio.reverbMix = Float(reverb)
        syncDelay()
    }

    // MARK: - Persistence

    private enum Key {
        static let bpm = "bpm", budget = "budget", signature = "signature"
        static let swing = "swing", humanize = "humanize", drift = "drift"
        static let accent = "accent", flam = "flam"
        static let motion = "motion", spread = "spread", evolve = "evolvePatches"
        static let route = "route", channel = "midiChannel", clock = "sendsClock"
        static let destination = "destination"
        static let volume = "volume", reverb = "reverb", echo = "echo"
        static let kit = "kit"
        static let flowing = "flowing"

        static let all = [bpm, budget, signature, swing, humanize, drift, accent,
                          flam, motion, spread, evolve, route, channel, clock,
                          destination, volume, reverb, echo, kit, flowing]
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if defaults.object(forKey: Key.bpm) != nil {
            bpm = defaults.double(forKey: Key.bpm)
            budget = defaults.double(forKey: Key.budget)
            signatureName = defaults.string(forKey: Key.signature) ?? "4/4"
            swing = defaults.double(forKey: Key.swing)
            humanize = defaults.double(forKey: Key.humanize)
            drift = defaults.double(forKey: Key.drift)
            accent = defaults.double(forKey: Key.accent)
            flam = defaults.double(forKey: Key.flam)
            motion = defaults.double(forKey: Key.motion)
            spread = defaults.double(forKey: Key.spread)
            evolvePatches = defaults.bool(forKey: Key.evolve)
            volume = defaults.double(forKey: Key.volume)
            reverb = defaults.double(forKey: Key.reverb)
            echo = defaults.double(forKey: Key.echo)
            midiChannel = max(1, defaults.integer(forKey: Key.channel))
            sendsClock = defaults.bool(forKey: Key.clock)
            if let raw = defaults.string(forKey: Key.route), let r = Route(rawValue: raw) { route = r }
            flowing = defaults.bool(forKey: Key.flowing)
        }
        if let data = defaults.data(forKey: Key.kit),
           let stored = try? JSONDecoder().decode([String: LaneSettings].self, from: data) {
            for (raw, lane) in stored {
                guard let voice = DrumVoice(rawValue: raw) else { continue }
                // A patch name from an older build might no longer exist.
                var lane = lane
                if !Patch.bank.contains(where: { $0.name == lane.patchName }) {
                    lane.patchName = Patch.defaultPatch(for: voice).name
                }
                kit[voice] = lane
            }
        }
        let stored = defaults.integer(forKey: Key.destination)
        if stored != 0 {
            let uid = MIDIUniqueID(stored)
            if midi.destinations().contains(where: { $0.id == uid }) {
                midi.select(uid)
                selectedDestination = uid
            }
        }
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(bpm, forKey: Key.bpm)
        defaults.set(budget, forKey: Key.budget)
        defaults.set(signatureName, forKey: Key.signature)
        defaults.set(swing, forKey: Key.swing)
        defaults.set(humanize, forKey: Key.humanize)
        defaults.set(drift, forKey: Key.drift)
        defaults.set(accent, forKey: Key.accent)
        defaults.set(flam, forKey: Key.flam)
        defaults.set(motion, forKey: Key.motion)
        defaults.set(spread, forKey: Key.spread)
        defaults.set(evolvePatches, forKey: Key.evolve)
        defaults.set(route.rawValue, forKey: Key.route)
        defaults.set(flowing, forKey: Key.flowing)
        defaults.set(midiChannel, forKey: Key.channel)
        defaults.set(sendsClock, forKey: Key.clock)
        defaults.set(volume, forKey: Key.volume)
        defaults.set(reverb, forKey: Key.reverb)
        defaults.set(echo, forKey: Key.echo)
        defaults.set(Int(selectedDestination ?? 0), forKey: Key.destination)
    }

    /// The rack is saved separately, and only when the player changes it. The
    /// director's own slow drift is not persisted on purpose: a session should
    /// open on the kit you built, not on wherever twenty minutes of unattended
    /// drifting happened to leave it.
    private func saveKit() {
        guard !isLoading else { return }
        var raw: [String: LaneSettings] = [:]
        for (voice, lane) in kit { raw[voice.rawValue] = lane }
        if let data = try? JSONEncoder().encode(raw) { defaults.set(data, forKey: Key.kit) }
    }
}

private extension Array {
    func randomPick(_ rng: inout Rng) -> Element { self[rng.int(count)] }
}
