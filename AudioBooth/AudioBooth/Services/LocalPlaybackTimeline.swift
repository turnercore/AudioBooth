import API
import AVFoundation
import Logging
import Models

nonisolated enum LocalPlaybackTimeline {
  struct MeasuredTrack: Equatable, Sendable {
    let index: Int
    let duration: TimeInterval
  }

  struct TrackTiming: Equatable, Sendable {
    let index: Int
    let startOffset: TimeInterval
    let duration: TimeInterval
  }

  struct Timeline: Equatable, Sendable {
    let tracks: [TrackTiming]
    let duration: TimeInterval
  }

  static func make(measuredTracks: [MeasuredTrack]) -> Timeline? {
    guard !measuredTracks.isEmpty else { return nil }

    let ordered = measuredTracks.sorted { $0.index < $1.index }
    guard Set(ordered.map(\.index)).count == ordered.count else { return nil }

    var offset: TimeInterval = 0
    var timings: [TrackTiming] = []
    timings.reserveCapacity(ordered.count)

    for track in ordered {
      guard track.duration.isFinite, track.duration > 0 else { return nil }
      timings.append(
        TrackTiming(index: track.index, startOffset: offset, duration: track.duration)
      )
      offset += track.duration
    }

    return Timeline(tracks: timings, duration: offset)
  }
}

@MainActor
enum LocalPlaybackTimelineReconciler {
  static func reconcile(book: LocalBook, mediaProgress: MediaProgress? = nil) async {
    guard let serverID = Audiobookshelf.shared.authentication.server?.id,
      ModelContextProvider.shared.activeServerID == serverID
    else { return }

    let bookID = book.bookID
    let localTracks = book.orderedTracks.compactMap { track in
      track.localPath.map { (index: track.index, url: $0) }
    }
    guard localTracks.count == book.tracks.count else { return }

    var measuredTracks: [LocalPlaybackTimeline.MeasuredTrack] = []
    measuredTracks.reserveCapacity(localTracks.count)

    for track in localTracks {
      let url = track.url

      do {
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        measuredTracks.append(.init(index: track.index, duration: duration))
      } catch {
        AppLogger.player.warning("Could not measure downloaded track \(track.index): \(error.localizedDescription)")
        return
      }
    }

    guard Audiobookshelf.shared.authentication.server?.id == serverID,
      ModelContextProvider.shared.activeServerID == serverID,
      let currentBook = try? LocalBook.fetch(bookID: bookID),
      let timeline = LocalPlaybackTimeline.make(measuredTracks: measuredTracks)
    else { return }

    let timingByIndex = Dictionary(uniqueKeysWithValues: timeline.tracks.map { ($0.index, $0) })
    let durationTolerance: TimeInterval = 1
    let needsReconciliation =
      abs(currentBook.duration - timeline.duration) > durationTolerance
      || currentBook.tracks.contains { track in
        guard let timing = timingByIndex[track.index] else { return true }
        return abs(track.startOffset - timing.startOffset) > durationTolerance
          || abs(track.duration - timing.duration) > durationTolerance
      }

    guard needsReconciliation else { return }

    let previousDuration = currentBook.duration
    for track in currentBook.tracks {
      guard let timing = timingByIndex[track.index] else { continue }
      track.startOffset = timing.startOffset
      track.duration = timing.duration
    }
    currentBook.duration = timeline.duration

    do {
      try currentBook.save()

      let progress = mediaProgress ?? (try? MediaProgress.fetch(bookID: bookID))
      if let progress {
        progress.duration = timeline.duration
        progress.currentTime = min(progress.currentTime, timeline.duration)
        progress.progress = timeline.duration > 0 ? progress.currentTime / timeline.duration : 0
        progress.isFinished = progress.progress >= 1
        progress.finishedAt = progress.isFinished ? (progress.finishedAt ?? Date()) : nil
        try progress.save()
      }

      AppLogger.player.info(
        "Reconciled downloaded timeline for \(bookID): \(previousDuration)s -> \(timeline.duration)s"
      )
    } catch {
      AppLogger.player.error("Failed to save reconciled downloaded timeline for \(bookID): \(error)")
    }
  }
}
