import AVKit
import Cadence
import SwiftUI

/// The whole app.
///
/// One ring, one knob and a play button. The ring is the Mac app's allocation
/// bar bent into a circle: the outer band is who currently holds the budget, the
/// inner ticks are the attacks this measure actually spent, and the lamp goes
/// round once a bar. Watching it is optional — the reason it exists is that when
/// you do look, you can see the machine thinking.
struct FlowView: View {
    @ObservedObject var host: FlowHost
    @State private var tuning = false
    @State private var marked = false
    /// The simulator has no way to tap anything, so the two screens this app has
    /// are reachable from the environment for the sake of being able to look at
    /// a build. See also METER_AUTOPLAY in FlowHost.
    private let opensTuning = ProcessInfo.processInfo.environment["METER_TUNING"] != nil

    var body: some View {
        ZStack {
            Flow.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                ring
                Spacer(minLength: 0)
                controls
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
        // "This. What it is doing right now." Undiscoverable on purpose: a
        // diagnostic rather than a feature. Three taps rather than two, because
        // the screen is covered in one-tap targets and a false mark is a lie in
        // the log.
        .contentShape(Rectangle())
        .onTapGesture(count: 3) {
            host.logMoment()
            marked = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { marked = false }
        }
        .overlay(alignment: .top) {
            if marked {
                Text("logged")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(Flow.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Flow.live))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: marked)
        .onAppear { if opensTuning { tuning = true } }
        .sheet(isPresented: $tuning) {
            NavigationStack {
                CadenceTuningView(cadence: host.cadence)
                    .navigationTitle("Your pulse")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { tuning = false }
                        }
                    }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("METER")
                .font(.system(size: 14, weight: .heavy))
                .tracking(3.6)
                .foregroundStyle(Flow.text)
            Spacer()
            sleepButton
            Button { tuning = true } label: {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 17))
                    .foregroundStyle(host.followsPulse ? Flow.pulse : Flow.dim)
                    .frame(width: 34, height: 34)
            }
        }
        .padding(.top, 4)
    }

    /// Cycles rather than opens a picker: four states is not worth a sheet, and
    /// a thing you set on the way to sleep should take one tap.
    private var sleepButton: some View {
        Button {
            let steps = [0, 20, 45, 90]
            let next = (steps.firstIndex(of: host.sleepMinutes).map { $0 + 1 } ?? 1) % steps.count
            host.sleepMinutes = steps[next]
        } label: {
            HStack(spacing: 4) {
                Image(systemName: host.sleepMinutes == 0 ? "infinity" : "moon.zzz")
                    .font(.system(size: 13))
                if let remaining = host.sleepRemaining {
                    Text("\(Int(remaining / 60) + 1)m")
                        .font(.system(size: 12, design: .monospaced))
                } else if host.sleepMinutes > 0 {
                    Text("\(host.sleepMinutes)m")
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            .foregroundStyle(host.sleepMinutes == 0 ? Flow.dim : Flow.live)
            .frame(height: 34)
            .padding(.horizontal, 8)
        }
    }

    // MARK: - The ring

    private var ring: some View {
        ZStack {
            AllocationRing(measure: host.measure, shares: host.shares,
                           pulse: host.pulse, levels: host.levels)
            VStack(spacing: 2) {
                Text("\(Int(host.tempo.rounded()))")
                    .font(.system(size: 68, weight: .ultraLight, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Flow.text)
                if host.followsPulse, host.cadence.estimate.source == .measured {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Flow.pulse)
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .padding(.vertical, 4)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                HStack {
                    Flow.label("density")
                    Spacer()
                    Text("\(Int(host.budget)) per bar")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Flow.text)
                }
                Slider(value: $host.budget, in: 3...36, step: 1)
                    .tint(Flow.accent)
            }

            VStack(spacing: 5) {
                Toggle(isOn: $host.followsPulse) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 12))
                        Text("Follow my pulse")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(Flow.text)
                }
                .tint(Flow.pulse)

                if !host.followsPulse {
                    HStack {
                        Flow.label("tempo")
                        Spacer()
                        Text("\(Int(host.tempo.rounded())) bpm")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Flow.text)
                    }
                    Slider(value: $host.tempo, in: 50...170, step: 1)
                        .tint(Flow.accent)
                }
            }

            VStack(spacing: 8) {
                Button { host.toggle() } label: {
                    Image(systemName: host.playback == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Flow.background)
                        .frame(width: 74, height: 74)
                        .background(Circle().fill(host.playback == .playing ? Flow.accent : Flow.text))
                }
                Output(host: host)
            }
            .padding(.top, 2)
        }
    }
}

