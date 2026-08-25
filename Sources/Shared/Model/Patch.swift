import Foundation

/// How the noise channel's filter is configured. A modular percussion voice is
/// usually *defined* by this choice — the same noise burst is a hat through a
/// highpass, a snare through a bandpass and a rumble through a lowpass.
enum FilterMode: Int, Codable, CaseIterable {
    case lowpass = 0, bandpass = 1, highpass = 2
}

/// One patch: a complete modular percussion voice, described as the settings of
/// a small fixed rack rather than as a named drum.
///
/// The rack, in signal order:
///
///   1. **Two oscillators.** A carrier and a modulator at an arbitrary (usually
///      inharmonic) ratio, phase-modulating each other with an index that has
///      its own decay. This is where the *attack* comes from — a fast-collapsing
///      FM index is the whole trick behind percussive FM voices.
///   2. **Pitch envelope.** The carrier starts `drop` above its base pitch and
///      falls to it over `dropTime`. The classic modular thump.
///   3. **Wavefolder.** `sin(g·x)` with the gain riding the body envelope, so
///      the harmonics collapse inward as the hit dies. Cheap, and it does the
///      right thing: loud means bright and complicated.
///   4. **Ring modulator.** Carrier times modulator, mixed in. Turns a tuned
///      voice into a clangorous one without changing its envelope.
///   5. **Noise channel.** White noise, optionally sample-and-hold crushed,
///      through a resonant state-variable filter with its own cutoff sweep. An
///      impulse into a high-resonance filter is the "ping" — a struck filter,
///      no oscillator involved.
///   6. **Inharmonic bank.** Six sine partials at non-integer ratios. Metal.
///
/// Nothing here knows what a snare is. A lane sounds like whatever patch is in
/// it, and the four macros (`tone`, `fold`, `grit`, `decay`) let the same patch
/// cover a lot of ground — which is what makes patch-swapping a kit worth doing.
struct Patch: Codable, Identifiable, Hashable {
    var name: String
    var id: String { name }

    // Oscillator pair
    var baseHz: Double = 110
    var ratio: Double = 1.0
    var fmIndex: Double = 0
    var fmDecay: Double = 0.02
    var drop: Double = 0          // start pitch = baseHz * (1 + drop)
    var dropTime: Double = 0.03
    var fold: Double = 0
    var ring: Double = 0
    var bodyDecay: Double = 0.25
    var bodyLevel: Double = 1.0

    // Noise channel
    var noiseLevel: Double = 0
    var noiseDecay: Double = 0.08
    var filterMode: FilterMode = .bandpass
    var cutoffHz: Double = 1_500
    var resonance: Double = 0.3    // 0 … 1, mapped to Q
    var cutoffSweep: Double = 0    // start cutoff = cutoffHz * (1 + sweep)
    var crush: Double = 0          // 0 … 1 sample-and-hold reduction
    var pingLevel: Double = 0      // impulse into the resonant filter

    // Inharmonic bank
    var metalLevel: Double = 0
    var metalDecay: Double = 0.6
    var metalHz: Double = 320

    var level: Double = 0.9
    /// Post-sum saturation. Modular voices nearly always run into something
    /// that clips; a little of it is what glues a hit together.
    var drive: Double = 1.2

