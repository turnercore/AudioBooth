import XCTest

@testable import AudioBooth

@MainActor
final class HomePageLifecycleTests: XCTestCase {
  func testRecentlyAddedSeriesUsesClearDisplayName() {
    XCTAssertEqual(HomeSection.recentSeries.displayName, "Recently Added Series")
  }

  func testRepeatedAppearancesStartAutomaticLoadingOnce() {
    final class Model: HomePage.Model {
      private(set) var startCount = 0

      override func start() {
        startCount += 1
      }
    }

    let model = Model()

    model.onAppear()
    model.onAppear()

    XCTAssertEqual(model.startCount, 1)
  }
}
