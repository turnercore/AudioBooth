import API
import Combine
import Foundation
import Logging
import Models

nonisolated struct PodcastEpisodeProjectionInput: Sendable {
  nonisolated struct Chapter: Sendable {
    let id: Int
    let start: Double
    let end: Double
    let title: String
  }

  let id: String
  let title: String
  let season: String?
  let episode: String?
  let publishedAt: Date?
  let publishedAtMilliseconds: Int64?
  let duration: Double?
  let size: Int64?
  let description: String?
  let chapters: [Chapter]
  let apiEpisode: PodcastEpisode?

  init(
    id: String,
    title: String,
    season: String? = nil,
    episode: String? = nil,
    publishedAt: Date? = nil,
    publishedAtMilliseconds: Int64? = nil,
    duration: Double? = nil,
    size: Int64? = nil,
    description: String? = nil,
    chapters: [Chapter] = [],
    apiEpisode: PodcastEpisode? = nil
  ) {
    self.id = id
    self.title = title
    self.season = season
    self.episode = episode
    self.publishedAt = publishedAt
    self.publishedAtMilliseconds = publishedAtMilliseconds
    self.duration = duration
    self.size = size
    self.description = description
    self.chapters = chapters
    self.apiEpisode = apiEpisode
  }

  init(apiEpisode: PodcastEpisode) {
    self.init(
      id: apiEpisode.id,
      title: apiEpisode.title,
      season: apiEpisode.season,
      episode: apiEpisode.episode,
      publishedAtMilliseconds: apiEpisode.publishedAt,
      duration: apiEpisode.duration,
      size: apiEpisode.audioTrack?.metadata?.size ?? apiEpisode.size,
      description: apiEpisode.description,
      chapters: (apiEpisode.chapters ?? []).map {
        Chapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title)
      },
      apiEpisode: apiEpisode
    )
  }
}

nonisolated struct PodcastEpisodeProjection: Sendable {
  let id: String
  let title: String
  let season: String?
  let episode: String?
  let publishedAt: Date?
  let duration: Double?
  let size: Int64?
  let description: String?
  let chapters: [PodcastEpisodeProjectionInput.Chapter]
  let apiEpisode: PodcastEpisode?
}

nonisolated struct PodcastEpisodeProjectionResult: Sendable {
  let episodes: [PodcastEpisodeProjection]
  let totalDuration: Double
}

nonisolated enum PodcastEpisodeProjector {
  static func project(_ inputs: [PodcastEpisodeProjectionInput]) throws -> PodcastEpisodeProjectionResult {
    var totalDuration = 0.0
    var episodes: [PodcastEpisodeProjection] = []
    episodes.reserveCapacity(inputs.count)

    for input in inputs {
      try Task.checkCancellation()
      let publishedAt =
        input.publishedAt
        ?? input.publishedAtMilliseconds.map {
          Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }
      let chapters = input.chapters.sorted { $0.start < $1.start }
      totalDuration += input.duration ?? 0
      episodes.append(
        PodcastEpisodeProjection(
          id: input.id,
          title: input.title,
          season: input.season,
          episode: input.episode,
          publishedAt: publishedAt,
          duration: input.duration,
          size: input.size,
          description: input.description,
          chapters: chapters,
          apiEpisode: input.apiEpisode
        )
      )
    }

    return PodcastEpisodeProjectionResult(episodes: episodes, totalDuration: totalDuration)
  }
}

final class PodcastDetailsViewModel: PodcastDetailsView.Model {
  private var podcastsService: PodcastsService { Audiobookshelf.shared.podcasts }
  private let playerManager = PlayerManager.shared
  private let downloadManager = DownloadManager.shared
  private var apiEpisodes: [PodcastEpisode] = []
  private var localPodcast: LocalPodcast?
  private var cancellables = Set<AnyCancellable>()
  private let episodeID: String?
  private let preferences = UserPreferences.shared
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var didLoadPodcast = false

  init(podcastID: String, episodeID: String? = nil) {
    self.episodeID = episodeID
    super.init(podcastID: podcastID)
    selectedFilter = preferences.podcastEpisodeFilter
    selectedSort = preferences.podcastEpisodeSort
    ascending = preferences.podcastEpisodeSortAscending

    let autoQueue = preferences.podcastAutoQueueSetting(for: podcastID)
    autoQueuePosition = autoQueue.position
    autoQueueLimit = autoQueue.limit

    observePlayer()
    observeDownloadStates()
  }

  override func onAutoQueueChanged(_ position: PodcastAutoQueueSettings.Position, _ limit: PodcastAutoQueueLimit) {
    autoQueuePosition = position
    autoQueueLimit = limit

    var setting = preferences.podcastAutoQueueSetting(for: podcastID)
    let wasEnabled = setting.position.isEnabled
    setting.position = position
    setting.limit = limit

    if position.isEnabled && !wasEnabled {
      setting.baselinePublishedAt = newestKnownPublishedAt() ?? Int64(Date().timeIntervalSince1970 * 1000)
    }

    preferences.setPodcastAutoQueueSetting(setting, for: podcastID)
  }

