import UIKit

/// S1 spike: records every process launch (including background relaunches by Core Location).
final class S1AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // `launchOptions[.location]` is deprecated in iOS 26, and in a scene-based app the state is
    // already `.background` here even for a user launch. A system relaunch is therefore an
    // `app.launch` line that is NOT followed by `scene.phase active`.
    S1Recorder.shared.handleLaunch()
    return true
  }

  func applicationWillTerminate(_ application: UIApplication) {
    S1Recorder.shared.handleTermination()
  }
}
