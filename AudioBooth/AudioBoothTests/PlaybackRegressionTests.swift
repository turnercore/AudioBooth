import API
import Models
import XCTest

@testable import AudioBooth

@MainActor
final class PlaybackRegressionTests: XCTestCase {
  func testProgressRefreshPreservesLocalTimelineForStaleAndNewResponses() throws {
    try ModelContextProvider.shared.useInMemoryContainer(for: "refresh-regression")
    for (remoteUpdate, expectedTime) in [(1_000, 45.0), (3_000, 60.0)] {
      let progress = MediaProgress(
        bookID: "refresh-regression",
        currentTime: 45,
        duration: 60,
        progress: 0.75,
        lastUpdate: Date(timeIntervalSince1970: 2)
      )
      let data = Data(
        """
        {"id":"remote-progress","libraryItemId":"refresh-regression",
         "duration":120,"progress":0.5,"isFinished":false,
         "startedAt":0,"currentTime":60,"lastUpdate":\(remoteUpdate)}
        """.utf8
      )
      let remote = try JSONDecoder().decode(User.MediaProgress.self, from: data)

      SessionManager.applyRefreshedProgress(remote, to: progress, localDuration: 60)

      XCTAssertEqual(progress.duration, 60)
      XCTAssertEqual(progress.currentTime, expectedTime)
      XCTAssertEqual(progress.progress, expectedTime / 60)
      XCTAssertEqual(progress.isFinished, expectedTime == 60)
      XCTAssertEqual(progress.finishedAt != nil, expectedTime == 60)
    }
  }

  func testEmptyNextItemResponseCannotClearNewSelection() async {
    let manager = PlayerManager.shared
    let previousPlayer = manager.current
    let previousPresentation = manager.isShowingFullPlayer
    defer {
      manager.current = previousPlayer
      manager.isShowingFullPlayer = previousPresentation
    }
    let original = BookPlayer.Model.mock
    let replacement = BookPlayer.Model.mock
    manager.current = original

    await manager.resolveNext(autoPlay: false) { itemID, _ in
      XCTAssertEqual(itemID, original.id)
      await Task.yield()
      manager.current = replacement
      return nil
    }

    XCTAssertTrue(manager.current === replacement)
  }

  func testMeasuredLocalTimelineReplacesDoubledMetadataDuration() {
    let timeline = LocalPlaybackTimeline.make(
      measuredTracks: [
        .init(index: 0, duration: 30),
        .init(index: 1, duration: 30),
      ]
    )

    guard let timeline else {
      XCTFail("Expected a valid measured timeline")
      return
    }

    XCTAssertEqual(timeline.duration, 60, accuracy: 0.001)
    XCTAssertEqual(timeline.tracks[0], .init(index: 0, startOffset: 0, duration: 30))
    XCTAssertEqual(timeline.tracks[1], .init(index: 1, startOffset: 30, duration: 30))
  }

  func testPlaybackResumeClearsCompletedTimerWithoutRearmingAutoTimer() async throws {
    try ModelContextProvider.shared.useInMemoryContainer(for: "timer-regression")

    let preferences = UserPreferences.shared
    let previousShakeSensitivity = preferences.shakeSensitivity
    let previousPauseBehavior = preferences.timerPauseBehavior
    let previousAutoMode = preferences.autoTimerMode
    let previousAutoTrigger = preferences.autoTimerTrigger
    let previousWindowStart = preferences.autoTimerWindowStart
    let previousWindowEnd = preferences.autoTimerWindowEnd
    defer {
      preferences.shakeSensitivity = previousShakeSensitivity
      preferences.timerPauseBehavior = previousPauseBehavior
      preferences.autoTimerMode = previousAutoMode
      preferences.autoTimerTrigger = previousAutoTrigger
      preferences.autoTimerWindowStart = previousWindowStart
      preferences.autoTimerWindowEnd = previousWindowEnd
    }

    preferences.timerPauseBehavior = .none
    preferences.autoTimerMode = .duration(60)
    preferences.autoTimerTrigger = .timeWindow
    preferences.autoTimerWindowStart = 0
    preferences.autoTimerWindowEnd = 0

    for shakeSensitivity in [ShakeSensitivity.medium, .off] {
      preferences.shakeSensitivity = shakeSensitivity
      let itemID = "timer-regression-\(shakeSensitivity.rawValue)"
      let progress = MediaProgress(bookID: itemID, duration: 60)
      let session = PlaybackSession(
        libraryItemID: itemID,
        startTime: 0,
        currentTime: 0,
        duration: 60
      )
      let player = AudioPlayer(mediaProgress: progress, session: session)
      let model = TimerPickerSheetViewModel(
        itemID: itemID,
        player: player,
        chapters: nil,
        speed: FloatPickerSheet.Model()
      )

      model.selected = .preset(1)
      model.onStartTimerTapped()
      try await Task.sleep(for: .milliseconds(1_200))

      XCTAssertEqual(model.current, .none)
      XCTAssertEqual(model.completedAlert == nil, shakeSensitivity == .off)

      model.onPlaybackResumeRequested()
      model.activateAutoTimerIfNeeded()

      XCTAssertEqual(model.current, .none)
      XCTAssertNil(model.completedAlert)
    }
  }
}
