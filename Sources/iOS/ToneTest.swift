import AVFoundation
import Foundation

/// A plain sine wave through the smallest possible graph.
///
/// When the instrumentation says samples are leaving the mixer and the listener
/// says the room is silent, everything between those two claims is untested:
/// the IO unit, the session, the route, the Bluetooth link. This bypasses the
/// rack, the spatial stage and every effect — one source node straight into the
/// engine's mixer — so what it proves is exactly that gap. If this is audible
/// and Meter is not, the fault is in Meter's graph. If neither is audible, the
/// fault is not in Meter at all.
///
/// Reached with `METER_TONE=1`; it never runs otherwise.
@MainActor
final class ToneTest {
    static let shared = ToneTest()

    private let engine = AVAudioEngine()
    private var phase: Double = 0
    /// Stage one and stage two use different pitches so the listener can say
    /// which they heard without watching a clock. Designing the experiment so
    /// the answer cannot be ambiguous is most of the work.
    private var frequency: Double = 440
    private let environment = AVAudioEnvironmentNode()

    /// Bisect Meter's own chain with a signal that cannot be mistaken for
    /// nothing.
    ///
    /// Stage one puts a sine through the part of Meter's graph that the plain
    /// tone test skips — a mono source into `AVAudioEnvironmentNode`, which is
    /// the one node the audible test does not have. Stage two plays the same
    /// sine straight into the mixer. Whichever stage is audible says where the
    /// sound is being lost, and no amount of metering can answer that: the level
    /// after the node was always fine.
    func probe() {
        guard activateSession(note: "PROBE") else { return }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 48_000
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        frequency = 440

        let node = AVAudioSourceNode(format: mono) { [self] _, _, frameCount, audioBufferList in
            let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let increment = frequency / sampleRate
            for frame in 0..<Int(frameCount) {
                phase += increment
                if phase > 1 { phase -= 1 }
                let value = Float(sin(phase * 2 * Double.pi)) * 0.25
                for buffer in list {
                    guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    samples[frame] = value
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.attach(environment)
        environment.outputType = .auto
        engine.connect(node, to: environment, format: mono)
        node.position = AVAudio3DPoint(x: 0, y: 0, z: -1)
        node.renderingAlgorithm = .auto
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)

        do {
            try engine.start()
            AudioOutput.note("PROBE stage 1 — LOW 440Hz THROUGH the 3D environment node, 7 seconds")
        } catch {
            AudioOutput.note("PROBE engine FAILED — \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine.pause()
                self.frequency = 0            // a second of silence between them
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {}
                // Same source, an octave up, straight to the mixer.
                self.engine.disconnectNodeOutput(node)
                self.engine.disconnectNodeOutput(self.environment)
                self.engine.connect(node, to: self.engine.mainMixerNode, format: mono)
                self.frequency = 880
                try? self.engine.start()
                AudioOutput.note("PROBE stage 2 — HIGH 880Hz STRAIGHT to the mixer, 7 seconds")
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    MainActor.assumeIsolated {
                        AudioOutput.note("PROBE finished")
                        self.engine.stop()
                    }
                }
            }
        }
    }

    @discardableResult
    private func activateSession(note: String) -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let route = session.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
            AudioOutput.note("\(note) session — \(session.sampleRate)Hz, out \(route), vol \(session.outputVolume)")
            return true
        } catch {
            AudioOutput.note("\(note) session FAILED — \(error.localizedDescription)")
            return false
        }
    }

    func play(seconds: Double = 12) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            let route = session.currentRoute.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
            AudioOutput.note("TONE session — \(session.sampleRate)Hz, out \(route), vol \(session.outputVolume)")
        } catch {
            AudioOutput.note("TONE session FAILED — \(error.localizedDescription)")
            return
        }

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2)!
        let increment = 440.0 / format.sampleRate

        let node = AVAudioSourceNode(format: format) { [self] _, _, frameCount, audioBufferList in
            let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                phase += increment
                if phase > 1 { phase -= 1 }
                let value = Float(sin(phase * 2 * Double.pi)) * 0.25
                for buffer in list {
                    guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    samples[frame] = value
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)

        var peak: Float = 0
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4_096,
                                        format: engine.mainMixerNode.outputFormat(forBus: 0)) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            for f in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[0][f])) }
        }

        do {
            try engine.start()
            AudioOutput.note("TONE playing 440Hz at 0.25 — \(format.sampleRate)Hz \(format.channelCount)ch")
        } catch {
            AudioOutput.note("TONE engine FAILED — \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                AudioOutput.note("TONE finished — mixer peak \(peak)")
                self?.engine.stop()
            }
        }
    }
}
