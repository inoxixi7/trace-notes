import SwiftUI

/// Empty main screen. Real UI arrives with the first vertical slice.
struct ContentView: View {
    var body: some View {
        Color.clear
            .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}
