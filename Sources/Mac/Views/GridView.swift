import SwiftUI

/// The measure as it stands.
///
/// Read-only on purpose: the grid is a readout, not an editor. Nothing here is a
/// pattern the player drew, so there is nothing here to draw — what you get
/// instead is a clear view of where the budget went, and a playhead to follow.
///
/// The split between this and `GridCanvas` below is about cost, and it is worth
/// spelling out because it is not obvious. The cells are drawn in one `Canvas`
/// rather than as a hundred and forty-four views, and — separately — the lane
/// buttons deliberately do *not* watch the playhead. When they did, every one of
/// them was measured and placed twenty times a second, and that layout work cost
/// several times more processor time than every voice in the rack put together.
struct GridView: View {
    let measure: Measure
    let selected: DrumVoice
    let onSelect: (DrumVoice) -> Void
    let isMuted: (DrumVoice) -> Bool
    let pulse: Pulse
    let levels: Levels

    static let laneHeight: CGFloat = 22
    static let laneGap: CGFloat = 3
    static let headerHeight: CGFloat = 11
    /// Width of the lamp strip. The lamps are drawn rather than laid out, and in
    /// their own canvas, so that neither the lane labels nor the step grid is
    /// touched when one of them flashes.
    static let gutter: CGFloat = 13

    private var lanes: [DrumVoice] { DrumVoice.laneOrder }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: Self.laneGap) {
                Spacer().frame(height: Self.headerHeight)
                ForEach(lanes) { label($0) }
            }
            .frame(width: 62)

            LampStrip(isMuted: isMuted, levels: levels)
                .frame(width: Self.gutter)

            GridCanvas(measure: measure, isMuted: isMuted, pulse: pulse)
        }
    }

    private func label(_ voice: DrumVoice) -> some View {
        Button { onSelect(voice) } label: {
            HStack(spacing: 0) {
                Text(voice.label)
                    .font(.system(size: 10, weight: voice == selected ? .semibold : .regular))
                    .foregroundStyle(isMuted(voice) ? Theme.faint
                                                    : (voice == selected ? Theme.text : Theme.dim))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(height: Self.laneHeight)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(voice == selected ? Color.white.opacity(0.055) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Everything that moves: the cells, the playhead and the lane lamps, all in one
/// canvas that redraws without laying anything out.
private struct GridCanvas: View {
    let measure: Measure
    let isMuted: (DrumVoice) -> Bool
    @ObservedObject var pulse: Pulse

    private var lanes: [DrumVoice] { DrumVoice.laneOrder }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: context, size: size)
        }
        .frame(height: GridView.headerHeight
               + CGFloat(lanes.count) * (GridView.laneHeight + GridView.laneGap))
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let steps = max(1, measure.signature.steps)
        let gap: CGFloat = 3
        let laneHeight = GridView.laneHeight
        let laneGap = GridView.laneGap
        let headerHeight = GridView.headerHeight
        let cellWidth = (size.width - CGFloat(steps - 1) * gap) / CGFloat(steps)
        guard cellWidth > 1 else { return }
        let starts = measure.signature.groupStarts

        // Pulse numbers along the top, one per group of the meter.
        var group = 0
        for step in 0..<steps where starts.contains(step) {
            group += 1
            let x = CGFloat(step) * (cellWidth + gap)
            var text = context.resolve(
                Text("\(group)").font(.system(size: 8, weight: .medium, design: .monospaced)))
            text.shading = .color(step == pulse.step ? Theme.live : Theme.faint)
            context.draw(text, at: CGPoint(x: x + cellWidth / 2, y: headerHeight / 2))
        }

        // A hit lookup, so the inner loop is not a linear scan per cell.
        var placed: [DrumVoice: [Int: Hit]] = [:]
        for hit in measure.hits { placed[hit.voice, default: [:]][hit.step] = hit }

        for (row, voice) in lanes.enumerated() {
            let y = headerHeight + CGFloat(row) * (laneHeight + laneGap)
            let muted = isMuted(voice)

            for step in 0..<steps {
                let x = CGFloat(step) * (cellWidth + gap)
                let cell = CGRect(x: x, y: y, width: cellWidth, height: laneHeight)
                let strong = starts.contains(step)
                let playing = step == pulse.step

                let well = RoundedRectangle(cornerRadius: 2).path(in: cell)
                context.fill(well, with: .color(playing ? Theme.live.opacity(0.13)
                                                        : (strong ? Color.white.opacity(0.035)
                                                                  : Theme.well)))
                if strong { context.stroke(well, with: .color(Theme.hairline), lineWidth: 1) }

                guard let hit = placed[voice]?[step] else { continue }
                let opacity = muted ? 0.14 : (0.28 + 0.72 * hit.velocity)
                if hit.flam {
                    // A flam is two attacks and costs two units of budget, so it
                    // is drawn as two.
                    let inset = cell.insetBy(dx: 2, dy: 2)
                    let half = (inset.width - 1.5) / 2
                    let left = CGRect(x: inset.minX, y: inset.minY, width: half, height: inset.height)
                    let right = CGRect(x: inset.minX + half + 1.5, y: inset.minY,
                                       width: half, height: inset.height)
                    context.fill(RoundedRectangle(cornerRadius: 1).path(in: left),
                                 with: .color(voice.color.opacity(opacity)))
                    context.fill(RoundedRectangle(cornerRadius: 1).path(in: right),
                                 with: .color(voice.color.opacity(opacity * 0.7)))
                } else {
                    context.fill(RoundedRectangle(cornerRadius: 2)
                        .path(in: cell.insetBy(dx: 1.5, dy: 1.5)),
                                 with: .color(voice.color.opacity(opacity)))
                }
            }
        }
    }
}


/// The nine hit lamps. Its own canvas so that a flash — twenty times a second —
/// redraws thirteen points of width and nothing else.
private struct LampStrip: View {
    let isMuted: (DrumVoice) -> Bool
    @ObservedObject var levels: Levels

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            for (row, voice) in DrumVoice.laneOrder.enumerated() {
                let y = GridView.headerHeight
                    + CGFloat(row) * (GridView.laneHeight + GridView.laneGap)
                let index = DrumVoice.allCases.firstIndex(of: voice) ?? 0
                let energy = Double(levels.glow[safe: index] ?? 0)
                let lamp = CGRect(x: (size.width - 7) / 2, y: y + GridView.laneHeight / 2 - 3.5,
                                  width: 7, height: 7)
                context.fill(Path(ellipseIn: lamp),
                             with: .color(voice.color.opacity(
                                isMuted(voice) ? 0.15 : 0.30 + min(0.70, energy * 2.4))))
            }
        }
        .frame(height: GridView.headerHeight
               + CGFloat(DrumVoice.allCases.count) * (GridView.laneHeight + GridView.laneGap))
    }
}
