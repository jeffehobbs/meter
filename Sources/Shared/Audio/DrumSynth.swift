import Foundation

/// A fully resolved hit, ready for the render thread. Everything the patch and
/// the lane macros and the hit's velocity had to say has already been folded
/// into these numbers, so the audio path never reads a patch, a dictionary or a
/// string.
struct Trigger {
    /// When this hit should be *heard*, in mach uptime seconds — the same clock
    /// the engine timestamps its buffers with.
    ///
    /// A hit used to have no time at all: it was pushed onto a queue and the
    /// voice started wherever the next render callback happened to drain it,
    /// which on a phone is up to a buffer away and a different distance for
    /// every lane. Zero still means "as soon as possible", which is what an
    /// audition wants.
    var at: Double = 0
    var lane: Int32 = 0
    /// Lanes whose ringing tail this hit cuts short, as a bitmask of lanes.
    /// A closed tick landing on an open sustain is the canonical case.
    var chokeMask: UInt32 = 0

    var carrierHz: Double = 110
    var ratio: Double = 1
    var fmIndex: Double = 0
    var fmDecay: Double = 0.02
    var drop: Double = 0
    var dropTime: Double = 0.03
    var fold: Double = 0
    var ring: Double = 0
    var bodyDecay: Double = 0.25
    var bodyLevel: Double = 1

    var noiseLevel: Double = 0
    var noiseDecay: Double = 0.08
    var filterMode: Int32 = 1
    var cutoffHz: Double = 1_500
    var resonance: Double = 0.3
    var cutoffSweep: Double = 0
    var crush: Double = 0
    var pingLevel: Double = 0

    var metalLevel: Double = 0
    var metalDecay: Double = 0.6
    var metalHz: Double = 320

    var level: Double = 0.9
    var drive: Double = 1.2
}

/// The rack. Two voices per lane so a ringing tail is not cut by the next hit
/// on the same lane — a real module would cut it, but two of them wouldn't, and
/// two sounds better.
///
/// Everything the render thread touches is preallocated; triggers arrive
/// through a try-lock queue. No allocation, no locks held, no Swift runtime
/// calls in the inner loop.
final class DrumSynth {
    static let voicesPerLane = 2
    private static let laneCount = DrumVoice.allCases.count
    static let maxVoices = laneCount * voicesPerLane
    private static let metalPartials = 6
    /// Inharmonic ratios. Deliberately not a harmonic series and not a real
    /// cymbal's modes either — these are the ratios that stayed interesting
    /// when the bank was tuned by ear.
    private static let metalRatios: [Double] = [1.0, 1.413, 1.789, 2.197, 2.714, 3.373]
    /// Per-lane ceiling. Nine lanes now sum downstream of the kernel instead of
    /// inside it, so each one has to leave room for the others.
    private static let spatialHeadroom: Float = 0.55

    private struct Voice {
        var active = false
        var lane: Int32 = 0
        /// The sample within the current buffer where this voice starts. Set
        /// once, when the voice is triggered, and cleared by the buffer that
        /// honors it.
        var startOffset: Int32 = 0
        var age: Int32 = 0            // frames since trigger, for voice stealing

        // Oscillator pair
        var carPhase = 0.0
        var modPhase = 0.0
        var carHz = 110.0
        var baseHz = 110.0
        var ratio = 1.0
        var dropAmount = 0.0
        var dropEnv: Double = 1
        var dropCoef: Double = 0.99
        var fmIndex = 0.0
        var fmEnv: Double = 1
        var fmCoef: Double = 0.99
        var fold = 0.0
        var ring = 0.0
        var bodyEnv: Float = 0
        var bodyCoef: Float = 0.999
        var bodyLevel: Float = 1

