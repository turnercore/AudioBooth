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

  func testRefreshRemovesStaleEntriesAndPreservesLiveDownloadState() async {
    let manager = DownloadManager(
      downloadStateEntries: {
        [(id: "persisted", isDownloaded: true)]
      },
      refreshOnInit: false
    )
    manager.downloadStates = [
      "stale": .downloaded,
      "active": .downloading(progress: 0.4),
    ]

    await manager.refreshDownloadStates()

    XCTAssertEqual(
      manager.downloadStates,
      [
        "persisted": .downloaded,
        "active": .downloading(progress: 0.4),
      ]
    )
  }

  func testRefreshDoesNotOverwriteProgressChangedWhileReadingSnapshot() async throws {
    let manager = DownloadManager(
      downloadStateEntries: {
        try? await Task.sleep(for: .milliseconds(100))
        return [(id: "active", isDownloaded: false)]
      },
      refreshOnInit: false
    )
    manager.downloadStates["active"] = .downloading(progress: 0.1)

    let refresh = Task { await manager.refreshDownloadStates() }
    try await Task.sleep(for: .milliseconds(20))
    manager.downloadStates["active"] = .downloading(progress: 0.8)
    await refresh.value

    XCTAssertEqual(manager.downloadStates["active"], .downloading(progress: 0.8))
  }
}
