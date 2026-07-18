import XCTest

@testable import AudioBooth

@MainActor
final class PodcastDetailsPerformanceTests: XCTestCase {
  func testEpisodePayloadProjectionRunsOffActorAndPreservesDisplayData() async throws {
    let inputs = [
      PodcastEpisodeProjectionInput(
        id: "episode-1",
        title: "First",
        season: "2",
        episode: "3",
        publishedAtMilliseconds: 1_000,
        duration: 120,
        size: 42,
        description: "Description",
        chapters: [
          .init(id: 2, start: 60, end: 120, title: "Later"),
          .init(id: 1, start: 0, end: 60, title: "Earlier"),
        ]
      ),
      PodcastEpisodeProjectionInput(
        id: "episode-2",
        title: "Second",
        duration: nil
      ),
    ]

    let result = try await Task.detached {
      try PodcastEpisodeProjector.project(inputs)
    }.value

    XCTAssertEqual(result.episodes.map(\.id), ["episode-1", "episode-2"])
    XCTAssertEqual(result.episodes[0].publishedAt, Date(timeIntervalSince1970: 1))
    XCTAssertEqual(result.episodes[0].chapters.map(\.id), [1, 2])
    XCTAssertEqual(result.totalDuration, 120)
  }

  func testDownloadSnapshotsOnlyApplyChangedKnownEpisodeIDs() {
    let model = PodcastDetailsView.Model(
      podcastID: "podcast",
      isLoading: false,
      episodes: [
        episode(id: "episode-1"),
        episode(id: "episode-2"),
      ]
    )

    XCTAssertEqual(
      model.applyDownloadStates(["unknown": .downloaded]),
      0
    )
    XCTAssertEqual(model.episodes.map(\.downloadState), [.notDownloaded, .notDownloaded])

    XCTAssertEqual(
      model.applyDownloadStates([
        "episode-1": .downloaded,
        "episode-2": .downloading(progress: 0.5),
      ]),
      2
    )
    XCTAssertEqual(
      model.episodes.map(\.downloadState),
      [.downloaded, .downloading(progress: 0.5)]
    )
    XCTAssertEqual(
      model.filteredEpisodes.map(\.downloadState),
      [.downloaded, .downloading(progress: 0.5)]
    )

    XCTAssertEqual(
      model.applyDownloadStates([
        "episode-1": .downloaded,
        "episode-2": .downloading(progress: 0.5),
      ]),
      0
    )
  }

  func testProgressUpdateMutatesProjectedEpisodeWithoutReprojectingOrder() {
    let model = PodcastDetailsView.Model(
      podcastID: "podcast",
      isLoading: false,
      episodes: [
        episode(id: "episode-1", title: "First"),
        episode(id: "episode-2", title: "Second"),
      ],
      selectedSort: .title,
      ascending: false
    )
    let projectedIDs = model.filteredEpisodes.map(\.id)

    XCTAssertTrue(model.applyProgress(0.5, to: "episode-1"))

    XCTAssertEqual(model.filteredEpisodes.map(\.id), projectedIDs)
    XCTAssertEqual(model.episodes.first { $0.id == "episode-1" }?.progress, 0.5)
    XCTAssertEqual(model.filteredEpisodes.first { $0.id == "episode-1" }?.progress, 0.5)
  }

  func testProgressUpdateRefreshesFilterOnlyWhenMembershipChanges() {
    let model = PodcastDetailsView.Model(
      podcastID: "podcast",
      isLoading: false,
      episodes: [episode(id: "episode")],
      selectedFilter: .inProgress
    )
    XCTAssertTrue(model.filteredEpisodes.isEmpty)

    model.applyProgress(0.5, to: "episode")
    XCTAssertEqual(model.filteredEpisodes.map(\.id), ["episode"])

    model.applyProgress(1, to: "episode")
    XCTAssertTrue(model.filteredEpisodes.isEmpty)
  }

  private func episode(
    id: String,
    title: String = "Episode",
    progress: Double = 0
  ) -> PodcastDetailsView.Model.Episode {
    PodcastDetailsView.Model.Episode(
      id: id,
      title: title,
      season: nil,
      episode: nil,
      publishedAt: nil,
      duration: nil,
      size: nil,
      description: nil,
      isCompleted: progress >= 1,
      progress: progress,
      chapters: [],
      downloadState: .notDownloaded
    )
  }
}
