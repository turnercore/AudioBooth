import Combine
import XCTest

@testable import AudioBooth

@MainActor
final class DownloadStateBatchingTests: XCTestCase {
  func testUpdateDownloadStatesPublishesOneCompleteSnapshot() async {
    let manager = DownloadManager(
      downloadStateEntries: {
        [
          (id: "book-1", isDownloaded: true),
          (id: "episode-1", isDownloaded: false),
        ]
      },
      refreshOnInit: false
    )
    var publishedSnapshots: [[String: DownloadManager.DownloadState]] = []
    let cancellable = manager.$downloadStates
      .dropFirst()
      .sink { publishedSnapshots.append($0) }

    await manager.refreshDownloadStates()

    XCTAssertEqual(publishedSnapshots.count, 1)
    XCTAssertEqual(
      publishedSnapshots.first,
      [
        "book-1": .downloaded,
        "episode-1": .notDownloaded,
      ]
    )
    withExtendedLifetime(cancellable) {}
  }

  func testOlderRefreshCannotOverwriteNewerSnapshot() async throws {
    var callCount = 0
    let manager = DownloadManager(
      downloadStateEntries: {
        callCount += 1
        if callCount == 1 {
          try? await Task.sleep(for: .milliseconds(100))
          return [(id: "episode", isDownloaded: false)]
        }
        return [(id: "episode", isDownloaded: true)]
      },
      refreshOnInit: false
    )

    manager.updateDownloadStates()
    await Task.yield()
    manager.updateDownloadStates()
    try await Task.sleep(for: .milliseconds(200))

    XCTAssertEqual(manager.downloadStates["episode"], .downloaded)
  }
}