/// The allocation, the measure and the playhead, drawn in one canvas.
///
/// Same reasoning as the Mac app's grid: this redraws fifteen times a second,
/// and as a stack of shapes that would be fifteen layout passes a second for
/// something that never changes size.
private struct AllocationRing: View {
    let measure: Measure
    let shares: [DrumVoice: Double]
    @ObservedObject var pulse: Pulse
    @ObservedObject var levels: Levels

    private var lanes: [DrumVoice] { DrumVoice.laneOrder.reversed() }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 6
            let bandWidth = outer * 0.10
            let bandRadius = outer - bandWidth / 2
            let tickRadius = bandRadius - bandWidth * 1.5

            // The budget, as arcs. Low lanes start at the top and it runs
            // clockwise into the bright ones, which is the same left-to-right
            // order the Mac app's bar uses.
            let total = max(0.0001, lanes.reduce(0.0) { $0 + (shares[$1] ?? 0) })
            var angle = -90.0
            for lane in lanes {
                let share = (shares[lane] ?? 0) / total
                let sweep = share * 360
                guard sweep > 0.4 else { angle += sweep; continue }
                let index = DrumVoice.allCases.firstIndex(of: lane) ?? 0
                let energy = Double(levels.glow[safe: index] ?? 0)
                let played = (measure.counts[lane] ?? 0) > 0
                var path = Path()
                path.addArc(center: center, radius: bandRadius,
                            startAngle: .degrees(angle + 0.6),
                            endAngle: .degrees(angle + sweep - 0.6), clockwise: false)
                context.stroke(path, with: .color(lane.color.opacity(
                    (played ? 0.5 : 0.16) + min(0.5, energy * 1.6))),
                               style: StrokeStyle(lineWidth: bandWidth, lineCap: .butt))
                angle += sweep
            }

            // The measure itself: one tick per attack, at the angle of the step
            // it lands on, brightness by how hard it is hit.
            let steps = max(1, measure.signature.steps)
            for hit in measure.hits {
                let position = Double(hit.step) / Double(steps)
                let a = (position * 360 - 90) * .pi / 180
                let length = bandWidth * (hit.flam ? 1.15 : 0.8)
                let inner = tickRadius - length / 2
                let start = CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner)
                let end = CGPoint(x: center.x + cos(a) * (inner + length),
                                  y: center.y + sin(a) * (inner + length))
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .color(hit.voice.color.opacity(0.25 + 0.7 * hit.velocity)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // The playhead, once round the bar.
            let a = (Double(pulse.step) / Double(steps) * 360 - 90) * .pi / 180
            let dot = CGPoint(x: center.x + cos(a) * (bandRadius - bandWidth * 0.9),
                              y: center.y + sin(a) * (bandRadius - bandWidth * 0.9))
            context.fill(Path(ellipseIn: CGRect(x: dot.x - 3.5, y: dot.y - 3.5,
                                                width: 7, height: 7)),
                         with: .color(Flow.live))
        }
    }
}


/// Where the sound is going, and whether there is any.
///
/// This exists because of a real morning spent wondering why an app that was
/// working perfectly made no sound: it was playing, at full level, into a
/// Bluetooth speaker in another room. A passive-listening app is exactly where
/// that happens, and the phone never volunteers the answer.
private struct Output: View {
    @ObservedObject var host: FlowHost
    @ObservedObject private var levels: Levels

    init(host: FlowHost) {
        self.host = host
        self.levels = host.levels
    }

    var body: some View {
        HStack(spacing: 7) {
            // The system's own output picker. An app that plays into whatever
            // the phone last decided to connect to needs a way to say
            // "not there, here" without leaving for Settings.
            RoutePicker()
                .frame(width: 22, height: 22)
            Text(host.routeName.isEmpty ? "no output" : host.routeName)
                .font(.system(size: 11))
                .lineLimit(1)
            // Not a decoration: a level that moves is the difference between
            // "it is playing somewhere else" and "it is not playing".
            Capsule()
                .fill(Flow.faint)
                .frame(width: 34, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(host.playback == .playing ? Flow.accent : Flow.faint)
                        .frame(width: 34 * CGFloat(min(1, levels.output)), height: 3)
                }
        }
        .foregroundStyle(Flow.dim)
    }

}

/// `AVRoutePickerView`, which is the only supported way to offer this — the
/// output picker is a system sheet and an app cannot present it itself.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(Flow.dim)
        view.activeTintColor = UIColor(Flow.accent)
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
