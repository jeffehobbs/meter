import AVFoundation
import CoreMIDI
import Foundation

/// A MIDI destination Meter can play into.
struct MIDIDestinationInfo: Identifiable, Hashable {
    var id: MIDIUniqueID
    var name: String
}

/// MIDI out. Meter always publishes a virtual source named "Meter Out" that any
/// app on the machine can subscribe to, and can additionally send straight to
/// one chosen destination — a hardware drum module, a DAW input, the IAC bus.
///
/// It also sends MIDI beat clock, which for this app is not a nicety: the whole
/// point of driving an external drum machine from a budget is that the external
/// machine's own sequencer stays in step with ours.
final class MIDIOut {
    var onDestinationsChanged: (() -> Void)?

    /// Endpoints belonging to Meter itself, so it never sends into its own ports.
    private(set) var ownUIDs: Set<MIDIUniqueID> = []

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var selectedEndpoint: MIDIEndpointRef = 0

    /// Channel index 0…15. Ten (index 9) is the percussion channel by
    /// convention, and is the default.
    var channel: UInt8 = 9
    /// Whether to send beat clock and start/stop.
    var sendsClock: Bool = false

    private(set) var selected: MIDIUniqueID? {
        didSet { selectedEndpoint = selected.flatMap { endpoint(for: $0) } ?? 0 }
    }

    init() {
        var status = MIDIClientCreateWithBlock("Meter" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async {
                    // Re-resolve, in case our destination came or went.
                    self?.select(self?.selected)
                    self?.onDestinationsChanged?()
                }
            }
        }
        guard status == noErr else {
            NSLog("Meter: MIDI client failed (\(status))")
            return
        }
        status = MIDIOutputPortCreate(client, "Meter Out Port" as CFString, &port)
        if status != noErr { NSLog("Meter: MIDIOutputPortCreate failed (\(status))") }

        status = MIDISourceCreateWithProtocol(client, "Meter Out" as CFString, ._1_0, &virtualSource)
        if status == noErr {
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(virtualSource, kMIDIPropertyUniqueID, &uid)
            ownUIDs.insert(uid)
        } else {
            NSLog("Meter: MIDISourceCreateWithProtocol failed (\(status))")
        }
    }

    // MARK: - Destinations

    func destinations() -> [MIDIDestinationInfo] {
        var result: [MIDIDestinationInfo] = []
        for i in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(i)
            guard endpoint != 0 else { continue }
            var uid: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uid)
            guard !ownUIDs.contains(uid) else { continue }
            result.append(MIDIDestinationInfo(id: uid, name: displayName(endpoint)))
        }
        return result
    }

    func select(_ uid: MIDIUniqueID?) { selected = uid }

    private func endpoint(for uid: MIDIUniqueID) -> MIDIEndpointRef? {
        for i in 0..<MIDIGetNumberOfDestinations() {
            let endpoint = MIDIGetDestination(i)
            var found: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &found)
            if found == uid { return endpoint }
        }
        return nil
    }

    private func displayName(_ endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value) == noErr,
           let string = value?.takeRetainedValue() {
            return string as String
        }
        return "MIDI destination"
    }

    // MARK: - Sending

    func noteOn(_ note: Int, velocity: Double, at time: Double = 0) {
        let v = UInt8(max(1, min(127, Int((velocity * 127).rounded()))))
        channelVoice(status: 0x9, UInt8(clamping: note), v, at: time)
    }

    func noteOff(_ note: Int, at time: Double = 0) {
        channelVoice(status: 0x8, UInt8(clamping: note), 0, at: time)
    }

    /// CC 123 on the percussion channel, plus a stop, so nothing is left
    /// hanging on an external instrument when the transport stops or the app
    /// quits mid-measure.
    func allNotesOff() {
        channelVoice(status: 0xB, 123, 0)
    }

    // MARK: - Transport messages

    func clockTick(at time: Double = 0) { guard sendsClock else { return }; realtime(0xF8, at: time) }
    func start()     { guard sendsClock else { return }; realtime(0xFA) }
    func resume()    { guard sendsClock else { return }; realtime(0xFB) }
    func stop()      { guard sendsClock else { return }; realtime(0xFC) }

    private func channelVoice(status: UInt8, _ data1: UInt8, _ data2: UInt8,
                              at time: Double = 0) {
        // UMP MIDI 1.0 channel voice: [mt:4=2][group:4][status:4][channel:4][d1:8][d2:8]
        let word = (UInt32(0x2) << 28)
            | (UInt32(status & 0xF) << 20)
            | (UInt32(channel & 0xF) << 16)
            | (UInt32(data1 & 0x7F) << 8)
            | UInt32(data2 & 0x7F)
        send(word, at: time)
    }

    private func realtime(_ status: UInt8, at time: Double = 0) {
        // UMP system real time: [mt:4=1][group:4][status:8][0:8][0:8]
        let word = (UInt32(0x1) << 28) | (UInt32(status) << 16)
        send(word, at: time)
    }

    /// `time` is mach uptime seconds — the moment the rack will be heard at,
    /// which is a little after the moment the clock decided on. Zero means now.
    ///
    /// The two routes have to be told the same time or they drift apart by the
    /// output latency: a hit handed to the graph is heard when the buffer
    /// carrying it reaches the ears, and an external instrument given the same
    /// hit "now" has already played it by then.
    private func send(_ word: UInt32, at time: Double = 0) {
        guard virtualSource != 0 || selectedEndpoint != 0 else { return }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        var words = [word]
        let stamp: MIDITimeStamp = time > 0 ? AVAudioTime.hostTime(forSeconds: time) : 0
        _ = MIDIEventListAdd(&list, 1_024, packet, stamp, 1, &words)
        // Publish to anyone subscribed to "Meter Out"…
        if virtualSource != 0 { MIDIReceivedEventList(virtualSource, &list) }
        // …and to the chosen destination, if there is one.
        if selectedEndpoint != 0 { MIDISendEventList(port, selectedEndpoint, &list) }
    }
}