        // Noise channel
        var noiseEnv: Float = 0
        var noiseCoef: Float = 0.999
        var noiseLevel: Float = 0
        var crushHold: Int32 = 0      // sample-and-hold period in frames
        var crushCounter: Int32 = 0
        var crushValue: Float = 0
        var ping: Float = 0           // impulse energy left to inject
        var filterMode: Int32 = 1
        var cutoff = 1_500.0
        var cutoffTarget = 1_500.0
        var cutoffCoef = 0.999
        var k: Double = 1             // filter damping, 1/Q
        var a1 = 0.0, a2 = 0.0, a3 = 0.0
        var ic1 = 0.0, ic2 = 0.0
        var coefAge: Int32 = 0

        // Inharmonic bank
        /// True when this voice was struck rather than driven — its filter is
        /// still ringing after every envelope has gone, and retiring the voice
        /// on the envelopes alone would cut the ring off.
        var ringing = false
        var metalEnv: Float = 0
        var metalCoef: Float = 0.999
        var metalLevel: Float = 0
        var metalPhase: (Double, Double, Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0)
        var metalInc: (Double, Double, Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0)

        // Attack smoothing: a fraction of a millisecond, just enough that the
        // first sample isn't a step from silence to full scale. Any longer and
        // the hit loses its click, which on a modular voice *is* the sound.
        var attack: Float = 0
        var attackInc: Float = 1

        var level: Float = 0.9
        var drive: Float = 1.2
        // A one-pole DC blocker. The wavefolder and the saturator are both
        // asymmetric under phase modulation and will happily park a low voice
        // off zero, which eats headroom and thuds in the limiter.
        var dcX: Float = 0
        var dcY: Float = 0
    }

    let triggers = EventQueue<Trigger>(capacity: 256)

    /// Master level, read live from the interface.
    var masterVolume: Float = 0.85

    /// Peak seen since the last read, for the interface's meter. Written from
    /// the render thread and read from the main one without synchronization: it
    /// is a display hint and a torn Float here costs nothing.
    private(set) var peak: Float = 0
    /// Per-lane hit flashes, decayed on the render thread for the grid's glow.
    private(set) var laneEnergy = [Float](repeating: 0, count: DrumVoice.allCases.count)

    private let voices: UnsafeMutablePointer<Voice>
    private var sampleRate = 48_000.0
    private var noiseState: UInt32 = 0x2545F491

    init() {
        voices = UnsafeMutablePointer<Voice>.allocate(capacity: Self.maxVoices)
        voices.initialize(repeating: Voice(), count: Self.maxVoices)
    }

