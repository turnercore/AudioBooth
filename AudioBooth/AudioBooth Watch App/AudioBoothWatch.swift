import Nuke
import SwiftUI
import WatchKit

@main
struct AudioBoothWatch: App {
  @WKApplicationDelegateAdaptor private var appDelegate: AppDelegate

  init() {
    configureImagePipeline()
    _ = WatchConnectivityManager.shared
    Task { @MainActor in
      WatchFileTransferReceiver.recoverStagedTransfers()
      WatchShareDownloadCoordinator.shared.resumePersistedTransfers()
    }
    DownloadManager.shared.start()
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }

  private func configureImagePipeline() {
    ImagePipeline.shared = ImagePipeline {
      let config = URLSessionConfiguration.default
      config.timeoutIntervalForResource = 300
      config.timeoutIntervalForRequest = 60
      config.allowsCellularAccess = true
      config.waitsForConnectivity = true
      config.allowsExpensiveNetworkAccess = true
      config.allowsConstrainedNetworkAccess = true
      config.urlCache = nil

      $0.dataLoader = DataLoader(configuration: config)
      $0.dataCache = try? DataCache(name: "me.jgrenier.audioBS.watch.images")
    }
  }
}

final class AppDelegate: NSObject, WKApplicationDelegate {
  func applicationDidBecomeActive() {
    DownloadManager.shared.applicationDidBecomeActive()
  }

  func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
    for task in backgroundTasks {
      switch task {
      case let urlSessionTask as WKURLSessionRefreshBackgroundTask:
        if urlSessionTask.sessionIdentifier
          == WatchShareDownloadCoordinator.backgroundSessionIdentifier
        {
          WatchShareDownloadCoordinator.shared.reconnectBackgroundSession(
            withIdentifier: urlSessionTask.sessionIdentifier
          ) {
            urlSessionTask.setTaskCompletedWithSnapshot(false)
          }
        } else {
          DownloadManager.shared.reconnectBackgroundSession(
            withIdentifier: urlSessionTask.sessionIdentifier
          ) {
            urlSessionTask.setTaskCompletedWithSnapshot(false)
          }
        }

      case let connectivityTask as WKWatchConnectivityRefreshBackgroundTask:
        WatchConnectivityManager.shared.handleBackgroundTask(connectivityTask)

      default:
        task.setTaskCompletedWithSnapshot(false)
      }
    }
  }
}
