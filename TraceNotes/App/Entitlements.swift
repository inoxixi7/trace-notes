/// The one place that decides what is unlocked (F11, D9, D55 ⑦). Which features will be paid is
/// not decided yet (PRODUCT Q4), so none is named and everything is unlocked. A paid feature gets
/// a `Feature` constant and asks `isUnlocked` instead of checking purchases itself; recording, the
/// basic review and GPX export stay free (F11).
nonisolated enum Entitlements {
  struct Feature: Hashable, Sendable {
    let id: String
  }

  static func isUnlocked(_ feature: Feature) -> Bool {
    true
  }
}
