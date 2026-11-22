import SwiftUI
import UIKit

/// S3 spike app (separate target `TraceNotesS3`, bundle id com.inoxixi.tracenotes.s3) so that
/// Settings › Battery reports its energy on its own, apart from the S1 spike in the main app.
@main
struct S3App: App {
  @UIApplicationDelegateAdaptor(S3AppDelegate.self) private var appDelegate
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      S3RootView()
    }
    .onChange(of: scenePhase) { _, phase in
      S3Recorder.shared.handleScenePhase(Self.name(phase))
    }
  }

  private static func name(_ phase: ScenePhase) -> String {
    switch phase {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
  }
}

/// Records every process launch, including background relaunches by Core Location. In a scene
/// app the state is `.background` here even for a user launch, so a relaunch is an `app.launch`
/// line not followed by `scene.phase active` (same reading as S1).
final class S3AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    S3MetricStore.shared.start()
    S3Recorder.shared.handleLaunch()
    return true
  }

  func applicationWillTerminate(_ application: UIApplication) {
    S3Recorder.shared.handleTermination()
  }
}
