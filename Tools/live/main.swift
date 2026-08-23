import AVFoundation
import Foundation

// A real-time test of the audio graph, as opposed to the offline one in
// check.swift.
//
// The offline path renders through `enableManualRenderingMode`, which pulls the
// source nodes itself. Real playback pulls them from the IO thread instead, and
// the two are different enough that a graph can measure perfectly in one and be
// silent in the other — so this starts the engine for real, plays a bar, and taps
// the mixer to see whether anything actually came out.

setvbuf(stdout, nil, _IONBF, 0)

let audio = AudioOutput()
audio.synth.masterVolume = 0.85
audio.reverbMix = 14

var kit: [DrumVoice: LaneSettings] = [:]
for voice in DrumVoice.allCases { kit[voice] = .default(for: voice) }
audio.place(kit)

audio.start()
print("engine running: \(audio.isRunning)")

// The graph keeps its own meter on the mixer, which is the same measurement the
// app shows and one tap fewer to collide with.
var peak: Float = 0

// Four beats of the whole kit, spread across the bar.
let voices = DrumVoice.allCases
for step in 0..<16 {
    let voice = voices[step % voices.count]
    if let lane = kit[voice] {
        audio.synth.triggers.push(Trigger(voice: voice, lane: lane, velocity: 0.9))
    }
    Thread.sleep(forTimeInterval: 0.125)
    peak = max(peak, audio.outputPeak)
}
Thread.sleep(forTimeInterval: 0.5)
peak = max(peak, audio.outputPeak)

print(String(format: "output peak %.4f, synth peak %.4f, cycles %d",
             peak, audio.synth.peak, audio.cycles))
print(peak > 0.02 ? "AUDIBLE" : "SILENT")
exit(peak > 0.02 ? 0 : 1)
