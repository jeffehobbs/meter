import AVFoundation
import Cadence
import os
import Combine
import MediaPlayer
import SwiftUI

/// Meter, playing itself.
///
/// The Mac app is an instrument: nine lanes, sixteen patches, a director you can
/// argue with. This is the same machine with nothing to operate — one knob for
/// how busy it is, and a tempo that would rather come from the listener's pulse
/// than from a slider. Everything else the director was already deciding on its
/// own, so on a phone it simply gets on with it.
///
/// The host owns the parts iOS needs that the Mac does not: an audio session
/// that survives the lock screen, transport controls that appear on it, and the
/// arithmetic of fading rather than stopping.
@MainActor
final class FlowHost: ObservableObject {
    /// One host, because the audio session is one thing. A second engine would
    /// fight this one over it.
    static let shared = FlowHost()

    enum Playback: String { case idle, paused, playing }

    @Published private(set) var playback: Playback = .idle
    @Published private(set) var measure = Measure()
    @Published private(set) var shares: [DrumVoice: Double] = [:]
    @Published private(set) var lastError: String?
    /// Where the sound is going: "AirPods Pro", "iPhone Speaker", a car. On a
    /// phone this is not a detail — a passive app playing into a Bluetooth
    /// speaker in another room is indistinguishable from a broken one, and the
    /// only way to tell is to say so.
    @Published private(set) var routeName: String = ""


    /// The one knob: attacks per measure. Narrower than the Mac's range on
    /// purpose — this is a thing to leave running, and sixty-four attacks a bar
    /// is not something to leave running.
    @Published var budget: Double = 12 {
        didSet { transport.set(budget: Int(budget)); updateNowPlaying(); save() }
    }

    /// Beats per minute. Written by the listener when they are driving, and by
    /// Cadence when they are not.
    @Published var tempo: Double = 96 {
        didSet { transport.set(bpm: tempo); updateNowPlaying() }
    }

    /// Whether the tempo follows the listener's pulse.
    @Published var followsPulse: Bool = true {
        didSet {
            if followsPulse {
                Task { await cadence.requestAuthorization() }
                if playback == .playing { cadence.start() }
                applyCadence()
            }
            updateNowPlaying()
            save()
        }
    }

    /// Minutes until it fades out on its own; zero means never.
    @Published var sleepMinutes: Int = 0 {
        didSet { armSleepTimer(); save() }
    }
    @Published private(set) var sleepRemaining: TimeInterval?

    /// Off while the screen is dark. The audio does not care, and the drawing
    /// should not happen at all.
    var isVisible = true

    let pulse = Pulse()
    let levels = Levels()
    let cadence = Cadence(name: "meter")

    private let audio: AudioOutput
    private let midi = MIDIOut()
    private let director = Director()
    private let composer = Composer()
    private let transport: Transport
    private var meterTimer: Timer?
    private var sleepTimer: Timer?
    private var fadeTimer: Timer?
    private var watches: Set<AnyCancellable> = []
    private let defaults = UserDefaults.standard
    /// Each setting's `didSet` persists the lot, so loading them one at a time
    /// has to stay quiet or the first one writes the defaults back over the rest.
    private var isLoading = false

