import AVFoundation
import os
import simd

/// The audio graph: nine lanes placed around the listener, into a short room and
/// a tempo-synced delay, then a real limiter.
///
/// Each lane gets its own mono bus and its own position in the field, and
/// `AVAudioEnvironmentNode` does the placing. On headphones — AirPods in
/// particular — that is a genuine binaural render, so the kit occupies a room
/// instead of a line between two speakers: the low lane centred and close, the
/// toms sweeping across, the bright lanes out to the sides and slightly up. On
/// speakers the same graph collapses to ordinary panning, because the rendering
/// algorithm is `.auto` and asking for HRTF into a loudspeaker is how a mix ends
/// up sounding thin and far away.
final class AudioOutput {
    /// Diagnostics for the failures that only happen on a device: a graph that
    /// measures perfectly offline and makes no sound in someone's ears.
    static let log = Logger(subsystem: "com.jeffhobbs.meter", category: "audio")

    /// Both, deliberately: the unified log needs an admin to stream off a
    /// device, and stdout is what `devicectl … --console` can actually read.
    static func note(_ text: String) {
        log.notice("\(text, privacy: .public)")
        // stdout as well, but only when someone is watching: it is what
        // `devicectl … --console` can read, and the unified log needs an admin
        // to stream off a device.
        if verbose { print("METER audio: " + text) }
    }

    static let verbose = ProcessInfo.processInfo.environment["METER_DEBUG"] != nil
        || ProcessInfo.processInfo.environment["METER_AUTOPLAY"] != nil
        || ProcessInfo.processInfo.environment["METER_CYCLE"] != nil
        || ProcessInfo.processInfo.environment["METER_TONE"] != nil
        || ProcessInfo.processInfo.environment["METER_PROBE"] != nil