  private func newestKnownPublishedAt() -> Int64? {
    if let newest = apiEpisodes.compactMap({ $0.publishedAt }).max() {
      return newest
    }
    return
      episodes
      .compactMap { $0.publishedAt }
      .map { Int64($0.timeIntervalSince1970 * 1000) }
      .max()
  }

  override func onFilterChanged(_ filter: EpisodeFilter) {
    selectedFilter = filter
    preferences.podcastEpisodeFilter = filter
  }

  override func onSortOptionTapped(_ sort: EpisodeSort) {
    super.onSortOptionTapped(sort)
    preferences.podcastEpisodeSort = selectedSort
    preferences.podcastEpisodeSortAscending = ascending
  }

  override func onAppear() {
    guard loadTask == nil, !didLoadPodcast else { return }
    loadGeneration += 1
    let generation = loadGeneration
    loadTask = Task { [weak self] in
      guard let self else { return }
      await loadLocalPodcast()
      guard !Task.isCancelled else { return }
      await loadPodcast()
      if loadGeneration == generation {
        loadTask = nil
      }
    }
  }

  override func onDisappear() {
    loadGeneration += 1
    loadTask?.cancel()
    loadTask = nil
  }

  isolated deinit {
    loadTask?.cancel()
  }

  override func onPlayEpisode(_ episode: Episode) {
    if playerManager.current?.id == episode.id {
      if let currentPlayer = playerManager.current as? BookPlayerModel {
        currentPlayer.onTogglePlaybackTapped()
      }
      return
    }

    if let apiEpisode = apiEpisodes.first(where: { $0.id == episode.id }) {
      playerManager.setCurrent(
        episode: apiEpisode,
        podcastID: podcastID,
        podcastTitle: title,
        podcastAuthor: author,
        coverURL: coverURL
      )
      playerManager.play()
    } else if let localEpisode = localPodcast?.episodes.first(where: { $0.episodeID == episode.id }) {
      playerManager.setCurrent(localEpisode)
      playerManager.play()
    }
  }

  override func onDownloadAllEpisodes() {
    let episodes = filteredEpisodes.filter { $0.downloadState == .notDownloaded }

    Task {
      for episode in episodes {
        let size = episode.size ?? 0
        downloadManager.startDownload(
          for: episode.id,
          type: .episode(podcastID: podcastID, episodeID: episode.id),
          info: .init(
            title: episode.title,
            coverURL: coverURL,
            duration: episode.duration,
            size: size > 0 ? size : nil,
            startedAt: Date()
          )
        )
      }
    }
  }

  override func onPlayAllEpisodes() {
    let episodes = filteredEpisodes
    guard let first = episodes.first else { return }

    onPlayEpisode(first)

    for episode in episodes.dropFirst() {
      playerManager.addToQueue(
        QueueItem(
          bookID: episode.id,
          title: episode.title,
          details: episode.durationText,
          coverURL: coverURL,
          podcastID: podcastID
        )
      )
    }
  }

  private func observeDownloadStates() {
    downloadManager.$downloadStates
      .sink { [weak self] states in
        self?.applyDownloadStates(states)
      }
      .store(in: &cancellables)
  }

  private func observePlayer() {
    playerManager.$current
      .sink { [weak self] newCurrent in
        guard let self else { return }
        observeIsPlaying(newCurrent)
      }
      .store(in: &cancellables)
  }