    private init() {
        // The category, but *not* activation. Declaring the category is what
        // lets the engine read the right hardware sample rate; activating is
        // what takes the audio away from whatever else is playing, and an app
        // that has merely been opened has no business doing that. This was a
        // real bug: Meter silenced other apps from the moment it launched,
        // before anyone had asked it for a sound.
        Self.prepareSession()

        audio = AudioOutput()
        transport = Transport(synth: audio.synth, midi: midi,
                              director: director, composer: composer)

        load()

        // Settings the Mac exposes and this does not. These are the values the
        // machine sounds best left alone at: calm, wide, and roomier than the
        // desktop default, because nobody is listening critically to this.
        director.motion = 0.35
        director.spread = 0.55
        director.evolvePatches = true
        transport.setFeel(swing: 0.14, humanize: 0.42, persistence: 0.76,
                          accent: 0.75, flam: 0.08)
        transport.setDirector(motion: 0.35, spread: 0.55, evolvePatches: true)
        transport.set(signature: .named("4/4"))
        transport.set(budget: Int(budget))
        transport.set(bpm: tempo)
        transport.set(route: .synth)
        for voice in DrumVoice.allCases { kit[voice] = .default(for: voice) }
        transport.set(kit: kit)
        audio.place(kit)
        audio.reverbMix = 22
        audio.delayFeedback = 30
        syncEcho()

        transport.onMeasure = { [weak self] measure, tick in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.measure = measure
                self.shares = tick.shares
                self.applyDrift(tick)
                self.lastTick = tick
                self.history.append(MeasureSnapshot(
                    index: measure.index, spent: measure.spent, counts: measure.counts,
                    shares: tick.shares, temperature: tick.temperature, notes: tick.notes))
                if self.history.count > 24 { self.history.removeFirst(self.history.count - 24) }
            }
        }
        transport.onStep = { [weak self] step, _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.pulse.step = step
            }
        }
        transport.prime()


        // Cadence publishes about once every five seconds; the tempo it hands
        // over is already slew-limited, so this can be taken as read.
        cadence.$estimate
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.applyCadence() }
            }
            .store(in: &watches)

        configureRemoteCommands()
        watchSession()
        updateRoute()
        updateNowPlaying()

        // A way to see the thing running without a finger: the simulator has no
        // tap API, so verifying that a build actually plays means either poking
        // at a window or this.
        if ProcessInfo.processInfo.environment["METER_CYCLE"] != nil {
            // Play, pause, play — the sequence that a person performs with two
            // taps and that no simulator can. Each step says what it measured,
            // so a resume that renders into nothing is visible from a Mac.
            let steps: [(Double, String)] = [(0.6, "play"), (6, "pause"), (9, "play again"),
                                             (14, "report"), (20, "report")]
            for (delay, what) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch what {
                        case "play", "play again": self.play()
                        case "pause": self.pause()
                        default: break
                        }
                        self.diagnose(what)
                    }
                }
            }
        } else if ProcessInfo.processInfo.environment["METER_AUTOPLAY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.play() }
            }
        }
    }

    // MARK: - Session

    private static let log = Logger(subsystem: "com.jeffhobbs.meter", category: "host")

    /// Declare what kind of audio this is. Safe at any time: it changes nothing
    /// for anyone else until the session is made active.
    private static func prepareSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        } catch {
            AudioOutput.note("session category failed — \(error.localizedDescription)")
        }
    }

    /// Take the audio. Called when playback actually starts, and again on the
    /// way back from an interruption — the category as well as the activation,
    /// and that is not belt and braces: a session can come back from an
    /// interruption or a media-services reset with a category that is no longer
    /// ours, and `setActive` on one of those is exactly the throw that turns a
    /// play button into a button that does nothing.
    @discardableResult
    private static func activateSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let route = session.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
            AudioOutput.note("session active — \(session.sampleRate)Hz, out \(route), vol \(session.outputVolume), others \(session.isOtherAudioPlaying)")
            return true
        } catch {
            // Usually somebody else will not be interrupted — a call, or another
            // app that asked not to be. Starting the engine anyway is the worst
            // of both worlds: silent, and holding the transport in a state that
            // says it is playing.
            AudioOutput.note("session FAILED — \(error.localizedDescription)")
            return false
        }
    }

    /// Give it back. `.notifyOthersOnDeactivation` is what lets whatever was
    /// playing before resume where it left off, and without it a paused Meter
    /// leaves the phone silent for everyone.
    private static func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            AudioOutput.note("session release failed — \(error.localizedDescription)")
        }
    }

    /// The failures that are not the app's fault: a phone call, a media-services
    /// reset, a pair of headphones arriving. Each of them can leave the engine
    /// stopped or the session pointed at somebody else's category, and none of
    /// them announce themselves as anything a play button would notice.
    private func watchSession() {
        let session = AVAudioSession.sharedInstance()
        let centre = NotificationCenter.default

        centre.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                switch type {
                case .began:
                    if self.playback == .playing {
                        self.interrupted = true
                        self.pause()
                    }
                case .ended:
                    let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                    // Only resume if the system says the interruption is over
                    // *and* it was the interruption that stopped us — otherwise
                    // a phone call would start a machine the listener had paused
                    // themselves.
                    if options.contains(.shouldResume) && self.interrupted { self.resume() }
                    self.interrupted = false
                @unknown default: break
                }
            }
        }

        centre.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                           object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        }
        centre.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateRoute()
                self?.recover()
            }
        }
    }

    private var interrupted = false
    /// Meter ticks during which the rack was making sound and the mixer was not.
    private var silentTicks = 0

    /// Write down everything the machine is doing, and what it has just been
    /// doing. Triggered by a triple tap; pulled off with `./build.sh log`.
    func logMoment() {
        var out = ""
        func line(_ text: String) { out += text + "\n" }

        let beat = 60.0 / max(30, tempo)
        line(String(format: "tempo %.0f bpm (%@)   budget %d   4/4   %@",
                    tempo, tempoSource, Int(budget), playback.rawValue))
        line(String(format: "out %@   level %.2f", routeName.isEmpty ? "—" : routeName, levels.output))
        line(String(format: "pulse %.0f bpm (%@, confidence %.2f)",
                    cadence.estimate.heartRate, cadence.estimate.source.label,
                    cadence.estimate.confidence))
        line("")
        line(String(format: "ECHO   %.0f%% wet  ·  %.0f ms  ·  feedback 30%%  (fixed)",
                    Double(Self.echoAmount), audio.delaySeconds * 1000))
        line(String(format: "ROOM   %.0f%% (fixed — never drifts)", 22.0))
        line(String(format: "SHAPE  placement %.2f (%@)", lastTick.temperature,
                    lastTick.temperature > 0.45 ? "off the beat" : "on the beat"))
        line("")

        // The part that says which parameters belong to which drum.
        line("lane      patch     tone  fold  grit  decay   pan   level  share  hits  note")
        for voice in DrumVoice.laneOrder.reversed() {
            guard let lane = kit[voice] else { continue }
            let share = (lastTick.shares[voice] ?? 0) * 100
            let hits = measure.counts[voice] ?? 0
            line(String(format: "%-9@ %-9@ %5.2f %5.2f %5.2f %6.2f %+5.2f %6.2f %5.1f%% %5d  %3d%@",
                        voice.label as NSString, lane.patchName as NSString,
                        lane.tone, lane.fold, lane.grit, lane.decay, lane.pan, lane.level,
                        share, hits, lane.midiNote, lane.muted ? "  MUTED" : ""))
        }
        line("")
        line("last measures (newest last):")
        for snapshot in history.suffix(12) { line(snapshot.line) }

        MomentLog.shared.write(out)
    }

    /// Everything worth knowing when the phone is silent, in one line: what the
    /// rack made, what left the mixer, where the session thinks it is going, and
    /// whether the engine's idea of the hardware still matches the session's.
    func diagnose(_ note: String) {
        audio.diagnose(note)
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        AudioOutput.note("\(note): route \(route), session \(session.sampleRate)Hz vol \(session.outputVolume), others \(session.isOtherAudioPlaying), engineOut \(audio.hardwareFormat)")
    }

    /// The friendly name of the current output, or the port type when there
    /// isn't one.
    func updateRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let first = outputs.first else { routeName = ""; return }
        let name = first.portName
        routeName = name.isEmpty ? first.portType.rawValue : name
    }

    private func recover() {
        guard playback == .playing, !audio.isRunning else { return }
        Self.activateSession()
        audio.restart()
    }

    // MARK: - Transport

    func toggle() { playback == .playing ? pause() : play() }

    func play() {
        switch playback {
        case .playing: return
        case .paused:  resume()
        case .idle:    start()
        }
    }

    /// One retry, half a second later. A refusal is usually momentary — the tail
    /// of somebody else's audio, a call ending — and asking twice is the
    /// difference between a play button that works and one that has to be
    /// pressed again for no visible reason.
    private func retryStartShortly() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.playback != .playing else { return }
                AudioOutput.note("retrying after a refused session")
                self.playback = .idle
                self.play()
            }
        }
    }

    private func start() {
        // Asked on the first play rather than at launch. A permission sheet is a
        // reasonable thing to meet when you have asked for music that follows
        // your pulse, and an unreasonable one to meet before you have asked for
        // anything at all.
        if followsPulse { Task { await cadence.requestAuthorization() } }
        guard Self.activateSession() else {
            lastError = "Another app is using the audio."
            retryStartShortly()
            return
        }
        lastError = nil
        fadeTimer?.invalidate()
        audio.outputVolume = 1
        // `restart()` rather than `start()` here too. A first play is usually a
        // fresh engine, but not always: the app may have been open for hours,
        // through a background pass and a route change or two, and an engine
        // that was stopped underneath us starts again perfectly and renders to
        // nobody.
        audio.restart()
        transport.start()
        playback = .playing
        cadence.start()
        armSleepTimer()
        startMeterTimer()
        updateRoute()
        updateNowPlaying()
        // Two seconds in, say whether anything is actually being rendered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                self?.diagnose("after start")
                self?.audio.dumpGraph()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                self?.diagnose("six seconds in")
            }
        }
    }

    private func resume() {
        // The category as well as the activation. A session can come back from
        // an interruption or a reset with somebody else's category, and
        // `setActive` on one of those is exactly the throw that turns a play
        // button into a button that does nothing.
        guard Self.activateSession() else {
            lastError = "Another app is using the audio."
            retryStartShortly()
            return
        }
        lastError = nil
        // A full restart rather than `start()` on a paused engine: the session
        // was deactivated while we were paused, which leaves the IO unit stale.
        audio.outputVolume = 0
        audio.restart()
        transport.start()
        playback = .playing
        cadence.start()
        armSleepTimer()
        startMeterTimer()
        fade(to: 1, over: 0.3)
        updateRoute()
        updateNowPlaying()
    }

    func pause() {
        guard playback == .playing else { return }
        playback = .paused
        // The clock stops with the sound rather than before it: freezing the
        // sequencer first would hold the last fifth of a second of hits
        // perfectly still while they faded.
        fade(to: 0, over: 0.2) { [weak self] in
            guard let self else { return }
            self.transport.stop()
            // A full stop rather than a pause: the session is about to be
            // released, and an engine left paused across that is precisely the
            // stale-IO limbo that made the next play silent.
            self.audio.stop()
            // After the engine has stopped, never before: releasing the session
            // while it is still rendering cuts the fade off at the knees.
            Self.deactivateSession()
        }
        cadence.stop()
        meterTimer?.invalidate()
        sleepTimer?.invalidate()
        sleepRemaining = nil
        updateNowPlaying()
    }

    private func fade(to target: Float, over duration: Double, then finish: (() -> Void)? = nil) {
        fadeTimer?.invalidate()
        let start = audio.outputVolume
        let began = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(began) / duration)
                self.audio.outputVolume = start + (target - start) * Float(t)
                if t >= 1 {
                    timer.invalidate()
                    self.fadeTimer = nil
                    finish?()
                }
            }
        }
    }

    /// Everything the interface animates, at fifteen a second rather than the
    /// Mac's twenty — the phone is in a pocket most of the time, and this is the
    /// only thing keeping the processor awake when it is not.
    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                let glow = self.audio.synth.laneEnergy
                if glow != self.levels.glow { self.levels.glow = glow }
                let peak = self.audio.synth.peak
                if peak != self.levels.peak { self.levels.peak = peak }
                let output = self.audio.outputPeak
                if output != self.levels.output { self.levels.output = output }
                // Self-heal. An engine that has stopped underneath a transport
                // that thinks it is playing is silent in a way nothing on screen
                // would otherwise show — and the causes (a media-services reset,
                // a route that came and went while backgrounded) do not always
                // arrive as a notification we heard.
                if self.playback == .playing && !self.audio.isRunning { self.recover() }
                // The subtler failure: an engine that says it is running while
                // nothing leaves it. If the rack is making samples and the mixer
                // is not, the graph is talking to a dead IO unit — restart it.
                if self.playback == .playing, self.audio.isRunning,
                   self.audio.synth.peak > 0.01, self.audio.outputPeak <= 0.0001 {
                    self.silentTicks += 1
                    if self.silentTicks > 30 {
                        self.silentTicks = 0
                        AudioOutput.note("rendering but silent — restarting the engine")
                        Self.activateSession()
                        self.audio.restart()
                    }
                } else {
                    self.silentTicks = 0
                }
                if let until = self.sleepUntil {
                    self.sleepRemaining = max(0, until.timeIntervalSinceNow)
                }
            }
        }
    }

    // MARK: - Cadence

    /// The rack, drifting. The phone has no rack panel, so this is the only
    /// place the director's slow changes to the lanes take effect.
    private var kit: [DrumVoice: LaneSettings] = [:]

    private func applyDrift(_ tick: DirectorTick) {
        var changed = false
        for move in tick.macroMoves {
            guard var lane = kit[move.voice] else { continue }
            switch move.macro {
            case .tone:  lane.tone = move.value
            case .fold:  lane.fold = move.value
            case .grit:  lane.grit = move.value
            case .decay: lane.decay = move.value
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
        if changed {
            transport.set(kit: kit)
            audio.place(kit)
        }
    }

    /// The last two dozen measures, for marked moments to look back through.
    private var history: [MeasureSnapshot] = []
    private var lastTick = DirectorTick()

    /// One echo for the kit, at a fixed amount, on a dotted eighth.
    ///
    /// Both of those used to drift, and the drift is what made the app's timing
    /// unreliable — an echo whose depth and subdivision are both moving is a
    /// second rhythm you did not ask for. The time is re-derived only when the
    /// tempo has moved a useful amount, because a delay line asked to change
    /// length mid-repeat warbles, and following a pulse changes the tempo every
    /// few seconds.
    private static let echoAmount: Float = 14

    private func syncEcho() {
        audio.delayMix = Self.echoAmount
        let target = min(2, (60.0 / max(30, tempo)) * 0.75)
        if abs(target - audio.delaySeconds) / max(0.05, audio.delaySeconds) > 0.06 {
            audio.delaySeconds = target
        }
    }

    private func applyCadence() {
        guard followsPulse else { return }
        let target = cadence.estimate.tempo
        guard target.isFinite, target > 30 else { return }
        if abs(target - tempo) > 0.05 { tempo = target }
        syncEcho()
    }

    /// What the tempo is currently being told by, for the one line of text on
    /// screen that explains itself.
    var tempoSource: String {
        guard followsPulse else { return "manual" }
        switch cadence.estimate.source {
        case .measured:     return "your pulse"
        case .extrapolated: return "your pulse"
        case .modeled:      return "estimated pulse"
        }
    }

    // MARK: - Sleep

    private var sleepUntil: Date?

    private func armSleepTimer() {
        sleepTimer?.invalidate()
        guard sleepMinutes > 0, playback == .playing else {
            sleepUntil = nil
            sleepRemaining = nil
            return
        }
        let until = Date().addingTimeInterval(Double(sleepMinutes) * 60)
        sleepUntil = until
        sleepRemaining = until.timeIntervalSinceNow
        sleepTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow,
                                          repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A long fade rather than a stop: the point of a sleep timer is
                // that nobody notices it happening.
                self.fade(to: 0, over: 12) {
                    self.transport.stop()
                    self.audio.stop()
                    Self.deactivateSession()
                    self.playback = .paused
                    self.cadence.stop()
                    self.updateNowPlaying()
                }
                self.sleepUntil = nil
                self.sleepRemaining = nil
            }
        }
    }

    // MARK: - Lock screen

    private func configureRemoteCommands() {
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.play() }
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.pause() }
            return .success
        }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            MainActor.assumeIsolated { self.toggle() }
            return .success
        }
        // Nothing to skip to and nowhere to scrub: an endless machine has no
        // next track, and leaving these enabled puts dead buttons on a lock
        // screen.
        for command in [centre.nextTrackCommand, centre.previousTrackCommand,
                        centre.changePlaybackPositionCommand, centre.seekForwardCommand,
                        centre.seekBackwardCommand] {
            command.isEnabled = false
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "\(Int(tempo.rounded())) BPM · \(Int(budget)) per bar",
            MPMediaItemPropertyArtist: followsPulse ? "Meter · following \(tempoSource)" : "Meter",
            // Endless by design, so no duration: without this the lock screen
            // draws a progress bar that can never move.
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: playback == .playing ? 1.0 : 0.0,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // The playback *state* is a separate property, and setting only the
        // dictionary is what leaves a lock screen showing a play triangle over
        // audible sound. `.paused` rather than `.stopped` when idle: stopped
        // means "finished", and a car or a lock screen reading that has nothing
        // to put its buttons on.
        MPNowPlayingInfoCenter.default().playbackState = playback == .playing ? .playing : .paused
    }

    private lazy var artwork: MPMediaItemArtwork? = {
        guard let image = UIImage(named: "NowPlayingArt") else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }()

    // MARK: - Scene

    func sceneBecameActive() {
        isVisible = true
        cadence.refreshAuthorizationIfNeeded()
    }

    func sceneWentBackground() {
        // Only the drawing stops. `UIBackgroundModes: audio` exists so the
        // machine survives the lock screen, which is when a thing you leave
        // running is most likely to be wanted.
        isVisible = false
    }

    // MARK: - Persistence

    private enum Key {
        static let budget = "flow.budget", tempo = "flow.tempo"
        static let follows = "flow.followsPulse", sleep = "flow.sleepMinutes"
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if defaults.object(forKey: Key.budget) != nil {
            budget = max(3, min(36, defaults.double(forKey: Key.budget)))
            tempo = max(40, min(200, defaults.double(forKey: Key.tempo)))
            followsPulse = defaults.bool(forKey: Key.follows)
            sleepMinutes = defaults.integer(forKey: Key.sleep)
        } else {
            followsPulse = true
        }
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(budget, forKey: Key.budget)
        defaults.set(tempo, forKey: Key.tempo)
        defaults.set(followsPulse, forKey: Key.follows)
        defaults.set(sleepMinutes, forKey: Key.sleep)
    }
}
