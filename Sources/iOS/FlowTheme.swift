import SwiftUI

/// The phone's palette. The same graphite the Mac app uses, because they are the
/// same machine, with more contrast in the accents — a phone gets looked at in
/// daylight and from across a room.
enum Flow {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.064)
    static let panel = Color(red: 0.086, green: 0.090, blue: 0.099)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.46)
    static let faint = Color.white.opacity(0.20)
    static let accent = Color(red: 0.42, green: 0.83, blue: 0.80)
    static let live = Color(red: 0.98, green: 0.72, blue: 0.32)
    static let pulse = Color(red: 0.95, green: 0.42, blue: 0.48)

    static func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium))
            .tracking(1.8)
            .foregroundStyle(Flow.dim)
    }
}
