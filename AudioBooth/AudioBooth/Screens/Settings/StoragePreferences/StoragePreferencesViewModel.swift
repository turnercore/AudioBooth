import API
import Foundation
import Models
import SwiftData

final class StoragePreferencesViewModel: StoragePreferencesView.Model {
  private let storageManager = StorageManager.shared

  override func onAppear() {
    Task {
      await loadStorageInfo()
    }
  }

  override func onClearDownloadsTapped() {
    showDownloadConfirmation = true
  }

  override func onKeepOfflineChanged() {
    KeepOfflineManager.shared.reconcile()
  }

  override func onClearCacheTapped() {
    showCacheConfirmation = true
  }

  override func onConfirmClearDownloads() {
    Task {
      isLoading = true
      let currentBookID = PlayerManager.shared.current?.id
      let servers = Audiobookshelf.shared.authentication.servers

      await DownloadManager.shared.deleteAllServerData()

      for server in servers.values {
        guard let context = try? ModelContextProvider.shared.context(for: server.id) else { continue }

        if let books = try? context.fetch(FetchDescriptor<LocalBook>()) {
          for book in books where book.bookID != currentBookID {
            context.delete(book)
          }
        }

        if let requests = try? context.fetch(FetchDescriptor<DownloadRequest>()) {
          for request in requests {
            context.delete(request)
          }
        }

        if let podcasts = try? context.fetch(FetchDescriptor<LocalPodcast>()) {
          for podcast in podcasts
          where !podcast.episodes.contains(where: { $0.episodeID == currentBookID }) {
            context.delete(podcast)
          }
        }

        try? context.save()
      }

      try? await Task.sleep(for: .seconds(0.5))
      await loadStorageInfo()
      Toast(success: "All downloads cleared").show()
    }
  }

  override func onConfirmClearCache() {
    Task {
      isLoading = true
      await storageManager.clearImageCache()
      try? await Task.sleep(for: .seconds(0.5))
      await loadStorageInfo()
      Toast(success: "Image cache cleared").show()
    }
  }

  override func onRemoveDownload(bookID: String, serverID: String) {
    if serverID == Audiobookshelf.shared.authentication.server?.id {
      DownloadManager.shared.deleteDownload(for: bookID)
    } else {
      guard
        let appGroupURL = FileManager.default.containerURL(
          forSecurityApplicationGroupIdentifier: "group.com.turnercore.audioBS"
        )
      else { return }

      let serverDir = appGroupURL.appendingPathComponent(serverID)
      try? FileManager.default.removeItem(
        at: serverDir.appendingPathComponent("audiobooks").appendingPathComponent(bookID)
      )
      try? FileManager.default.removeItem(
        at: serverDir.appendingPathComponent("ebooks").appendingPathComponent(bookID)
      )

      if let context = try? ModelContextProvider.shared.context(for: serverID) {
        let predicate = #Predicate<LocalBook> { $0.bookID == bookID }
        if let book = try? context.fetch(FetchDescriptor<LocalBook>(predicate: predicate)).first {
          context.delete(book)
          try? context.save()
        }
      }
    }

    Task {
      await loadStorageInfo()
    }
  }

  private func loadStorageInfo() async {
    isLoading = true

    let total = await storageManager.getTotalStorageUsed()
    let downloads = await storageManager.getDownloadedContentSize()
    let cache = await storageManager.getImageCacheSize()
    let breakdown = await Self.computeContentBreakdown()

    totalSize = total.formattedByteSize
    downloadSize = downloads.formattedByteSize
    cacheSize = cache.formattedByteSize

    audiobooksBytes = breakdown.audiobooksBytes
    audiobooksCount = breakdown.audiobooksCount
    ebooksBytes = breakdown.ebooksBytes
    ebooksCount = breakdown.ebooksCount
    imageCacheBytes = cache
    totalBytes = total

    serverDownloads = await buildServerDownloads()

    isLoading = false
  }

  private static func computeContentBreakdown() async -> (
    audiobooksBytes: Int64, audiobooksCount: Int, ebooksBytes: Int64, ebooksCount: Int
  ) {
    await Task.detached(priority: .utility) {
      computeContentBreakdownOnDisk()
    }.value
  }

  nonisolated private static func computeContentBreakdownOnDisk() -> (
    audiobooksBytes: Int64, audiobooksCount: Int, ebooksBytes: Int64, ebooksCount: Int
  ) {
    guard
      let appGroupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.turnercore.audioBS"
      )
    else {
      return (0, 0, 0, 0)
    }

