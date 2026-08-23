import Foundation

/// "This. What it is doing right now."
///
/// A triple tap writes everything the machine is doing to a file on the phone,
/// which can then be pulled off with `./build.sh log`. It exists because the
/// interesting questions about this app are all of the form "why does it sound
/// like *that*", and the answer is a hundred numbers that were true for about
/// four seconds.
///
/// Undiscoverable on purpose: a diagnostic rather than a feature.
final class MomentLog {
    static let shared = MomentLog()

    /// Beyond this the file starts again. A log that grows without limit on
    /// somebody's phone is its own bug.
    private static let sizeLimit = 512 * 1024

    private let queue = DispatchQueue(label: "com.jeffhobbs.meter.moments", qos: .utility)
    private let url: URL?
    private lazy var stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private init() {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        let directory = base?.appendingPathComponent("Meter", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        url = directory?.appendingPathComponent("moments.log")
    }

    func write(_ report: String) {
        let stamped = "\n════ \(stamp.string(from: Date())) ════\n" + report + "\n"
        queue.async { [weak self] in
            guard let self, let url = self.url else { return }
            let manager = FileManager.default
            if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int,
               size > Self.sizeLimit {
                try? manager.removeItem(at: url)
            }
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
        // Also to stdout, so a moment marked while a console is attached shows
        // up without having to fetch anything.
        if AudioOutput.verbose { print(stamped) }
    }
}

/// One measure, as it was. Kept in a ring so a marked moment can show what was
/// happening *before* the tap.
///
/// The window is retroactive, and that is the whole design: by the time somebody
/// has heard something, decided it was worth marking, and got a thumb to the
/// screen, several seconds have gone. A snapshot of only the instant of the
/// press points at the wrong bar.
struct MeasureSnapshot {
    var index: Int
    var spent: Int
    var counts: [DrumVoice: Int]
    var shares: [DrumVoice: Double]
    var temperature: Double
    var notes: [String]

    var line: String {
        let lanes = DrumVoice.laneOrder.reversed().map { voice -> String in
            let count = counts[voice] ?? 0
            return count > 0 ? "\(voice.short):\(count)" : "\(voice.short):·"
        }.joined(separator: " ")
        let trace = notes.isEmpty ? "" : "   ← " + notes.joined(separator: ", ")
        return String(format: "  m%-5d %2d spent  placement %.2f  %@%@",
                      index + 1, spent, temperature, lanes, trace)
    }
}
