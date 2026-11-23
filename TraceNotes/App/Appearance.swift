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

/// The settings button in the map's control column (D46, D47), which draws the glass around it.
/// Until the settings screen (VS10) exists, its menu holds the appearance choice (D40).
struct SettingsButton: View {
  let size: CGFloat
  @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

  var body: some View {
    Menu {
      Section("Appearance") {
        Picker("Appearance", selection: $appearance) {
          ForEach(Appearance.allCases) { option in
            Label(option.title, systemImage: option.symbol).tag(option)
          }
        }
      }
    } label: {
      Image(systemName: "gearshape")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
        .contentShape(.rect)
    }
    // A menu tints its label; the map's controls are all in the primary colour (D47).
    .tint(.primary)
    .accessibilityLabel(Text("Settings"))
  }
}