    var audiobooksBytes: Int64 = 0
    var audiobooksCount = 0
    var ebooksBytes: Int64 = 0
    var ebooksCount = 0

    let servers =
      (try? FileManager.default.contentsOfDirectory(
        at: appGroupURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    for server in servers {
      let audiobooksDir = server.appendingPathComponent("audiobooks")
      let ebooksDir = server.appendingPathComponent("ebooks")

      if let books = try? FileManager.default.contentsOfDirectory(at: audiobooksDir, includingPropertiesForKeys: nil) {
        for book in books {
          let size = book.directorySize
          if size > 0 {
            audiobooksBytes += size
            audiobooksCount += 1
          }
        }
      }

      if let books = try? FileManager.default.contentsOfDirectory(at: ebooksDir, includingPropertiesForKeys: nil) {
        for book in books {
          let size = book.directorySize
          if size > 0 {
            ebooksBytes += size
            ebooksCount += 1
          }
        }
      }
    }

    return (audiobooksBytes, audiobooksCount, ebooksBytes, ebooksCount)
  }

  private func buildServerDownloads() async -> [StoragePreferencesView.ServerDownloads] {
    let servers = Audiobookshelf.shared.authentication.servers.values
      .map {
        ServerDownloadIdentity(
          id: $0.id,
          name: $0.alias ?? $0.baseURL.host() ?? $0.id
        )
      }
      .sorted { $0.name < $1.name }

    guard
      let appGroupURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.turnercore.audioBS"
      )
    else { return [] }

    let inventories = await Self.buildServerDownloadInventory(
      servers: servers,
      appGroupURL: appGroupURL
    )

    var result: [StoragePreferencesView.ServerDownloads] = []

    for inventory in inventories {
      let context = try? ModelContextProvider.shared.context(for: inventory.server.id)

      let bookRows: [StoragePreferencesView.DownloadedBook] = inventory.books.map { book in
        let (title, author) = bookMetadata(bookID: book.id, context: context)
        return StoragePreferencesView.DownloadedBook(
          id: book.id,
          serverID: inventory.server.id,
          title: title,
          author: author,
          size: book.bytes.formattedByteSize
        )
      }

      result.append(
        StoragePreferencesView.ServerDownloads(id: inventory.server.id, name: inventory.server.name, books: bookRows)
      )
    }

    return result
  }

  private static func buildServerDownloadInventory(
    servers: [ServerDownloadIdentity],
    appGroupURL: URL
  ) async -> [ServerDownloadInventory] {
    await Task.detached(priority: .utility) {
      servers.compactMap { server in
        let serverDir = appGroupURL.appendingPathComponent(server.id)
        var bookSizes: [String: Int64] = [:]

        let audiobookDir = serverDir.appendingPathComponent("audiobooks")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: audiobookDir, includingPropertiesForKeys: nil) {
          for dir in dirs {
            let size = dir.directorySize
            if size > 0 {
              bookSizes[dir.lastPathComponent, default: 0] += size
            }
          }
        }

        let ebooksDir = serverDir.appendingPathComponent("ebooks")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: ebooksDir, includingPropertiesForKeys: nil) {
          for dir in dirs {
            let size = dir.directorySize
            if size > 0 {
              bookSizes[dir.lastPathComponent, default: 0] += size
            }
          }
        }

        let books =
          bookSizes
          .map { ServerDownloadInventory.Book(id: $0.key, bytes: $0.value) }
          .sorted { $0.id < $1.id }

        guard !books.isEmpty else { return nil }
        return ServerDownloadInventory(server: server, books: books)
      }
    }.value
  }

  private func bookMetadata(bookID: String, context: ModelContext?) -> (String, String?) {
    guard let context else { return (bookID, nil) }
    let predicate = #Predicate<LocalBook> { $0.bookID == bookID }
    let descriptor = FetchDescriptor<LocalBook>(predicate: predicate)
    guard let book = try? context.fetch(descriptor).first else { return (bookID, nil) }
    return (book.title, book.authors.first?.name)
  }

}

private struct ServerDownloadIdentity: Sendable {
  let id: String
  let name: String
}

private struct ServerDownloadInventory: Sendable {
  struct Book: Sendable {
    let id: String
    let bytes: Int64
  }

  let server: ServerDownloadIdentity
  let books: [Book]
}
