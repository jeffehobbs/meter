import SwiftUI

/// One lane's module. A patch and four macros — deliberately few, because a
/// rack with a hundred knobs is not playable, and because the director is also
/// turning these and it should be possible to see it happen.
struct RackPanel: View {
    @ObservedObject var engine: MeterEngine

    private var voice: DrumVoice { engine.selectedLane }
    private var lane: LaneSettings { engine.kit[voice] ?? .default(for: voice) }

    var body: some View {
        Panel(title: "Module — \(voice.label)", trailing: lane.patchName) {
            VStack(alignment: .leading, spacing: 10) {
                patchGrid
                Divider().overlay(Theme.hairline)
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 6) {
                        Dial(title: "Tone", value: macro(.tone), range: 0.4...2.2,
                             format: { String(format: "%.2f×", $0) }, live: engine.evolvePatches)
                        Dial(title: "Fold", value: macro(.fold), range: 0...2,
                             format: { String(format: "%.2f", $0) }, live: engine.evolvePatches)
                    }
                    VStack(spacing: 6) {
                        Dial(title: "Grit", value: macro(.grit), range: 0...2,
                             format: { String(format: "%.2f", $0) }, live: engine.evolvePatches)
                        Dial(title: "Decay", value: macro(.decay), range: 0.2...2.4,
                             format: { String(format: "%.2f×", $0) }, live: engine.evolvePatches)
                    }
                    VStack(spacing: 6) {
                        Dial(title: "Level", value: binding(\.level), range: 0...1.6,
                             format: { String(format: "%.2f", $0) })
                        Dial(title: "Pan", value: binding(\.pan), range: -1...1,
                             format: { String(format: "%+.2f", $0) })
                    }
                }
                HStack(spacing: 8) {
                    Pill(title: lane.muted ? "muted" : "live",
                         isOn: Binding(get: { !lane.muted },
                                       set: { on in engine.update(voice) { $0.muted = !on } }))
                    Tap(title: "hit", tint: voice.color) { engine.audition(voice) }
                    Spacer()
                    Theme.label("MIDI note")
                    Stepper(value: Binding(get: { lane.midiNote },
                                           set: { n in engine.update(voice) { $0.midiNote = n } }),
                            in: 0...127) {
                        Theme.readout("\(lane.midiNote)", size: 10)
                    }
                    .controlSize(.mini)
                    .fixedSize()
                }
            }
        }
    }

    private var patchGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
            ForEach(Patch.bank) { patch in
                let on = patch.name == lane.patchName
                Button { engine.setPatch(patch.name, for: voice) } label: {
                    Text(patch.name)
                        .font(.system(size: 9, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.background : Theme.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(on ? voice.color.opacity(0.85) : Color.white.opacity(0.045))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func binding(_ path: WritableKeyPath<LaneSettings, Double>) -> Binding<Double> {
        Binding(get: { lane[keyPath: path] },
                set: { value in engine.update(voice) { $0[keyPath: path] = value } })
    }

    private func macro(_ macro: Macro) -> Binding<Double> {
        switch macro {
        case .tone:  return binding(\.tone)
        case .fold:  return binding(\.fold)
        case .grit:  return binding(\.grit)
        case .decay: return binding(\.decay)
        // Pan has its own control below; the director drifts it through the
        // same mechanism, which is why it is a macro at all.
        case .pan:   return binding(\.pan)
        }
    }
}