    /// The bank. Ordered roughly low-to-bright, since that is how the kit
    /// builder walks it.
    static let bank: [Patch] = [
        Patch(name: "Thump", baseHz: 52, ratio: 1.0, fmIndex: 0.9, fmDecay: 0.008,
              drop: 1.8, dropTime: 0.028, fold: 0.05, bodyDecay: 0.42,
              noiseLevel: 0.10, noiseDecay: 0.006, filterMode: .lowpass,
              cutoffHz: 2_600, resonance: 0.15, level: 1.0, drive: 1.5),

        Patch(name: "Sub", baseHz: 44, ratio: 0.5, fmIndex: 0.2, fmDecay: 0.05,
              drop: 0.35, dropTime: 0.09, bodyDecay: 0.85, level: 0.95, drive: 1.1),

        Patch(name: "Iterate", baseHz: 96, ratio: 1.53, fmIndex: 5.2, fmDecay: 0.030,
              drop: 0.9, dropTime: 0.020, fold: 0.30, bodyDecay: 0.20,
              noiseLevel: 0.22, noiseDecay: 0.05, filterMode: .bandpass,
              cutoffHz: 2_200, resonance: 0.35, cutoffSweep: 1.2, level: 0.85, drive: 1.6),

        Patch(name: "Fold", baseHz: 148, ratio: 2.01, fmIndex: 1.6, fmDecay: 0.06,
              drop: 0.5, dropTime: 0.04, fold: 0.85, ring: 0.15, bodyDecay: 0.28,
              level: 0.8, drive: 1.4),

        Patch(name: "Clang", baseHz: 210, ratio: 1.414, fmIndex: 3.4, fmDecay: 0.12,
              drop: 0.2, dropTime: 0.03, fold: 0.35, ring: 0.55, bodyDecay: 0.34,
              metalLevel: 0.19, metalDecay: 0.38, metalHz: 640, level: 0.72, drive: 1.5),

        Patch(name: "Muffle", baseHz: 132, ratio: 1.19, fmIndex: 1.1, fmDecay: 0.014,
              drop: 0.45, dropTime: 0.026, fold: 0.12, bodyDecay: 0.15,
              noiseLevel: 0.30, noiseDecay: 0.035, filterMode: .lowpass,
              cutoffHz: 780, resonance: 0.35, cutoffSweep: 1.1,
              level: 0.78, drive: 1.3),

        Patch(name: "Tine", baseHz: 264, ratio: 3.47, fmIndex: 2.1, fmDecay: 0.05,
              drop: 0.12, dropTime: 0.02, bodyDecay: 0.18, level: 0.7, drive: 1.2),

        Patch(name: "Zap", baseHz: 320, ratio: 1.0, fmIndex: 0.4, fmDecay: 0.01,
              drop: 7.0, dropTime: 0.055, fold: 0.25, ring: 0.30, bodyDecay: 0.13,
              noiseLevel: 0.14, noiseDecay: 0.03, filterMode: .highpass,
              cutoffHz: 900, resonance: 0.4, level: 0.66, drive: 1.3),

        // A struck filter is a sine burst, so its ring *is* its pitch: at 430 Hz
        // for over a second this was the most beep-like thing in the bank.
        // Lower and much shorter — a struck drum head rather than a tuning fork.
        Patch(name: "Ping", baseHz: 340, fmIndex: 0, bodyLevel: 0,
              noiseLevel: 0.06, noiseDecay: 0.02, filterMode: .bandpass,
              cutoffHz: 250, resonance: 0.72, cutoffSweep: 0.08, pingLevel: 1.0,
              level: 0.75, drive: 1.25),

        // A woodblock is a click with a pitch, not a pitch with a click. This
        // was the latter: 1.6 kHz ringing for a fifth of a second, which is the
        // high-pitched ping you could hear across a room.
        Patch(name: "Clave", baseHz: 1_000, bodyLevel: 0,
              noiseLevel: 0.10, noiseDecay: 0.005, filterMode: .bandpass,
              cutoffHz: 1_050, resonance: 0.58, pingLevel: 0.85,
              level: 0.72, drive: 1.35),

        // A resonant lowpass is the one filter mode in the rack whose output is
        // not gain-compensated, and this patch was asking for a Q of twenty at
        // 420 Hz — twenty-odd decibels of ring, on noise, in the band the ear
        // is least forgiving about. It measured as two to three times the
        // 250–800 Hz energy of anything else in the bank, which is why it
        // arrived over the top of the kit rather than underneath it. Less
        // resonance, less noise into it, and a shorter tail: still the low
        // crushed one, no longer the loudest thing in the room.
        Patch(name: "Rumble", baseHz: 68, ratio: 0.51, fmIndex: 1.1, fmDecay: 0.08,
              drop: 0.6, dropTime: 0.06, fold: 0.2, bodyDecay: 0.28, bodyLevel: 0.6,
              noiseLevel: 0.62, noiseDecay: 0.16, filterMode: .lowpass,
              cutoffHz: 420, resonance: 0.30, cutoffSweep: 2.0, crush: 0.32,
              level: 0.68, drive: 1.35),

        Patch(name: "Grit", baseHz: 180, bodyLevel: 0,
              noiseLevel: 1.0, noiseDecay: 0.11, filterMode: .bandpass,
              cutoffHz: 1_700, resonance: 0.5, cutoffSweep: 1.6, crush: 0.6,
              level: 0.62, drive: 1.6),

        Patch(name: "Static", baseHz: 200, bodyLevel: 0,
              noiseLevel: 0.95, noiseDecay: 0.022, filterMode: .highpass,
              cutoffHz: 4_200, resonance: 0.30, cutoffSweep: 0.5, crush: 0.18,
              level: 0.85, drive: 1.25),

        Patch(name: "Wash", baseHz: 200, bodyLevel: 0,
              noiseLevel: 0.8, noiseDecay: 0.9, filterMode: .highpass,
              cutoffHz: 3_600, resonance: 0.2, cutoffSweep: 1.1, crush: 0.10,
              level: 0.6, drive: 1.1),

        // Shorter than it was, and that is the fix for a cymbal that dominated
        // a mix it was never the loudest thing in: at 1.9 seconds it rang
        // through every gap and overlapped itself, so it was *always* present
        // while the drums were only sometimes. Its peak was already below the
        // kick's; duration was doing the work.
        Patch(name: "Metal", baseHz: 300, bodyLevel: 0,
              noiseLevel: 0.26, noiseDecay: 0.5, filterMode: .highpass,
              cutoffHz: 5_600, resonance: 0.25, cutoffSweep: 0.6,
              metalLevel: 0.8, metalDecay: 0.95, metalHz: 372,
              level: 0.42, drive: 1.2),

        Patch(name: "Shatter", baseHz: 240, ratio: 2.37, fmIndex: 4.0, fmDecay: 0.02,
              drop: 0.4, dropTime: 0.02, fold: 0.6, ring: 0.4,
              bodyDecay: 0.12, bodyLevel: 0.5,
              noiseLevel: 0.6, noiseDecay: 0.09, filterMode: .bandpass,
              cutoffHz: 3_100, resonance: 0.45, cutoffSweep: 1.4, crush: 0.7,
              metalLevel: 0.30, metalDecay: 0.26, metalHz: 610,
              level: 0.55, drive: 1.7),
    ]

