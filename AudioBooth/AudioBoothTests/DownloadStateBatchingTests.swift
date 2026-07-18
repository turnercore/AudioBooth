import Combine
import XCTest

@testable import AudioBooth

@MainActor
final class DownloadStateBatchingTests: XCTestCase {
  func testUpdateDownloadStatesPublishesOneCompleteSnapshot() {
    let manager = DownloadManager(downloadStateEntries: {
      [
        (id: "book-1", isDownloaded: true),
        (id: "episode-1", isDownloaded: false),
      ]
    })
    var publishedSnapshots: [[String: DownloadManager.DownloadState]] = []
    let cancellable = manager.$downloadStates
      .dropFirst()
      .sink { publishedSnapshots.append($0) }

    manager.updateDownloadStates()

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
}
