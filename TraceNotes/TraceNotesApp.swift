import SwiftUI

@main
struct TraceNotesApp: App {
    // S1 spike wiring (spikes/S1-control-pause). Restore ContentView when the spike is removed.
    @UIApplicationDelegateAdaptor(S1AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // S2 map datum debug page (TraceNotes/Debug); never compiled into Release.
            TabView {
                Tab {
                    S1SpikeView()
                } label: {
                    Label { Text(verbatim: "S1") } icon: { Image(systemName: "pause.circle") }
                }
                Tab {
                    MapDatumDebugView()
                } label: {
                    Label { Text(verbatim: "S2 Datum") } icon: { Image(systemName: "map") }
                }
            }
            #else
            S1SpikeView()
            #endif
        }
    }
}
