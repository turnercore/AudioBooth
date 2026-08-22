import API
import Foundation
import Logging
import Models
import Nuke
import SwiftData

final class StorageManager {
  static let shared = StorageManager()

  private init() {}

  func getDownloadedContentSize() async -> Int64 {
    await Task.detached { Self.downloadedContentSize() }.value
  }

  nonisolated private static func downloadedContentSize() -> Int64 {
    guard
      let appGroupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.turnercore.audioBS"
      )
    else {
      return 0
    }

    var totalSize: Int64 = 0

    do {
      let directories = try FileManager.default.contentsOfDirectory(
        at: appGroupURL,
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      )

      for directory in directories {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
          totalSize += directory.directorySize
        }
      }
    } catch {
      return 0
    }

    return totalSize
  }

  func getImageCacheSize() async -> Int64 {
    guard let dataCache = ImagePipeline.shared.configuration.dataCache as? DataCache else {
      return 0
    }

    return await Task.detached {
      Int64(dataCache.totalSize)
    }.value
  }

  func getTotalStorageUsed() async -> Int64 {
    let downloadSize = await getDownloadedContentSize()
    let cacheSize = await getImageCacheSize()
    return downloadSize + cacheSize
  }

  func canDownload(additionalBytes: Int64 = 0) async -> Bool {
    let limitGB = UserPreferences.shared.maxDownloadStorageGB
    guard limitGB > 0 else { return true }

    let maxBytes = Int64(limitGB) * 1_000_000_000
    let currentUsage = await getDownloadedContentSize()
    return (currentUsage + additionalBytes) < maxBytes
  }

  func cleanupUnusedDownloads() async {
    let setting = await MainActor.run { UserPreferences.shared.removeAfterUnused }
    guard setting != .never else { return }

    let days = setting.rawValue
    let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    let currentlyPlaying = await MainActor.run { PlayerManager.shared.current?.id }

    AppLogger.download.info("Cleaning up downloads unused since \(cutoffDate)")

    let staleBookIDs = await MainActor.run {
      let servers = Audiobookshelf.shared.authentication.servers
      var result: [String] = []

      for server in servers.values {
        do {
          let context = try ModelContextProvider.shared.context(for: server.id)

          let bookDescriptor = FetchDescriptor<LocalBook>()
          let allBooks = try context.fetch(bookDescriptor)
          let downloadedBooks = allBooks.filter { $0.isDownloaded || $0.mediaType.contains(.ebook) }
          let progressByBookID = (try context.fetch(FetchDescriptor<MediaProgress>()))
            .reduce(into: [String: MediaProgress]()) { result, progress in
              result[progress.bookID] = progress
            }

          for book in downloadedBooks {
            if book.bookID == currentlyPlaying { continue }

            let lastUsed = progressByBookID[book.bookID]?.lastPlayedAt ?? book.createdAt

            if lastUsed < cutoffDate {
              AppLogger.download.info("Removing unused download: \(book.title) (last used: \(lastUsed))")
              result.append(book.bookID)
            }
          }
        } catch {
          AppLogger.download.error("Failed to cleanup downloads for server \(server.id): \(error)")
        }
      }
      return result
    }

    for bookID in staleBookIDs {
      DownloadManager.shared.deleteDownload(for: bookID)
    }
  }

  func clearImageCache() async {
    ImagePipeline.shared.cache.removeAll()

    guard let dataCache = ImagePipeline.shared.configuration.dataCache as? DataCache else {
      return
    }

    dataCache.removeAll()
    dataCache.flush()
    URLCache.shared.removeAllCachedResponses()
  }

}

extension Int64 {
  var formattedByteSize: String {
    ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
  }
}
