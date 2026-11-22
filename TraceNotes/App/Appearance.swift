import SwiftUI

/// The user's choice of light or dark mode for the whole app (D40); `system` follows iOS.
enum Appearance: String, CaseIterable, Identifiable {
  case system, light, dark

  static let storageKey = "appearance"

  var id: Self { self }

  /// nil lets the system decide.
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  var title: LocalizedStringKey {
    switch self {
    case .system: "Match System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var symbol: String {
    switch self {
    case .system: "circle.lefthalf.filled"
    case .light: "sun.max"
    case .dark: "moon"
    }
  }
}

/// A round glass button on the map that picks the appearance.
struct AppearanceButton: View {
  @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

  var body: some View {
    Menu {
      Picker("Appearance", selection: $appearance) {
        ForEach(Appearance.allCases) { option in
          Label(option.title, systemImage: option.symbol).tag(option)
        }
      }
    } label: {
      Image(systemName: appearance.symbol)
        .font(.body.weight(.semibold))
        .frame(width: 44, height: 44)
        .glassEffect(.regular.interactive(), in: .circle)
    }
    .accessibilityLabel(Text("Appearance"))
  }
}