    deinit { voices.deallocate() }

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        // A rebuilt graph is a new route, and a new route has its own latency.
        scheduleLead = 0
    }

    func silence() {
        for v in 0..<Self.maxVoices { voices[v].active = false }
        // Hits are handed over a lead-time ahead of being heard, so stopping
        // has to throw away the ones already in flight — otherwise a stop, or
        // the end of a sleep timer, is followed by a tenth of a second of kit.
        triggers.drain { _ in }
        pendingCount = 0
    }

    // MARK: - Render

    @inline(__always)
    private func white() -> Float {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Float(Int32(bitPattern: noiseState)) * (1.0 / 2_147_483_648.0)
    }

    /// Cheap sine. A table would be faster but `sin` on Apple silicon is quick
    /// enough for eighteen voices and this keeps the FM phase-accurate, which
    /// matters: a table's interpolation error becomes audible sideband noise at
    /// the modulation indices these patches use.
    @inline(__always)
    private func osc(_ phase: Double) -> Double {
        sin(phase * 2 * Double.pi)
    }

    /// Render one lane into one mono buffer.
    ///
    /// Per lane, and **independent** of every other lane, which is the whole
    /// point. Each lane is placed somewhere in the room and the spatial
    /// rendering happens downstream, so a pre-mixed stereo pair would have
    /// thrown away the thing being placed.
    ///
    /// The earlier version rendered all nine lanes in whichever callback came
    /// first each cycle and let the other eight copy their share out. That works
    /// only if every source node is pulled once per cycle with the same frame
    /// count — true on a Mac, and false on a phone, where the engine inserts a
    /// converter in front of each input to the 3D mixer and each converter pulls
    /// its source on its own schedule. The result was nine lanes each holding a
    /// different moment in time and a sequencer advancing nine times a cycle:
    /// meters full of signal, and nothing recognisable to listen to.
    ///
    /// A lane's voices touch no state but their own, so there is nothing to
    /// coordinate — which is the version that should have been written first.
    func render(lane: Int, frames: Int, at playout: Double,
                into out: UnsafeMutablePointer<Float>) {
        collect()
        if playout > 0 {
            measureLead(playout: playout, frames: frames)
            startDue(lane: lane, playout: playout, frames: frames)
        } else {
            // No usable clock — offline rendering, where a buffer has no
            // moment it will be heard at. Everything waiting is simply due.
            startAll(lane: lane)
        }

        for f in 0..<frames { out[f] = 0 }

        let first = lane * Self.voicesPerLane
        let last = min(Self.maxVoices, first + Self.voicesPerLane)
        for v in first..<last {
            guard voices[v].active else { continue }
            var voice = voices[v]
            var laneLoudest: Float = 0
            // Where this voice starts in this buffer. Non-zero only for the
            // buffer that contains its onset, which is the whole point: a hit
            // lands on the sample the clock asked for rather than on the
            // boundary that happened to notice it.
            let from = Int(voice.startOffset)
            voice.startOffset = 0
            if from >= frames { voices[v] = voice; continue }

            for f in from..<frames {
                // --- envelopes -------------------------------------------------
                if voice.attack < 1 {
                    voice.attack = min(1, voice.attack + voice.attackInc)
                }
                voice.bodyEnv *= voice.bodyCoef
                voice.noiseEnv *= voice.noiseCoef
                voice.metalEnv *= voice.metalCoef
                voice.dropEnv *= voice.dropCoef
                voice.fmEnv *= voice.fmCoef

                // --- oscillator pair ------------------------------------------
                var body: Double = 0
                if voice.bodyLevel > 0 {
                    let hz = voice.baseHz * (1 + voice.dropAmount * voice.dropEnv)
                    voice.carHz = hz
                    let carInc = hz / sampleRate
                    let modInc = hz * voice.ratio / sampleRate
                    voice.carPhase += carInc
                    voice.modPhase += modInc
                    if voice.carPhase > 1 { voice.carPhase -= 1 }
                    if voice.modPhase > 1 { voice.modPhase -= 1 }

                    let modulator = osc(voice.modPhase)
                    // Phase modulation: the index has its own fast decay, which
                    // is what makes the attack bright and the tail pure.
                    let index = voice.fmIndex * Double(voice.fmEnv)
                    var car = osc(voice.carPhase + modulator * index * 0.159_154_9)
                    if voice.fold > 0 {
                        // Wavefolder. Gain rides the body envelope so the
                        // harmonics collapse inward as the hit dies.
                        let g = 1 + voice.fold * 8 * Double(voice.bodyEnv)
                        car = sin(car * g) / (1 + voice.fold * 0.5)
                    }
                    if voice.ring > 0 {
                        car = car * (1 - voice.ring) + car * modulator * voice.ring * 1.8
                    }
                    body = car * Double(voice.bodyEnv * voice.bodyLevel)
                }

                // --- noise channel -------------------------------------------
                var noise: Float = 0
                if voice.noiseLevel > 0 || voice.ping > 0 {
                    var n = white() * voice.noiseEnv * voice.noiseLevel
                    if voice.crushHold > 1 {
                        // Sample and hold. Aliasing is the point.
                        voice.crushCounter -= 1
                        if voice.crushCounter <= 0 {
                            voice.crushCounter = voice.crushHold
                            voice.crushValue = n
                        }
                        n = voice.crushValue
                    }
                    if voice.ping > 0 {
                        // A single impulse into a high-resonance filter: a
                        // struck filter, no oscillator involved.
                        n += voice.ping
                        voice.ping = 0
                    }
                    noise = Float(filter(&voice, Double(n)))
                }

                // --- inharmonic bank -----------------------------------------
                var metal: Double = 0
                if voice.metalLevel > 0 {
                    voice.metalPhase.0 += voice.metalInc.0
                    voice.metalPhase.1 += voice.metalInc.1
                    voice.metalPhase.2 += voice.metalInc.2
                    voice.metalPhase.3 += voice.metalInc.3
                    voice.metalPhase.4 += voice.metalInc.4
                    voice.metalPhase.5 += voice.metalInc.5
                    // A steeper rolloff across the partials than the bank
                    // shipped with. The upper ones sit in the two-to-four
                    // kilohertz band the ear is most sensitive to, so a flat
                    // series reads as far louder than it measures — which is
                    // how a cymbal quieter than the kick can still dominate.
                    metal = (osc(voice.metalPhase.0) + osc(voice.metalPhase.1) * 0.72
                             + osc(voice.metalPhase.2) * 0.52 + osc(voice.metalPhase.3) * 0.34
                             + osc(voice.metalPhase.4) * 0.22 + osc(voice.metalPhase.5) * 0.14)
                        / 2.94
                    metal *= Double(voice.metalEnv * voice.metalLevel)
                }

                // --- sum, saturate, block DC ----------------------------------
                var s = Float(body + metal) + noise
                s = tanh(s * voice.drive) * voice.level * voice.attack
                // y[n] = x[n] - x[n-1] + 0.9995·y[n-1]
                let dc = s - voice.dcX + 0.9995 * voice.dcY
                voice.dcX = s
                voice.dcY = dc
                s = dc

                out[f] += s
                let mag = abs(s)
                if mag > laneLoudest { laneLoudest = mag }
            }

            voice.age += Int32(frames)
            // Retire the voice once every channel is inaudible. Checking the
            // envelopes rather than a fixed length is what lets a patch's decay
            // macro run to two seconds without truncation.
            let quiet: Float = 0.00015
            let ringOut = voice.ringing && abs(voice.ic1) + abs(voice.ic2) > 0.0002
            if voice.bodyEnv < quiet && voice.noiseEnv < quiet && voice.metalEnv < quiet
                && !ringOut {
                voice.active = false
            }
            voices[v] = voice
            if laneLoudest > laneEnergy[lane] { laneEnergy[lane] = laneLoudest }
        }

        // Master, with a soft ceiling, applied per lane before the spatial
        // stage. The rack is deliberately allowed to run hot into this:
        // eighteen saturating voices summing is exactly the case where a hard
        // clip would sound like a bug. The gain leaves headroom for nine lanes
        // arriving at the same instant — measured, in Tools/check.sh.
        var localPeak: Float = 0
        for f in 0..<frames {
            let s = tanh(out[f] * masterVolume * 1.12) * Self.spatialHeadroom
            out[f] = s
            localPeak = max(localPeak, abs(s))
        }

        // Release the meters on a clock, not per block. A fixed per-block factor
        // decays at whatever rate the hardware happens to hand out buffers —
        // about twenty times a second at 256 frames — so the reading was gone
        // before a 20 Hz interface could ever sample it. Only one lane needs to
        // run the clock; the others would multiply the release by nine.
        let release = Float(frames) / Float(sampleRate) * 1.6
        peak = max(peak - (lane == 0 ? release : 0), localPeak)
        if lane == 0 {
            for i in laneEnergy.indices { laneEnergy[i] = max(0, laneEnergy[i] - release * 1.6) }
        }
    }

    /// Zavalishin's topology-preserving state variable filter. Stable at any
    /// cutoff up to Nyquist, which a Chamberlin SVF is not — and these patches
    /// sweep a resonant filter from 12 kHz down to 300 Hz inside one hit, which
    /// is precisely where the naive form blows up.
    @inline(__always)
    private func filter(_ voice: inout Voice, _ input: Double) -> Double {
        // Coefficients at control rate. Recomputing a tangent per frame per
        // voice buys nothing audible.
        voice.coefAge -= 1
        if voice.coefAge <= 0 {
            voice.coefAge = 16
            voice.cutoff += (voice.cutoffTarget - voice.cutoff) * (1 - voice.cutoffCoef)
            let fc = min(max(20, voice.cutoff), sampleRate * 0.47)
            let g = tan(Double.pi * fc / sampleRate)
            voice.a1 = 1 / (1 + g * (g + voice.k))
            voice.a2 = g * voice.a1
            voice.a3 = g * voice.a2
        }
        let v3 = input - voice.ic2
        let v1 = voice.a1 * voice.ic1 + voice.a2 * v3
        let v2 = voice.ic2 + voice.a2 * voice.ic1 + voice.a3 * v3
        voice.ic1 = 2 * v1 - voice.ic1
        voice.ic2 = 2 * v2 - voice.ic2
        switch voice.filterMode {
        case 0:  return v2                                   // lowpass
        case 2:  return input - voice.k * v1 - v2            // highpass
        default: return v1 * voice.k                         // bandpass, gain-compensated
        }
    }

    // MARK: - Triggering

    // MARK: - Scheduling

    /// Hits waiting for the buffer they belong in.
    ///
    /// The queue the clock writes into is drained by whichever lane the engine
    /// pulls first — and on iOS every lane sits behind its own converter,
    /// pulling on its own schedule — so a hit cannot be started there. It
    /// belongs to one lane at one moment, and that lane may not have been asked
    /// for that moment yet.
    private var pending = [Trigger](repeating: Trigger(), count: 192)
    private var pendingCount = 0

    /// Take everything the clock has written since the last buffer.
    private func collect() {
        triggers.drain { [self] t in
            if pendingCount < pending.count {
                pending[pendingCount] = t
                pendingCount += 1
            } else {
                // The clock is never expected to run this far ahead of the
                // graph; if it does, a hit early is better than a hit lost.
                start(t, offset: 0)
            }
        }
    }

    /// Start this lane's hits that fall inside the buffer about to be rendered,
    /// each at its own sample.
    private func startDue(lane: Int, playout: Double, frames: Int) {
        guard pendingCount > 0 else { return }
        let ends = playout + Double(frames) / sampleRate
        var keep = 0
        for i in 0..<pendingCount {
            let t = pending[i]
            guard Int(t.lane) == lane, t.at < ends else {
                pending[keep] = t
                keep += 1
                continue
            }
            // A moment already gone is due now rather than dropped: the clock
            // is never silently disobeyed, and `at == 0` — an audition — is
            // exactly this case.
            var offset = 0
            if t.at > playout {
                offset = min(frames - 1, Int(((t.at - playout) * sampleRate).rounded()))
            } else if Self.watching, t.at > 0 {
                missed += 1
            }
            start(t, offset: Int32(offset))
            if Self.watching, t.at > 0 {
                let error = abs(playout + Double(offset) / sampleRate - t.at)
                errorMax = max(errorMax, error)
                errorSum += error
                errorCount += 1
            }
        }
        pendingCount = keep
    }

    /// Offline rendering, where a buffer has no moment it will be heard at, so
    /// everything waiting for this lane starts at the top of it.
    private func startAll(lane: Int) {
        guard pendingCount > 0 else { return }
        var keep = 0
        for i in 0..<pendingCount {
            let t = pending[i]
            if Int(t.lane) == lane {
                start(t, offset: 0)
            } else {
                pending[keep] = t
                keep += 1
            }
        }
        pendingCount = keep
    }

    /// How far ahead of the render call the buffer being rendered will actually
    /// be heard: the output latency plus whatever the engine is holding. A
    /// couple of milliseconds into a speaker and a tenth of a second into
    /// Bluetooth, so it is measured rather than assumed — and the clock has to
    /// hand its hits over that far in advance for them to be placeable at all.
    ///
    /// Held at the largest lead seen since the graph was built and rounded up to
    /// a whole buffer. A lead that moved with every callback would move the hits
    /// with it, which is the jitter this whole arrangement exists to remove; it
    /// is reset by `prepare`, which is what a route change goes through.
    private(set) var scheduleLead: Double = 0

    private func measureLead(playout: Double, frames: Int) {
        let lead = playout - Double(DispatchTime.now().uptimeNanoseconds) / 1e9
        // A lead of a second is not a lead, it is a bad timestamp.
        guard lead > 0, lead < 1 else { return }
        let buffer = Double(frames) / sampleRate
        guard buffer > 0, lead + buffer > scheduleLead else { return }
        scheduleLead = ((lead + buffer) / buffer).rounded(.up) * buffer
    }

    /// Placement diagnostics, kept only when someone is watching. Written on the
    /// render thread and read once a second by the transport's report —
    /// deliberately unsynchronized, since a diagnostic that needs a lock changes
    /// what it is measuring.
    static let watching = AudioOutput.verbose
    private var errorMax: Double = 0
    private var errorSum: Double = 0
    private var errorCount = 0
    private var missed = 0

    /// How far each voice actually started from where the clock asked for it,
    /// since the last read.
    func takePlacement() -> (mean: Double, max: Double, count: Int,
                             missed: Int, lead: Double, skipped: Int) {
        defer { errorMax = 0; errorSum = 0; errorCount = 0; missed = 0 }
        return (errorCount > 0 ? errorSum / Double(errorCount) : 0, errorMax,
                errorCount, missed, scheduleLead, triggers.skipped)
    }

    /// Pick a slot for a lane: a free one, else the oldest of that lane's own
    /// voices. A lane can never steal another lane's slot, so a busy hat lane
    /// cannot silence the low end — the failure mode that makes a shared voice
    /// pool sound broken at high density.
    private func slot(for lane: Int32) -> Int {
        let base = Int(lane) * Self.voicesPerLane
        var oldest = base
        for i in 0..<Self.voicesPerLane {
            let idx = base + i
            if !voices[idx].active { return idx }
            if voices[idx].age > voices[oldest].age { oldest = idx }
        }
        return oldest
    }

    private func start(_ t: Trigger, offset: Int32) {
        // Choke: cut the tails this hit is meant to interrupt.
        if t.chokeMask != 0 {
            for v in 0..<Self.maxVoices where voices[v].active {
                if t.chokeMask & (1 << UInt32(voices[v].lane)) != 0 {
                    // Fast release rather than a hard stop, so a choke is a
                    // damping gesture and not a click.
                    voices[v].bodyCoef = min(voices[v].bodyCoef, 0.9985)
                    voices[v].noiseCoef = min(voices[v].noiseCoef, 0.9985)
                    voices[v].metalCoef = min(voices[v].metalCoef, 0.9985)
                }
            }
        }

        let idx = slot(for: t.lane)
        var voice = Voice()
        voice.active = true
        voice.lane = t.lane
        voice.startOffset = offset
        voice.age = 0

        voice.baseHz = max(12, min(sampleRate * 0.4, t.carrierHz))
        voice.ratio = max(0.05, t.ratio)
        voice.dropAmount = max(0, t.drop)
        voice.dropEnv = 1
        voice.dropCoef = decayCoef(seconds: t.dropTime)
        voice.fmIndex = max(0, t.fmIndex)
        voice.fmEnv = 1
        voice.fmCoef = decayCoef(seconds: t.fmDecay)
        voice.fold = max(0, min(1, t.fold))
        voice.ring = max(0, min(1, t.ring))
        voice.bodyLevel = Float(max(0, t.bodyLevel))
        voice.bodyEnv = voice.bodyLevel > 0 ? 1 : 0
        voice.bodyCoef = Float(decayCoef(seconds: t.bodyDecay))
        // Random start phases keep repeated hits from being bit-identical; a
        // machine that plays the same sample every time is the thing modular
        // percussion is not.
        voice.carPhase = Double(white()) * 0.02
        voice.modPhase = Double(white()) * 0.02

        voice.noiseLevel = Float(max(0, t.noiseLevel))
        voice.noiseEnv = voice.noiseLevel > 0 ? 1 : 0
        voice.noiseCoef = Float(decayCoef(seconds: t.noiseDecay))
        voice.filterMode = t.filterMode
        let cut = max(30, min(sampleRate * 0.45, t.cutoffHz))
        voice.cutoffTarget = cut
        voice.cutoff = min(sampleRate * 0.45, cut * (1 + max(0, t.cutoffSweep)))
        // The sweep is a decay too: fast at first, easing into the target.
        voice.cutoffCoef = decayCoef(seconds: max(0.004, t.noiseDecay * 0.7), perFrames: 16)
        voice.coefAge = 0
        // Resonance to damping, logarithmically: Q from 0.5 to 400 across the
        // knob. A linear map is useless here — everything interesting about a
        // struck filter happens in the last two percent of it, and the whole
        // reason `Ping` sounded like a click rather than a ping was a linear map
        // whose ceiling rang for twenty milliseconds.
        let q = 0.5 * pow(800, min(1, max(0, t.resonance)))
        voice.k = 1 / q
        voice.crushHold = t.crush > 0.01
            ? Int32(1 + (sampleRate / 48_000.0) * pow(t.crush, 1.6) * 48)
            : 0
        voice.crushCounter = 0
        // A single-sample impulse into a resonant filter is a *tiny* amount of
        // energy: the ring it produces scales with the filter's own gain, so at
        // the resonances these ping patches use it comes out 50 dB below
        // everything else. The impulse is therefore scaled by 1/(g·k) — the
        // inverse of that gain — which makes the ring's peak land at pingLevel
        // regardless of where the filter is tuned. Measured, not guessed: this
        // is what the rack check in Tools/ is for.
        if t.pingLevel > 0 {
            let g = tan(Double.pi * min(voice.cutoff, sampleRate * 0.47) / sampleRate)
            let gain = max(1e-4, g * voice.k)
            voice.ping = Float(min(4_000, max(0, t.pingLevel) / gain))
            voice.ringing = true
            if voice.noiseEnv == 0 { voice.noiseEnv = 1 }
        } else {
            voice.ping = 0
        }

        voice.metalLevel = Float(max(0, t.metalLevel))
        voice.metalEnv = voice.metalLevel > 0 ? 1 : 0
        voice.metalCoef = Float(decayCoef(seconds: t.metalDecay))
        if voice.metalLevel > 0 {
            let base = max(30, min(sampleRate * 0.4, t.metalHz))
            var incs: [Double] = []
            for r in Self.metalRatios {
                // A little detune per hit, so struck metal never rings twice
                // the same way.
                let jitter = 1 + Double(white()) * 0.004
                let hz = base * r * jitter
                incs.append(hz < sampleRate * 0.45 ? hz / sampleRate : 0)
            }
            voice.metalInc = (incs[0], incs[1], incs[2], incs[3], incs[4], incs[5])
            voice.metalPhase = (Double(white()) * 0.5, Double(white()) * 0.5, Double(white()) * 0.5,
                                Double(white()) * 0.5, Double(white()) * 0.5, Double(white()) * 0.5)
        }

        voice.level = Float(max(0, min(2, t.level)))
        voice.drive = Float(max(0.2, min(6, t.drive)))
        voice.attack = 0
        voice.attackInc = Float(1.0 / max(1, 0.0004 * sampleRate))

        voices[idx] = voice
    }

    /// Per-frame multiplier that takes an envelope from 1 to -80 dB in
    /// `seconds`. `perFrames` lets a control-rate envelope use the same math.
    private func decayCoef(seconds: Double, perFrames: Double = 1) -> Double {
        let s = max(0.0008, seconds)
        return pow(0.0001, perFrames / (s * sampleRate))
    }
}

