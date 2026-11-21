import SwiftUI
import WidgetKit

@main
struct TraceNotesWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // S1 spike control (spikes/S1-control-pause). Remove with the spike.
        S1RecordingControl()
    }
}
