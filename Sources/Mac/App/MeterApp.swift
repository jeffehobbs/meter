import SwiftUI

@main
struct MeterApp: App {
    @StateObject private var engine = MeterEngine()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .frame(minWidth: 1_060, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1_180, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Machine") {
                Button(engine.running ? "Stop" : "Run") { engine.toggleTransport() }
                    .keyboardShortcut(.space, modifiers: [])
                Divider()
                Button(engine.flowing ? "Stop Flow" : "Start Flow") { engine.flowing.toggle() }
                    .keyboardShortcut("f", modifiers: [.command])
                Divider()
                Button("Nudge the Director") { engine.nudge() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Reseed Allocation") { engine.reseed() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Repatch Everything") { engine.randomizeKit() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Reset Everything to Factory Defaults") { engine.factoryReset() }
            }
        }
    }
}