// MARK: - Building a trigger

extension Trigger {
    /// The highest a tuned body is allowed to sit, in hertz. Roughly middle C.
    static let pitchCeiling: Double = 270
    /// And the highest a *ring* may sit — a struck filter or an inharmonic bank.
    ///
    /// These are pitched too, and the body ceiling does not touch them: a
    /// resonant filter's centre frequency is its note, and a metal bank's base
    /// is where its partials start. A clave at 1.6 kHz with a two-hundred
    /// millisecond ring measured as a single partial 1390× above the mean of its
    /// own spectrum, which is the arithmetic of a beep.
    static let ringCeiling: Double = 1_100
    static let metalCeiling: Double = 700

    /// Which lanes' tails a lane damps when it fires. A closed tick landing on
    /// an open sustain is the one case a kit needs, and doing it in the rack
    /// rather than in the arrangement is what a hi-hat pedal actually is.
    static let chokes: [DrumVoice: [DrumVoice]] = [
        .closedHat: [.openHat],
    ]

    static let laneIndex: [DrumVoice: Int] = {
        var map: [DrumVoice: Int] = [:]
        for (i, v) in DrumVoice.allCases.enumerated() { map[v] = i }
        return map
    }()

    /// Fold a patch, a lane's macros and a hit's velocity into the flat
    /// parameter block the render thread wants.
    ///
    /// Velocity is not only level here: a harder hit gets more modulation index,
    /// more fold and a higher filter sweep, because that is what hitting a real
    /// voice harder does. A velocity that only changes volume is the tell of a
    /// cheap drum machine, and on a modular voice it is a wasted opportunity —
    /// these patches have plenty of places for the energy to go.
    init(at: Double = 0, voice: DrumVoice, lane: LaneSettings, velocity: Double) {
        self.init()
        self.at = at
        let p = lane.patch
        let v = max(0.05, min(1, velocity))

        self.lane = Int32(Trigger.laneIndex[voice] ?? 0)
        if let choked = Trigger.chokes[voice] {
            var mask: UInt32 = 0
            for c in choked { mask |= 1 << UInt32(Trigger.laneIndex[c] ?? 0) }
            chokeMask = mask
        }

        let tone = max(0.25, lane.tone)
        let fold = max(0, lane.fold)
        let grit = max(0, lane.grit)
        let decay = max(0.1, lane.decay)

        // A drum has a fundamental below about middle C. Above that a tuned
        // body stops reading as a hit and starts reading as a note — a beep —
        // and the Tone macro drifting upward was walking several patches
        // straight past it. The ceiling is on the *base* pitch only: the pitch
        // envelope still starts far above it, because that transient is the
        // punch rather than the pitch.
        carrierHz = min(Trigger.pitchCeiling, p.baseHz * tone)
        ratio = p.ratio
        fmIndex = p.fmIndex * fold * (0.55 + 0.65 * v)
        fmDecay = p.fmDecay * decay
        drop = p.drop * (0.72 + 0.4 * v)
        dropTime = p.dropTime
        self.fold = min(1, p.fold * fold * (0.62 + 0.5 * v))
        ring = p.ring
        bodyDecay = p.bodyDecay * decay
        bodyLevel = p.bodyLevel

        // Grit above unity used to be an unbounded gain on the noise channel,
        // which on a patch that is mostly noise is a volume control — and in
        // front of a resonant filter it is a volume control with the filter's
        // gain after it. Above unity it still opens up, with diminishing
        // returns and a ceiling: the top of the knob is dirtier rather than
        // louder, which is what the macro is for. Crush is deliberately left
        // to take the full range, since that is the dirt.
        noiseLevel = p.noiseLevel * (grit <= 1 ? grit : min(1.2, 1 + (grit - 1) * 0.4))
        noiseDecay = p.noiseDecay * decay
        filterMode = Int32(p.filterMode.rawValue)
        // A struck filter's cutoff is its pitch, so it takes the ring ceiling;
        // a filter that is only shaping noise can go as high as it likes.
        cutoffHz = p.pingLevel > 0 ? min(Trigger.ringCeiling, p.cutoffHz * tone)
                                   : p.cutoffHz * tone
        resonance = p.resonance
        cutoffSweep = p.cutoffSweep * (0.45 + 0.85 * v)
        crush = min(1, p.crush * grit)
        pingLevel = p.pingLevel * (0.45 + 0.65 * v)

        metalLevel = p.metalLevel
        metalDecay = p.metalDecay * decay
        metalHz = min(Trigger.metalCeiling, p.metalHz * tone)

        // Level tracks velocity, but never to silence: a ghost note still has
        // to be a hit.
        level = p.level * lane.level * (0.34 + 0.76 * v)
        drive = p.drive
    }
}
