import UIKit
import os

/// Opens the database and creates the recording engine once per process, before any scene
/// exists, so that a background relaunch by Core Location rejoins the sessions at once
/// (ARCHITECTURE §4.2).
final class AppDelegate: NSObject, UIApplicationDelegate {
  enum Startup {
    case ready(database: AppDatabase, engine: RecordingEngine)
    /// The database could not be opened; nothing can be recorded or shown.
    case failed(String)
  }

  let startup: Startup

  override init() {
    do {
      let database = try AppDatabase.openShared()
      startup = .ready(database: database, engine: RecordingEngine(database: database, store: .appGroup()))
    } catch {
      AppLog.storage.fault("database unavailable: \(error.localizedDescription, privacy: .public)")
      startup = .failed(error.localizedDescription)
    }
    super.init()
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    guard case .ready(_, let engine) = startup else { return true }
    engine.handleLaunch()
    #if DEBUG
    SpikeEngineGuard.start(engine: engine)
    #endif
    if Onboarding.isCompleted {
      engine.start()
    }
    return true
  }

  func applicationWillTerminate(_ application: UIApplication) {
    guard case .ready(_, let engine) = startup else { return }
    engine.handleTermination()
  }
}

/// Whether first-launch onboarding (F1) is done; after that the engine starts on every launch.
enum Onboarding {
  static let completedKey = "onboarding.completed"

  static var isCompleted: Bool {
    UserDefaults.standard.bool(forKey: completedKey)
  }
}
