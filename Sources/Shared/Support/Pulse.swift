import Foundation

/// The playhead. Changes once per step — a few times a second.
///
/// It is deliberately a separate object from `Levels`. Anything that reads a
/// published property is re-evaluated when *any* property of that object
/// changes, so putting the step and the level meter together meant the whole
/// step grid was redrawn at the meter's rate rather than at the music's. Split,
/// the expensive drawing happens when the music moves and the cheap drawing
/// happens when the level does.
@MainActor
final class Pulse: ObservableObject {
    @Published var step = 0
}

/// The output level and the per-lane hit lamps: twenty times a second, but only
/// ever feeding two small canvases.
@MainActor
final class Levels: ObservableObject {
    /// What the rack produced.
    @Published var peak: Float = 0
    /// What actually left the graph, measured at the mixer. The two are
    /// different questions, and "I can't hear anything" is answered by the
    /// second one.
    @Published var output: Float = 0
    @Published var glow = [Float](repeating: 0, count: DrumVoice.allCases.count)
}

extension Array {
    /// Bounds-checked lookup, for the lamp arrays: the interface and the render
    /// thread agree on nine lanes, and a stale copy of one of them during a
    /// reconfiguration should dim a lamp rather than crash the app.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
