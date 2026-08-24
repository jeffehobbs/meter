import CoreMIDI
import SwiftUI

/// The output level. Its own view, because it is the fastest-changing thing on
/// the screen and nothing else should be re-laid-out on its account.
private struct LevelMeter: View {
    @ObservedObject var levels: Levels

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(levels.peak > 0.97 ? Color.red.opacity(0.8) : Theme.live.opacity(0.75))
                        .frame(width: geo.size.width * CGFloat(min(1, levels.peak)))
                }
            }
            .frame(width: 54, height: 6)
            HStack(spacing: 3) {
                Theme.label("out")
                Text(levels.peak > 0.0005
                     ? String(format: "%.0f", 20 * log10(Double(levels.peak)))
                     : "—")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine: MeterEngine
    @State private var confirmingReset = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Both columns scroll. On a short window the alternative is
            // compression, and what gets compressed first is the header, which
            // is the one part of the interface that has to stay readable.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    budget
                    Panel(title: "Measure", trailing: engine.signatureName) {
                        GridView(measure: engine.measure,
                                 selected: engine.selectedLane,
                                 onSelect: { engine.selectedLane = $0 },
                                 isMuted: { engine.kit[$0]?.muted ?? false },
                                 pulse: engine.pulse,
                                 levels: engine.levels)
                    }
                    RackPanel(engine: engine)
                    activity
                }
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .frame(minWidth: 660)
            .layoutPriority(1)

            controls
                .frame(width: 268)
        }
        .padding(12)
        .background(Theme.background)
        .background(WindowFloor(minSize: NSSize(width: 1_060, height: 720)))
        .foregroundStyle(Theme.text)
        .confirmationDialog("Reset everything to factory defaults?",
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Everything", role: .destructive) { engine.factoryReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The rack, the feel, the tempo and the budget all go back to how they shipped.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { engine.toggleTransport() } label: {
                HStack(spacing: 7) {
                    Image(systemName: engine.running ? "stop.fill" : "play.fill")
                        .font(.system(size: 11))
                    Text(engine.running ? "STOP" : "RUN")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.6)
                }
                .foregroundStyle(engine.running ? Theme.background : Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(engine.running ? Theme.accent : Color.white.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Text("METER")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3.4)

            Spacer()

            stat("\(Int(engine.bpm))", "bpm")
            stat("\(barBudget)", "budget")
            stat("\(engine.measure.spent)", "spent")
            stat("\(engine.measureIndex + 1)", "measure")
            meter
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .light, design: .monospaced))
                .foregroundStyle(Theme.text)
            Theme.label(caption)
        }
        .frame(minWidth: 46, alignment: .trailing)
    }

    private var meter: some View { LevelMeter(levels: engine.levels) }

    /// What this bar was asked to spend, which is what `spent` has to be read
    /// against — otherwise a bar scaled to hold its density through a meter
    /// change reads as "six of five attacks", and the one promise the whole
    /// program rests on looks broken.
    ///
    /// The slider itself when nothing is scaling it, so that dragging it still
    /// moves the number in the same instant rather than at the next downbeat.
    private var barBudget: Int {
        engine.meterMotion.holdsDensity ? engine.measure.budget : Int(engine.budget)
    }

    /// The ten written meters, plus whatever the bar currently is if the machine
    /// walked somewhere the list does not name.
    private var meterChoices: [Signature] {
        Signature.all.contains(engine.signature)
            ? Signature.all
            : Signature.all + [engine.signature]
    }

    // MARK: - Budget

    private var budget: some View {
        Panel(title: "Allocation",
              trailing: "\(engine.measure.spent) / \(barBudget) attacks") {
            VStack(alignment: .leading, spacing: 6) {
                BudgetBar(shares: engine.shares,
                          counts: engine.measure.counts,
                          levels: engine.levels)
                HStack {
                    Theme.label("low")
                    Spacer()
                    Text(engine.temperature > 0.45 ? "off the beat" : "on the beat")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                    Spacer()
                    Theme.label("bright")
                }
            }
        }
    }

    private var activity: some View {
        Panel(title: "Director") {
            VStack(alignment: .leading, spacing: 2) {
                if engine.activity.isEmpty {
                    Text("nothing has moved yet")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                }
                ForEach(Array(engine.activity.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(item.offset == 0 ? Theme.live.opacity(0.9)
                                                          : Theme.dim.opacity(1 - Double(item.offset) * 0.09))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(spacing: 10) {
                Panel(title: engine.flowing ? "The two numbers — flowing" : "The two numbers") {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            Pill(title: "flow", isOn: $engine.flowing, tint: Theme.live)
                                .help("Hand tempo and budget to the machine as well. It moves them on long arcs — minutes, not measures — and a hand on either slider re-centres it rather than fighting it.")
                            Spacer()
                        }
                        Dial(title: "Tempo", value: $engine.bpm, range: 40...200,
                             format: { String(format: "%.0f bpm", $0) }, step: 1,
                             live: engine.flowing)
                        Dial(title: "Budget", value: $engine.budget,
                             range: 1...64, format: { String(format: "%.0f", $0) }, step: 1,
                             live: engine.flowing,
                             hint: engine.meterMotion.holdsDensity
                                 ? "Attacks per bar of four-four. A bar of another length is scaled to match, so the density survives a meter change. The machine spends all of them."
                                 : "Attacks per measure. The machine spends all of them.")
                        HStack(spacing: 4) {
                            Theme.label("meter")
                            Spacer()
                            Picker("", selection: $engine.signature) {
                                // The current bar is listed even when it is not
                                // one of the ten: a walk generates meters that
                                // were never in the list, and a picker that goes
                                // blank is a picker that looks broken.
                                ForEach(meterChoices) { Text($0.name).tag($0) }
                            }
                            .labelsHidden()
                            .controlSize(.mini)
                            .frame(width: 96)
                        }
                        HStack(spacing: 4) {
                            Theme.label("moves")
                            Spacer()
                            Picker("", selection: $engine.meterMotion) {
                                ForEach(MeterMotion.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .controlSize(.mini)
                            .frame(width: 96)
                            .help(engine.meterMotion.hint)
                        }
                    }
                }

                Panel(title: "Reallocation") {
                    VStack(alignment: .leading, spacing: 9) {
                        Dial(title: "Motion", value: $engine.motion,
                             hint: "How often, and how far, the director reallocates.")
                        Dial(title: "Spread", value: $engine.spread,
                             hint: "Whether one lane carries the measure or everybody plays a little.")
                        HStack(spacing: 6) {
                            Pill(title: "evolve", isOn: $engine.evolvePatches)
                                .help("Let the director drift the rack, the feel and the echo over the session, the way Thrum drifts a drone.")
                            Spacer()
                            Tap(title: "nudge", tint: Theme.live) { engine.nudge() }
                            Tap(title: "reseed") { engine.reseed() }
                        }
                    }
                }

                Panel(title: "Feel") {
                    VStack(alignment: .leading, spacing: 7) {
                        Dial(title: "Swing", value: $engine.swing)
                        Dial(title: "Humanize", value: $engine.humanize)
                        Dial(title: "Drift", value: $engine.drift,
                             hint: "How much of last measure each lane throws away.")
                        Dial(title: "Accent", value: $engine.accent)
                        Dial(title: "Flam", value: $engine.flam)
                    }
                }

                Panel(title: "Rack") {
                    VStack(alignment: .leading, spacing: 8) {
                        Dial(title: "Volume", value: $engine.volume)
                        Dial(title: "Room", value: $engine.reverb, range: 0...60,
                             format: { String(format: "%.0f%%", $0) })
                        Dial(title: "Echo", value: $engine.echo, range: 0...60,
                             format: { String(format: "%.0f%%", $0) })
                        Tap(title: "repatch everything") { engine.randomizeKit() }
                    }
                }

                Panel(title: "Output", trailing: engine.destinationLabel) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $engine.route) {
                            ForEach(Route.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.mini)

                        HStack(spacing: 4) {
                            Theme.label("to")
                            Spacer()
                            Picker("", selection: Binding(
                                get: { engine.selectedDestination ?? -1 },
                                set: { engine.select(destination: $0 == -1 ? nil : $0) })) {
                                Text("Meter Out (virtual)").tag(MIDIUniqueID(-1))
                                ForEach(engine.destinations) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                            .controlSize(.mini)
                            .frame(width: 150)
                            .help("Meter always publishes a virtual source named “Meter Out”. Pick a destination to also send straight to hardware.")
                        }

                        HStack(spacing: 6) {
                            Theme.label("channel")
                            Stepper(value: $engine.midiChannel, in: 1...16) {
                                Theme.readout("\(engine.midiChannel)", size: 10)
                            }
                            .controlSize(.mini)
                            .fixedSize()
                            Spacer()
                            Pill(title: "clock", isOn: $engine.sendsClock)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Tap(title: "factory reset", tint: Theme.warn) { confirmingReset = true }
                }
                .padding(.top, 2)
            }
        }
        .scrollIndicators(.never)
    }
}