  private func observeIsPlaying(_ current: BookPlayer.Model?) {
    guard let current, current.podcastID == podcastID else {
      currentlyPlayingEpisodeID = nil
      isPlaying = false
      return
    }

    updatePlayingState()

    withObservationTracking {
      _ = current.isPlaying
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.updatePlayingState()
        self.observeIsPlaying(playerManager.current)
      }
    }
  }

  private func updatePlayingState() {
    let current = playerManager.current
    if current?.podcastID == podcastID {
      currentlyPlayingEpisodeID = current?.id
      isPlaying = current?.isPlaying ?? false
    } else {
      currentlyPlayingEpisodeID = nil
      isPlaying = false
    }
    refreshEpisodeProgress()
  }

  private func refreshEpisodeProgress() {
    var updatedEpisodes = episodes
    var changed = false
    for index in updatedEpisodes.indices {
      let progress = MediaProgress.progress(for: updatedEpisodes[index].id)
      let isCompleted = progress >= 1.0
      if updatedEpisodes[index].progress != progress || updatedEpisodes[index].isCompleted != isCompleted {
        updatedEpisodes[index].progress = progress
        updatedEpisodes[index].isCompleted = isCompleted
        changed = true
      }
    }
    if changed {
      episodes = updatedEpisodes
    }
  }

  private func loadLocalPodcast() async {
    do {
      guard let podcast = try LocalPodcast.fetch(podcastID: podcastID) else { return }
      localPodcast = podcast

      title = podcast.title
      author = podcast.author
      coverURL = podcast.coverURL(raw: true)
      description = podcast.podcastDescription?.replacingOccurrences(of: "\n", with: "<br>")
      genres = podcast.genres
      language = podcast.language
      podcastType = podcast.podcastType

      isLoading = false
      scrollToEpisodeID = episodeID

      try await showCachedEpisodes(podcast)
    } catch {
      if Task.isCancelled { return }
      AppLogger.viewModel.error("Failed to load local podcast: \(error)")
    }
  }

  private func showCachedEpisodes(_ podcast: LocalPodcast) async throws {
    let inputs = podcast.episodes.map { localEpisode in
      PodcastEpisodeProjectionInput(
        id: localEpisode.episodeID,
        title: localEpisode.title,
        season: localEpisode.season,
        episode: localEpisode.episode,
        publishedAt: localEpisode.publishedAt,
        duration: localEpisode.duration,
        description: localEpisode.episodeDescription,
        chapters: localEpisode.chapters.map {
          .init(id: $0.id, start: $0.start, end: $0.end, title: $0.title)
        }
      )
    }
    let progressByID = episodeProgress(for: inputs.map(\.id))
    let projection = try await Self.projectEpisodes(inputs)
    try Task.checkCancellation()

    episodeCount = projection.episodes.count
    updateDurationText(totalDuration: projection.totalDuration)
    episodes = makeEpisodes(projection.episodes, progressByID: progressByID)

    episodesLoading = false
  }

  private func loadPodcast() async {
    if episodes.isEmpty {
      episodesLoading = true
    }

    do {
      let podcast = try await podcastsService.fetch(id: podcastID)

      title = podcast.title
      author = podcast.author
      coverURL = podcast.coverURL(raw: true)
      description = podcast.description?.replacingOccurrences(of: "\n", with: "<br>")
      genres = podcast.genres
      tags = podcast.tags
      libraryID = podcast.libraryID
      isExplicit = podcast.media.metadata.explicit ?? false
      language = podcast.language
      podcastType = podcast.podcastType
      feedURL = podcast.feedURL

      apiEpisodes = podcast.media.episodes ?? []
      let inputs = apiEpisodes.map(PodcastEpisodeProjectionInput.init(apiEpisode:))
      let progressByID = episodeProgress(for: inputs.map(\.id))
      let projection = try await Self.projectEpisodes(inputs)
      try Task.checkCancellation()

      episodeCount = projection.episodes.count
      updateDurationText(totalDuration: projection.totalDuration)
      episodes = makeEpisodes(projection.episodes, progressByID: progressByID)

      error = nil
      isLoading = false
      episodesLoading = false
      scrollToEpisodeID = episodeID
      didLoadPodcast = true
    } catch {
      if Task.isCancelled { return }
      if localPodcast == nil {
        self.error = "Failed to load podcast details. Please check your connection and try again."
      } else if NetworkMonitor.shared.isConnected {
        Toast(error: "Couldn't refresh episodes. Showing downloaded episodes only.").show()
      }
      isLoading = false
      episodesLoading = false
      AppLogger.viewModel.error("Failed to load podcast: \(error)")
    }
  }

  private func episodeProgress(for episodeIDs: [String]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: episodeIDs.map { ($0, MediaProgress.progress(for: $0)) })
  }

  private func updateDurationText(totalDuration: Double) {
    guard totalDuration > 0 else { return }
    durationText = Duration.seconds(totalDuration).formatted(
      .units(allowed: [.hours, .minutes], width: .narrow)
    )
  }

  private func makeEpisodes(
    _ projections: [PodcastEpisodeProjection],
    progressByID: [String: Double]
  ) -> [Episode] {
    projections.map { projection in
      let progress = progressByID[projection.id] ?? 0
      let contextMenu = PodcastEpisodeContextMenuModel(
        podcastID: podcastID,
        podcastTitle: title,
        podcastAuthor: author,
        coverURL: coverURL,
        episode: projection,
        progress: progress
      )
      contextMenu.onProgressChanged = { [weak self] in
        self?.refreshEpisodeProgress()
      }

      return Episode(
        id: projection.id,
        title: projection.title,
        season: projection.season,
        episode: projection.episode,
        publishedAt: projection.publishedAt,
        duration: projection.duration,
        size: projection.size,
        description: projection.description,
        isCompleted: progress >= 1.0,
        progress: progress,
        chapters: projection.chapters.map {
          Chapter(id: $0.id, start: $0.start, end: $0.end, title: $0.title)
        },
        downloadState: downloadManager.downloadStates[projection.id] ?? .notDownloaded,
        contextMenu: contextMenu,
        apiEpisode: projection.apiEpisode
      )
    }
  }

  private nonisolated static func projectEpisodes(
    _ inputs: [PodcastEpisodeProjectionInput]
  ) async throws -> PodcastEpisodeProjectionResult {
    let projectionTask = Task.detached(priority: .userInitiated) {
      try PodcastEpisodeProjector.project(inputs)
    }
    return try await withTaskCancellationHandler {
      try await projectionTask.value
    } onCancel: {
      projectionTask.cancel()
    }
  }
}