    let synth = DrumSynth()
    /// Render cycles served, so "the callbacks never ran" and "the callbacks ran
    /// and the sound went nowhere" can be told apart from the outside.
    private(set) var cycles: Int = 0
    /// Peak of what actually leaves the graph, measured by a tap on the mixer.
    /// Distinct from `synth.peak`, which is what the kernel produced — the two
    /// disagreeing is the whole diagnosis when a graph goes quiet.
    private(set) var outputPeak: Float = 0
    /// The loudest thing that has left the graph since the last reset. A
    /// decaying meter read at the wrong moment says nothing; this answers
    /// "did any sound come out at all" without needing the timing to be lucky.
    private(set) var outputMax: Float = 0

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    /// One delay for the kit, after the spatial stage.
    ///
    /// This was briefly nine delays, one per lane, each on its own subdivision.
    /// It sounded chaotic: several delay lines at different times against a
    /// twelve-attack measure is not an echo, it is a second rhythm nobody asked
    /// for. One echo, one time, and it stays where the player left it.
    private let delay = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    /// Final brick wall. The synth's own saturation protects each lane, but the
    /// sum of nine of them plus delay feedback plus reverb build-up happens
    /// after that, and at high budgets that sum is genuinely loud.
    private let limiter = AVAudioUnitEffect(audioComponentDescription:
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: kAudioUnitSubType_PeakLimiter,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0, componentFlagsMask: 0))

    /// A decibel of headroom below full scale, after the limiter.
    ///
    /// The peak limiter's ceiling *is* 0 dBFS, so left to itself it parks a busy
    /// measure exactly on digital zero — technically not clipping and still a
    /// converter overshoot waiting to happen. This is where the room to breathe
    /// comes from, rather than from starving the limiter of pre-gain.
    private let trim = AVAudioMixerNode()
    private var laneNodes: [AVAudioSourceNode] = []
    /// Where each lane sits, kept because the source nodes are thrown away and
    /// remade whenever the hardware changes its mind about sample rate.
    private var positions: [AVAudio3DPoint] = DrumVoice.allCases.map {
        let p = $0.spatialPosition
        return AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
    }
    /// Decibels of make-up in front of the limiter. Measured in Tools/check.sh:
    /// enough that a sparse measure is not quiet, little enough that a full one
    /// is not permanently against the ceiling.
    private static let limiterPreGain: Float = 14
    /// The rate the kernel and the graph are currently built for.
    private var synthRate: Double = 48_000

    var reverbMix: Float = 14 { didSet { reverb.wetDryMix = max(0, min(100, reverbMix)) } }
    var delayMix: Float = 0 { didSet { delay.wetDryMix = max(0, min(100, delayMix)) } }
    var delayFeedback: Float = 34 { didSet { delay.feedback = max(0, min(90, delayFeedback)) } }
    var delaySeconds: Double = 0.3 { didSet { delay.delayTime = min(2, max(0.02, delaySeconds)) } }

    var sampleRate: Double { engine.outputNode.outputFormat(forBus: 0).sampleRate }
    var isRunning: Bool { engine.isRunning }
    /// What the engine currently believes the hardware wants. A route change
    /// can move this out from under a graph that was built for something else.
    var hardwareFormat: String {
        let format = engine.outputNode.outputFormat(forBus: 0)
        return "\(format.sampleRate)Hz \(format.channelCount)ch"
    }

    /// The host's own level, used for fading in and out around a pause.
    ///
    /// Deliberately the mixer's output and not `synth.masterVolume`: that one
    /// belongs to the listener, and a fade interrupted by the app being killed
    /// would otherwise leave their volume somewhere they did not put it.
    var outputVolume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    /// `offline` swaps the sound card for manual rendering so the whole chain
    /// can be measured without playing anything — the only honest way to check
    /// output levels, since the limiter, the room and the spatial stage are all
    /// invisible if you look at the voice bank alone.
    init(offline: Bool = false) {
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = offline ? 48_000 : (hardwareRate > 0 ? hardwareRate : 48_000)
        synth.prepare(sampleRate: rate)
        synthRate = rate
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

        engine.attach(environment)
        engine.attach(delay)
        engine.attach(reverb)
        engine.attach(limiter)
        engine.attach(trim)
        trim.outputVolume = 0.89

        // `.auto`: binaural on headphones, plain panning on a speaker.
        environment.outputType = .auto
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        // Gentle distance attenuation. The kit sits about a metre away and the
        // point of the positions is direction, not depth — a steep rolloff just
        // makes the wide lanes quiet.
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1.2
        environment.distanceAttenuationParameters.maximumDistance = 8
        environment.distanceAttenuationParameters.rolloffFactor = 0.35

        buildGraph(rate: rate)

        if offline {
            try? engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: 4_096)
        } else {
            observeConfigurationChanges()
            watchOutput()
        }
    }

    /// Build — or rebuild — every connection at a given sample rate.
    ///
    /// A source node's format is fixed when it is made, so a hardware rate
    /// change means new nodes, not just new connections. This is not a rare
    /// case on a phone: Bluetooth negotiates its own rate, so walking away from
    /// a speaker and putting headphones in can move the whole graph out from
    /// under itself. An engine left wired for the old rate restarts perfectly
    /// and plays to nobody, which is indistinguishable from a broken app.
    private func buildGraph(rate: Double) {
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!

        for node in laneNodes { engine.detach(node) }
        laneNodes.removeAll()

        for index in DrumVoice.allCases.indices {
            let node = AVAudioSourceNode(format: mono) { [self] _, _, frameCount, audioBufferList in
                render(lane: index, frames: Int(frameCount), into: audioBufferList)
            }
            engine.attach(node)
            engine.connect(node, to: environment, format: mono)
            node.position = positions[index]
            node.renderingAlgorithm = .auto
            laneNodes.append(node)
        }

        engine.connect(environment, to: delay, format: stereo)
        engine.connect(delay, to: reverb, format: stereo)
        engine.connect(reverb, to: limiter, format: stereo)
        engine.connect(limiter, to: trim, format: stereo)
        engine.connect(trim, to: engine.mainMixerNode, format: stereo)
    }

    /// The render callback: one lane, whatever it was asked for.
    ///
    /// No coordination with the other eight, deliberately. The engine inserts a
    /// converter in front of each input to the 3D mixer, and each converter
    /// pulls its source on its own schedule with its own frame count — so any
    /// scheme where one callback renders for all of them is wrong on a phone,
    /// however well it measures on a Mac.
    private func render(lane: Int, frames: Int, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let destination = list.first?.mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        synth.render(lane: lane, frames: frames, into: destination)
        if lane == 0 { cycles += 1 }
        return noErr
    }

    /// Slide each lane along x to wherever its Pan control has been left. The
    /// rest of the position — height and distance — stays the kit's.
    func place(_ kit: [DrumVoice: LaneSettings]) {
        for (index, voice) in DrumVoice.allCases.enumerated() {
            let base = voice.spatialPosition
            let pan = Float(kit[voice]?.pan ?? Double(voice.pan))
            let point = AVAudio3DPoint(x: pan * 1.8, y: base.y, z: base.z)
            positions[index] = point
            // The delay is the node connected to the environment now, so it is
            // the one that carries the position.
            if index < laneNodes.count { laneNodes[index].position = point }
        }
    }

    /// A route change — headphones in, an interface waking up, the system
    /// switching sample rate — posts AVAudioEngineConfigurationChange and stops
    /// the engine. Without handling it the audio just dies while the app keeps
    /// running, which is the exact bug Phonotropic shipped once.
    private func observeConfigurationChanges() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.reconfigure()
        }
    }

    /// A route change — headphones in, a car, an interface waking up — posts
    /// AVAudioEngineConfigurationChange and stops the engine. Restarting it is
    /// not enough if the new route runs at a different sample rate, which
    /// Bluetooth routinely does: the graph has to be rebuilt at the rate the
    /// hardware is actually asking for.
    private func reconfigure() {
        let wasRunning = engine.isRunning
        synth.silence()
        engine.stop()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let target = rate > 0 ? rate : 48_000
        Self.note("reconfiguring for \(target)Hz (was running: \(wasRunning))")
        synth.prepare(sampleRate: target)
        buildGraph(rate: target)
        engine.mainMixerNode.removeTap(onBus: 0)
        watchOutput()
        guard wasRunning else { return }
        engine.prepare()
        do {
            try engine.start()
            Self.note("engine restarted after route change — \(hardwareFormat)")
        } catch {
            Self.note("restart after route change FAILED: \(error.localizedDescription)")
        }
    }

    /// Keep `outputPeak` current. A 4096-frame tap is a fraction of a percent
    /// of a core and it is the only measurement that can tell a silent graph
    /// from a silent room.
    private func watchOutput() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            var peak: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                for f in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[c][f])) }
            }
            self.outputPeak = max(self.outputPeak * 0.6, peak)
            self.outputMax = max(self.outputMax, peak)
        }
    }

    /// Renders `seconds` of the whole chain, handing each block to `block`.
    /// Offline instances only.
    func renderOffline(seconds: Double, _ block: (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void) {
        guard engine.manualRenderingMode == .offline,
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: 1_024) else { return }
        if !engine.isRunning { try? engine.start() }
        var remaining = Int(seconds * engine.manualRenderingFormat.sampleRate)
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(1_024, remaining))
            guard let status = try? engine.renderOffline(frames, to: buffer), status == .success,
                  let channels = buffer.floatChannelData else { return }
            block(channels[0], channels[1], Int(buffer.frameLength))
            remaining -= Int(frames)
        }
    }

    func start() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            let out = engine.outputNode.outputFormat(forBus: 0)
            let env = environment.outputFormat(forBus: 0)
            Self.note("engine started — out \(out.sampleRate)Hz \(out.channelCount)ch, env \(env.sampleRate)Hz \(env.channelCount)ch, lanes \(laneNodes.count)")
        } catch {
            Self.note("engine FAILED to start: \(error.localizedDescription)")
        }
    }

    /// The engine's own picture of itself. `AVAudioEngine.description` draws the
    /// graph — every node, every connection, every format — which answers the
    /// question a level meter cannot: is the thing I am measuring actually
    /// joined to the thing that makes sound.
    func dumpGraph() {
        Self.note("outputNode input format: \(engine.outputNode.inputFormat(forBus: 0))")
        for line in engine.description.split(separator: "\n") {
            Self.note("graph| " + line.trimmingCharacters(in: .whitespaces))
        }
    }

    /// A snapshot for the log: enough to tell which half of the graph is at
    /// fault without a debugger.
    func diagnose(_ note: String) {
        Self.note("\(note): running \(engine.isRunning), cycles \(cycles), synthPeak \(synth.peak), OUTPUT \(outputPeak), max \(outputMax), mixer \(engine.mainMixerNode.outputVolume), trim \(trim.outputVolume)")
        outputMax = 0
    }

    /// Stop and start the engine outright.
    ///
    /// Not the same as `start()` on a paused engine, and the difference is the
    /// whole bug: after the audio session has been deactivated and reactivated
    /// underneath it, a paused engine's IO unit is stale. Starting it again
    /// succeeds, reports `isRunning`, renders happily into a buffer nobody is
    /// listening to — and the only symptom is silence.
    func restart() {
        synth.silence()
        engine.stop()
        // If the hardware has changed rate while we were stopped — a pair of
        // headphones went in during the pause — rebuild rather than start into
        // a graph wired for the old one.
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate > 0, abs(rate - synthRate) > 1 {
            Self.note("rate moved \(synthRate) → \(rate); rebuilding")
            synth.prepare(sampleRate: rate)
            synthRate = rate
            buildGraph(rate: rate)
            engine.mainMixerNode.removeTap(onBus: 0)
            watchOutput()
        }
        engine.prepare()
        do {
            try engine.start()
            Self.note("engine restarted — \(hardwareFormat)")
        } catch {
            Self.note("engine FAILED to restart: \(error.localizedDescription)")
        }
    }

    /// Stop rendering without tearing the graph down.
    func pause() {
        synth.silence()
        engine.pause()
    }

    func stop() {
        synth.silence()
        engine.stop()
    }
}
