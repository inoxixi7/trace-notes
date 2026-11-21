import SwiftUI

@main
struct TraceNotesApp: App {
    // S1 spike wiring (spikes/S1-control-pause). Restore ContentView when the spike is removed.
    @UIApplicationDelegateAdaptor(S1AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            S1SpikeView()
        }
    }
}
