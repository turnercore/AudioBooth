import Models
import XCTest

@testable import AudioBooth

@MainActor
final class PlaybackRegressionTests: XCTestCase {
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
