import SwiftUI

/// The budget, drawn.
///
/// One bar, the width of the window, divided into a segment per lane in
/// proportion to what that lane was given this measure. Because the total is
/// fixed, the segments can only ever push each other around — which is exactly
/// what the director is doing, and watching it is how the idea of the program
/// becomes obvious in about ten seconds.
struct BudgetBar: View {
    let shares: [DrumVoice: Double]
    let counts: [DrumVoice: Int]
    @ObservedObject var levels: Levels

    /// Low at the left, bright at the right: the axis the tilt gesture slides
    /// along.
    private var lanes: [DrumVoice] { DrumVoice.laneOrder.reversed() }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let total = max(0.0001, lanes.reduce(0.0) { $0 + (shares[$1] ?? 0) })
            var x: CGFloat = 0
            for voice in lanes {
                let share = (shares[voice] ?? 0) / total
                let width = max(0, size.width * share - 1)
                guard width > 0.5 else { x += width + 1; continue }
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                let count = counts[voice] ?? 0
                let index = DrumVoice.allCases.firstIndex(of: voice) ?? 0
                let energy = Double(levels.glow[safe: index] ?? 0)

                context.fill(Path(rect), with: .color(voice.color.opacity(count > 0 ? 0.55 : 0.18)))
                if energy > 0.001 {
                    context.fill(Path(rect), with: .color(voice.color.opacity(min(0.45, energy * 1.4))))
                }
                if width > 34 {
                    var text = context.resolve(
                        Text("\(voice.short) \(count)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced)))
                    text.shading = .color(Theme.background.opacity(0.8))
                    context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
                }
                x += width + 1
            }
        }
        .frame(height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .animation(.easeInOut(duration: 0.45), value: shares)
    }
}
