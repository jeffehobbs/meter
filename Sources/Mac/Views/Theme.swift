import SwiftUI

/// One place for the palette and the type, so the window reads as a single
/// panel rather than a stack of controls. The reference is a rack: dark
/// anodized aluminum, silkscreened labels too small to shout, and the only
/// bright things are the ones that are actually moving.
enum Theme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.064)
    static let panel = Color(red: 0.086, green: 0.090, blue: 0.099)
    static let well = Color(red: 0.043, green: 0.045, blue: 0.050)
    static let hairline = Color.white.opacity(0.075)
    static let text = Color.white.opacity(0.90)
    static let dim = Color.white.opacity(0.44)
    static let faint = Color.white.opacity(0.20)
    /// Structure — anything the player set.
    static let accent = Color(red: 0.42, green: 0.83, blue: 0.80)
    /// Motion — anything the machine is doing right now.
    static let live = Color(red: 0.98, green: 0.72, blue: 0.32)
    /// The one destructive control.
    static let warn = Color(red: 0.91, green: 0.45, blue: 0.40)

    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.8)
            .foregroundStyle(Theme.dim)
    }

    static func readout(_ text: String, size: CGFloat = 11) -> some View {
        Text(text)
            .font(.system(size: size, weight: .regular, design: .monospaced))
            .foregroundStyle(Theme.text)
    }
}

/// A framed section of the panel.
struct Panel<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Theme.label(title)
                Spacer(minLength: 8)
                if let trailing { Theme.readout(trailing, size: 10) }
            }
            content()
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline, lineWidth: 1))
        )
    }
}

/// Compact labeled slider. The readout is monospaced so a value that is being
/// ramped by the director does not make the row twitch.
struct Dial: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var step: Double = 0
    /// True when the machine, not the player, is moving this.
    var live: Bool = false
    /// What the control does, for the pointer. Explanations belong in a tooltip,
    /// not printed under the label.
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Theme.label(title)
                Spacer()
                Text(format(value))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(live ? Theme.live : Theme.text)
            }
            if step > 0 {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
        .tint((live ? Theme.live : Theme.accent).opacity(0.7))
        .controlSize(.mini)
        .help(hint ?? "")
    }
}

/// Flat toggle pill. The on state carries the accent, so what is armed is
/// readable without reading.
struct Pill: View {
    let title: String
    @Binding var isOn: Bool
    var tint: Color = Theme.accent

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(isOn ? Theme.background : Theme.dim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isOn ? tint.opacity(0.9) : Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }
}

/// A momentary button, for the things that are gestures rather than states.
struct Tap: View {
    let title: String
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(tint.opacity(0.45), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// A floor under the window size.
///
/// AppKit restores a saved window frame before SwiftUI's content minimum gets a
/// say, and a restored frame can be smaller than the interface can survive — a
/// 109-point-wide Meter is not an instrument. Setting `minSize` on the real
/// window is the only thing that actually holds, so the interface reaches down
/// through the representable to do it.
struct WindowFloor: NSViewRepresentable {
    let minSize: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.minSize = minSize
            var frame = window.frame
            if frame.width < minSize.width || frame.height < minSize.height {
                // Grow from the top-left, so a window that was restored small
                // does not walk off the bottom of the screen.
                frame.origin.y -= max(0, minSize.height - frame.height)
                frame.size.width = max(frame.width, minSize.width)
                frame.size.height = max(frame.height, minSize.height)
                window.setFrame(frame, display: true)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
