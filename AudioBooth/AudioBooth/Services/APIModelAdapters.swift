import API
import Foundation
import Logging
import Models
import SwiftData

extension Models.Chapter {
  convenience init(from chapter: Book.Media.Chapter) {
    self.init(id: chapter.id, start: chapter.start, end: chapter.end, title: chapter.title)
  }
}

extension Track {
  convenience init(from track: AudioTrack) {
    self.init(
      index: track.index,
      startOffset: track.startOffset,
      duration: track.duration,
      title: track.title,
      updatedAt: track.updatedAt,
      filename: track.metadata?.filename,
      ext: track.metadata?.ext,
      size: track.metadata?.size,
      format: track.format,
      bitRate: track.bitRate,
      codec: track.codec,
      channels: track.channels,
      channelLayout: track.channelLayout,
      mimeType: track.mimeType
    )
  }
}

extension LocalBook {
  convenience init(from book: Book) {
    self.init(
      bookID: book.id,
      libraryID: book.libraryID,
      title: book.title,
      authors: book.media.metadata.authors?.map { Author(id: $0.id, name: $0.name) } ?? [],
      narrators: book.media.metadata.narrators ?? [],
      series: book.media.metadata.series?.map { Series(id: $0.id, name: $0.name, sequence: $0.sequence) } ?? [],
      coverURL: book.coverURL(),
      duration: book.duration,
      tracks: book.tracks?.map { Track(from: $0) } ?? [],
      chapters: book.chapters?.map { Models.Chapter(from: $0) } ?? [],
      publishedYear: book.publishedYear,
      subtitle: book.media.metadata.subtitle,
      bookDescription: book.description,
      genres: book.genres,
      tags: book.tags,
      isExplicit: book.media.metadata.explicit ?? false,
      isAbridged: book.media.metadata.abridged ?? false,
      publisher: book.publisher,
      language: book.media.metadata.language
    )
  }
}

extension LocalPodcast {
  convenience init(from podcast: Podcast) {
    self.init(
      podcastID: podcast.id,
      title: podcast.title,
      author: podcast.author,
      coverURL: podcast.coverURL(),
      podcastDescription: podcast.description,
      genres: podcast.genres,
      feedURL: podcast.feedURL,
      language: podcast.language,
      podcastType: podcast.podcastType
    )
  }
}

extension Bookmark {
  convenience init(from apiBookmark: User.Bookmark) {
    self.init(
      bookID: apiBookmark.bookID,
      time: Int(apiBookmark.time),
      title: apiBookmark.title,
      createdAt: Date(timeIntervalSince1970: TimeInterval(apiBookmark.createdAt / 1000)),
      status: .synced
    )
  }

  @MainActor
  static func syncFromAPI(userData: User) throws {
    let context = ModelContextProvider.shared.context

    for apiBookmark in userData.bookmarks {
      let remote = Bookmark(from: apiBookmark)

      if let local = try Bookmark.fetch(bookID: apiBookmark.bookID, time: Int(apiBookmark.time)) {
        local.title = remote.title
        local.createdAt = remote.createdAt
        local.status = .synced
      } else {
        context.insert(remote)
      }
    }

    try context.save()
  }
}

extension MediaProgress {
  convenience init(from apiProgress: User.MediaProgress) {
    let values = MediaProgress.remoteValues(from: apiProgress)
    self.init(
      bookID: apiProgress.episodeId ?? apiProgress.libraryItemId,
      id: apiProgress.id,
      lastPlayedAt: values.lastUpdate,
      currentTime: values.currentTime,
      duration: apiProgress.duration ?? 0,
      progress: values.progress,
      ebookProgress: apiProgress.ebookProgress,
      ebookLocation: apiProgress.ebookLocation,
      isFinished: apiProgress.isFinished,
      startedAt: Date(timeIntervalSince1970: TimeInterval(apiProgress.startedAt / 1000)),
      finishedAt: values.finishedAt,
      lastUpdate: values.lastUpdate
    )
  }

  func update(from apiProgress: User.MediaProgress) {
    let values = MediaProgress.remoteValues(from: apiProgress)
    let remoteStartedAt = Date(timeIntervalSince1970: TimeInterval(apiProgress.startedAt / 1000))

    id = apiProgress.id
    duration = apiProgress.duration ?? 0
    startedAt = remoteStartedAt

    if finishedAt == nil {
      finishedAt = values.finishedAt
    }

    let willApply = values.lastUpdate > lastUpdate
    AppLogger.session.debug(
      """
      MediaProgress.update bookID=\(bookID) apply=\(willApply) \
      local(lastUpdate=\(lastUpdate.timeIntervalSince1970), currentTime=\(currentTime), progress=\(progress), isFinished=\(isFinished)) \
      remote(lastUpdate=\(values.lastUpdate.timeIntervalSince1970), currentTime=\(values.currentTime), progress=\(values.progress), isFinished=\(apiProgress.isFinished))
      """
    )

    if values.lastUpdate > lastUpdate {
      if values.currentTime != currentTime {
        PlaybackHistory.record(itemID: bookID, action: .sync, position: values.currentTime)
      }

      lastPlayedAt = values.lastUpdate
      currentTime = values.currentTime
      progress = values.progress
      ebookProgress = apiProgress.ebookProgress
      ebookLocation = apiProgress.ebookLocation
      isFinished = apiProgress.isFinished
      finishedAt = values.finishedAt
      lastUpdate = values.lastUpdate
    }
  }

  @MainActor
  static func syncFromAPI(userData: User, currentPlayingBookID: String? = nil) throws {
    let context = ModelContextProvider.shared.context
    let allLocalProgress = try MediaProgress.fetchAll()
    let remoteBookIDs = Set(userData.mediaProgress.map { $0.episodeId ?? $0.libraryItemId })
    var progressMap = Dictionary(uniqueKeysWithValues: allLocalProgress.map { ($0.bookID, $0) })

    AppLogger.session.debug(
      "MediaProgress.syncFromAPI start: local=\(allLocalProgress.count) remote=\(userData.mediaProgress.count) currentPlayingBookID=\(currentPlayingBookID ?? "nil")"
    )

    for apiProgress in userData.mediaProgress {
      let bookID = apiProgress.episodeId ?? apiProgress.libraryItemId
      if let existing = progressMap[bookID] {
        existing.update(from: apiProgress)
      } else {
        let remote = MediaProgress(from: apiProgress)
        context.insert(remote)
        progressMap[bookID] = remote
      }
    }

    for localProgress in allLocalProgress where !remoteBookIDs.contains(localProgress.bookID) {
      if let currentPlayingBookID, localProgress.bookID == currentPlayingBookID {
        continue
      }
      context.delete(localProgress)
    }

    try context.save()
    MediaProgress.refreshCache()
  }

  private static func remoteValues(
    from apiProgress: User.MediaProgress
  ) -> (
    progress: Double, currentTime: TimeInterval, lastUpdate: Date, finishedAt: Date?
  ) {
    var progress = apiProgress.progress
    var currentTime = apiProgress.currentTime
    if apiProgress.isFinished {
      progress = 1.0
      currentTime = apiProgress.duration ?? 0
    }
    return (
      progress,
      currentTime,
      Date(timeIntervalSince1970: TimeInterval(apiProgress.lastUpdate / 1000)),
      apiProgress.finishedAt.map { Date(timeIntervalSince1970: TimeInterval($0 / 1000)) }
    )
  }
}
