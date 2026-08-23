import SwiftUI

@main
struct MeterFlowApp: App {
    /// `FlowHost.shared` rather than a fresh one: the audio session is a single
    /// thing, and a second engine would spend its life fighting this one for it.
    @StateObject private var host = FlowHost.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FlowView(host: host)
                .onAppear {
                    // A bypass test for "the app says it is playing and the room
                    // is silent" — see ToneTest.
                    if ProcessInfo.processInfo.environment["METER_TONE"] != nil {
                        ToneTest.shared.play()
                    }
                    if ProcessInfo.processInfo.environment["METER_PROBE"] != nil {
                        ToneTest.shared.probe()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                host.sceneBecameActive()
            case .background, .inactive:
                host.sceneWentBackground()
            @unknown default:
                break
            }
        }
    }
}