    static func named(_ name: String) -> Patch {
        bank.first { $0.name == name } ?? bank[0]
    }

    static func defaultPatch(for voice: DrumVoice) -> Patch {
        switch voice {
        case .bass:      return named("Thump")
        case .snare:     return named("Iterate")
        case .rim:       return named("Clave")
        case .lowTom:    return named("Fold")
        case .midTom:    return named("Muffle")
        case .highTom:   return named("Tine")
        case .closedHat: return named("Static")
        case .openHat:   return named("Wash")
        case .cymbal:    return named("Metal")
        }
    }
}

/// A lane's user-facing settings: which patch, and four macros over it. The
/// macros are deliberately few — this is a rack, and a rack with a hundred
/// knobs is not playable.
struct LaneSettings: Codable, Equatable {
    var patchName: String
    /// Pitch and brightness together, 0.5 … 2 as a multiplier on every
    /// frequency in the patch. One knob, because on a percussion voice pitch
    /// and brightness are the same gesture.
    var tone: Double = 1.0
    /// Harmonic aggression: scales the wavefolder and the FM index.
    var fold: Double = 1.0
    /// Noise level and sample-and-hold crush together.
    var grit: Double = 1.0
    /// Multiplier on every decay in the patch.
    var decay: Double = 1.0
    var level: Double = 1.0
    /// Stereo placement, -1 … 1. Starts at the lane's default position.
    var pan: Double = 0
    var muted: Bool = false
    /// The note this lane sends on MIDI out. General MIDI to begin with, but a
    /// Eurorack drum module rarely follows GM, so it is editable.
    var midiNote: Int = 36

    var patch: Patch { Patch.named(patchName) }

    static func `default`(for voice: DrumVoice) -> LaneSettings {
        LaneSettings(patchName: Patch.defaultPatch(for: voice).name,
                     level: voice.defaultLevel,
                     pan: Double(voice.pan),
                     midiNote: voice.defaultNote)
    }
}
