import SwiftUI
import simd

/// The nine lanes of the machine.
///
/// The taxonomy is inherited from Phonotropic, and it is worth saying why a
/// modular-voiced instrument keeps drum-kit names at all: the names are how the
/// pattern corpus, the MIDI note map and the budget's low→high axis all line up.
/// A lane called `snare` is a *position* in the kit — mid-register, backbeat-ish,
/// answers the low lane — not a promise about the sound. What it actually sounds
/// like is whatever patch is loaded into it (see `Patch`), and that is usually
/// nothing like a snare drum.
enum DrumVoice: String, CaseIterable, Codable, Identifiable {
    case bass
    case snare
    case rim
    case lowTom
    case midTom
    case highTom
    case closedHat
    case openHat
    case cymbal

    var id: String { rawValue }

    /// Lanes top-to-bottom in the grid: brightest at the top, lowest at the
    /// bottom, which is also the axis the director's `tilt` gesture slides along.
    static var laneOrder: [DrumVoice] {
        [.cymbal, .openHat, .closedHat, .highTom, .midTom, .lowTom, .rim, .snare, .bass]
    }

    var label: String {
        switch self {
        case .bass:      return "Low"
        case .snare:     return "Body"
        case .rim:       return "Edge"
        case .lowTom:    return "Tom I"
        case .midTom:    return "Tom II"
        case .highTom:   return "Tom III"
        case .closedHat: return "Tick"
        case .openHat:   return "Sustain"
        case .cymbal:    return "Air"
        }
    }

    var short: String {
        switch self {
        case .bass:      return "LO"
        case .snare:     return "BD"
        case .rim:       return "ED"
        case .lowTom:    return "T1"
        case .midTom:    return "T2"
        case .highTom:   return "T3"
        case .closedHat: return "TK"
        case .openHat:   return "SU"
        case .cymbal:    return "AR"
        }
    }

    /// Register, 0 (lowest lane) … 1 (highest). The `tilt` gesture reallocates
    /// the budget along this axis, so it has to be a real number rather than
    /// just the lane order.
    var register: Double {
        switch self {
        case .bass:      return 0.00
        case .snare:     return 0.22
        case .rim:       return 0.34
        case .lowTom:    return 0.30
        case .midTom:    return 0.45
        case .highTom:   return 0.58
        case .closedHat: return 0.78
        case .openHat:   return 0.86
        case .cymbal:    return 1.00
        }
    }

    /// Hue used across the interface for this lane.
    var color: Color {
        switch self {
        case .bass:      return Color(hue: 0.03, saturation: 0.72, brightness: 0.96)
        case .snare:     return Color(hue: 0.09, saturation: 0.76, brightness: 0.97)
        case .rim:       return Color(hue: 0.14, saturation: 0.68, brightness: 0.95)
        case .lowTom:    return Color(hue: 0.30, saturation: 0.58, brightness: 0.86)
        case .midTom:    return Color(hue: 0.42, saturation: 0.60, brightness: 0.86)
        case .highTom:   return Color(hue: 0.52, saturation: 0.62, brightness: 0.89)
        case .closedHat: return Color(hue: 0.60, saturation: 0.54, brightness: 0.93)
        case .openHat:   return Color(hue: 0.71, saturation: 0.54, brightness: 0.93)
        case .cymbal:    return Color(hue: 0.82, saturation: 0.44, brightness: 0.96)
        }
    }

    /// Default stereo placement. Kept modest — a wide kit stops sounding like
    /// one instrument.
    var pan: Float {
        switch self {
        case .bass:      return  0.00
        case .snare:     return -0.05
        case .rim:       return  0.30
        case .lowTom:    return -0.45
        case .midTom:    return -0.12
        case .highTom:   return  0.28
        case .closedHat: return  0.42
        case .openHat:   return  0.50
        case .cymbal:    return -0.55
        }
    }

    /// Where this lane sits in the room, for the spatial field: x is left and
    /// right, y up and down, z front and back (negative is in front of you).
    ///
    /// A believable kit rather than a wide one. The low lane is centred and
    /// close because that is where a kick belongs and because bass carries no
    /// directional information anyway; the toms sweep across; the bright lanes
    /// sit out to the sides and slightly up, where cymbals are. The listener's
    /// own Pan control slides a lane along x from here.
    var spatialPosition: SIMD3<Float> {
        switch self {
        case .bass:      return SIMD3( 0.00, -0.20, -0.85)
        case .snare:     return SIMD3( 0.00,  0.00, -1.00)
        case .rim:       return SIMD3( 0.35,  0.05, -1.00)
        case .lowTom:    return SIMD3(-1.20,  0.15, -1.10)
        case .midTom:    return SIMD3(-0.35,  0.25, -1.25)
        case .highTom:   return SIMD3( 0.55,  0.35, -1.25)
        case .closedHat: return SIMD3( 1.25,  0.25, -0.95)
        case .openHat:   return SIMD3( 1.50,  0.40, -1.10)
        case .cymbal:    return SIMD3(-1.60,  0.75, -1.20)
        }
    }

    /// Where this lane sits in the kit's balance, before any patch is loaded.
    ///
    /// A kit is not nine equal voices. The bright lanes are the ones that
    /// dominate an unbalanced mix — they ring longest and sit where the ear is
    /// most sensitive — so they come in under the drums by default, the way a
    /// drummer sets up their own kit rather than the way a synthesiser defaults.
    var defaultLevel: Double {
        switch self {
        case .bass:      return 1.00
        case .snare:     return 1.00
        case .rim:       return 0.92
        case .lowTom:    return 1.00
        case .midTom:    return 0.98
        case .highTom:   return 0.95
        case .closedHat: return 0.90
        case .openHat:   return 0.82
        case .cymbal:    return 0.72
        }
    }

    /// General MIDI percussion note, the starting point for the editable note
    /// map. A Eurorack drum module rarely follows GM, which is exactly why the
    /// map is editable in the MIDI panel.
    var defaultNote: Int {
        switch self {
        case .bass:      return 36   // Bass Drum 1
        case .snare:     return 38   // Acoustic Snare
        case .rim:       return 37   // Side Stick
        case .lowTom:    return 41   // Low Floor Tom
        case .midTom:    return 45   // Low Tom
        case .highTom:   return 48   // Hi-Mid Tom
        case .closedHat: return 42   // Closed Hi-Hat
        case .openHat:   return 46   // Open Hi-Hat
        case .cymbal:    return 49   // Crash Cymbal 1
        }
    }

    /// Which lane an incoming corpus track counts toward, so 214 transcribed
    /// drum-machine patterns can act as placement priors for these nine lanes.
    static func fromPatternTrack(_ name: String) -> DrumVoice? {
        switch name {
        case "BassDrum":    return .bass
        case "SnareDrum":   return .snare
        case "RimShot":     return .rim
        case "Clap":        return .rim
        case "LowTom":      return .lowTom
        case "MediumTom":   return .midTom
        case "HighTom":     return .highTom
        case "ClosedHiHat": return .closedHat
        case "OpenHiHat":   return .openHat
        case "Cymbal":      return .cymbal
        case "Cowbell":     return .midTom
        case "Tambourine":  return .closedHat
        default:            return nil
        }
    }

    /// Lanes that may play a flam (two attacks a tick apart). On a modular
    /// voice a flam reads as a stutter rather than a drum roll, so it is kept
    /// away from the sustaining lanes where it would just sound like a glitch.
    var allowsFlam: Bool {
        switch self {
        case .snare, .rim, .lowTom, .midTom, .highTom, .closedHat: return true
        case .bass, .openHat, .cymbal: return false
        }
    }
}
