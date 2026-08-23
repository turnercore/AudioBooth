import API
import Foundation
import Logging
import Models
import UIKit
import WatchConnectivity

@MainActor
final class WatchFileTransferCoordinator {
  static let shared = WatchFileTransferCoordinator()
  static let relayChunkSize = 48 * 1024
  private static let trackChunkSize = relayChunkSize

  /// Official transport splits tracks into moderate parts: small enough that
  /// WCSession's opportunistic queue will actually move them, few enough to
  /// stay manageable. Hardware evidence: a single 819 MB file never delivers;
  /// 16 MB parts delivered slowly under charging.
  static let fileTransferPartSize: Int64 = 64 * 1024 * 1024

  private struct OwnedShare: Codable, Sendable {
    let serverID: String
    let transferID: String
    let bookID: String
    let mediaItemID: String
    let shareID: String
    let slug: String
    let expiresAt: Date
    let replacementGeneration: Int
  }

  private enum Keys {
    static let jobs = "watch_file_transfer_jobs"
    static let ownedShares = "watch_owned_media_shares"
    static let relayManifestPrefix = "watch_relay_manifest_"
  }

  private static let shareLifetime: TimeInterval = 24 * 60 * 60

  private enum RelayError: LocalizedError {
    case unavailable
    case incomplete
    case invalidTransfer
    case invalidChunk
    case invalidRange
    case readFailed

    var errorDescription: String? {
      switch self {
      case .unavailable: return "The iPhone download is unavailable."
      case .incomplete: return "The iPhone download is incomplete."
      case .invalidTransfer: return "The Watch transfer is no longer active."
      case .invalidChunk, .invalidRange: return "The Watch requested an invalid audio chunk."
      case .readFailed: return "The iPhone could not read the requested audio chunk."
      }
    }
  }

  private let fileManager = FileManager.default
  private var attemptedThumbnailBookIDs: Set<String> = []
  private var shareOfferTasks: [String: Task<WatchShareOffer, Error>] = [:]
  private let stagingDirectory = DownloadManager.appGroupContainer.appendingPathComponent("watch-transfers")

  private(set) var jobs: [WatchTransferJob] {
    didSet { saveJobs() }
  }
  private var ownedShares: [OwnedShare] {
    didSet { saveOwnedShares() }
  }

  private init() {
    if let data = UserDefaults.standard.data(forKey: Keys.jobs),
      let jobs = try? JSONDecoder().decode([WatchTransferJob].self, from: data)
    {
      self.jobs = jobs
    } else {
      self.jobs = []
    }

    if let data = UserDefaults.standard.data(forKey: Keys.ownedShares),
      let shares = try? JSONDecoder().decode([OwnedShare].self, from: data)
    {
      self.ownedShares = shares
    } else {
      self.ownedShares = []
    }
  }

  var activeBookIDs: Set<String> {
    Set(
      jobs
        .filter { $0.state == .queued || $0.state == .transferring }
        .map(\.bookID)
    )
  }

  func phoneDownloadedBooks() -> [WatchPhoneLibraryBook] {
    let progressByBookID = Dictionary(
      uniqueKeysWithValues: ((try? MediaProgress.fetchAll()) ?? []).map { ($0.bookID, $0) }
    )

    return ((try? LocalBook.fetchAll()) ?? [])
      .compactMap { book in
        guard let manifest = manifest(for: book), sources(for: book, manifest: manifest) != nil else {
          return nil
        }
        return WatchPhoneLibraryBook(
          bookID: book.bookID,
          title: book.title,
          authorName: book.authorNames.nilIfEmpty,
          duration: book.duration,
          currentTime: progressByBookID[book.bookID]?.currentTime ?? 0,
          lastPlayedAt: progressByBookID[book.bookID]?.lastPlayedAt
        )
      }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
  }

  func prepareCatalogThumbnails(session: WCSession) async {
    let books = (try? LocalBook.fetchAll()) ?? []
    for book in books where !attemptedThumbnailBookIDs.contains(book.bookID) {
      attemptedThumbnailBookIDs.insert(book.bookID)
      guard let data = await fetchCoverData(for: book), let image = UIImage(data: data) else { continue }
      let size = CGSize(width: 72, height: 72)
      let renderer = UIGraphicsImageRenderer(size: size)
      let thumbnail = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
      }
      guard let thumbnailData = thumbnail.jpegData(compressionQuality: 0.65) else { continue }

      do {
        let directory = stagingDirectory.appendingPathComponent("catalog-thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(book.bookID)-\(UUID().uuidString).jpg")
        try thumbnailData.write(to: fileURL, options: .atomic)
        session.transferFile(
          fileURL,
          metadata: Self.propertyList(
            from: .thumbnail(bookID: book.bookID, byteCount: Int64(thumbnailData.count))
          )
        )
      } catch {
        AppLogger.watchConnectivity.warning(
          "Could not prepare Watch catalog artwork: \(error.localizedDescription)"
        )
      }
    }
  }

  func queueTransfer(bookID: String, session: WCSession) async {
    // This build uses the official opportunistic transferFile queue as the
    // primary transport. Share-based downloads remain implemented but are not
    // requested; outstanding temporary shares are revoked for hygiene.
    await revokeAllOwnedShares()
    retireStaleJobs(bookID: bookID)

    guard !activeBookIDs.contains(bookID) else { return }

    guard let book = try? LocalBook.fetch(bookID: bookID) else {
      recordFailure(bookID: bookID, description: "The iPhone download is unavailable.")
      return
    }
    guard let manifest = manifest(for: book), let sources = sources(for: book, manifest: manifest) else {
      recordFailure(bookID: bookID, description: "The iPhone download is incomplete.")
      return
    }

    // Ensure the local timeline is measured from the actual files so the
    // duration/progress baked into the manifest isn't the doubled server
    // estimate. This also corrects the 50% = finished tile bug for books
    // downloaded before the reconciler existed.
    await LocalPlaybackTimelineReconciler.reconcile(book: book)
    let reconciledBook = (try? LocalBook.fetch(bookID: bookID)) ?? book
    let freshManifest = self.manifest(for: reconciledBook) ?? manifest
    var freshCurrentTime = (try? MediaProgress.fetch(bookID: bookID))?.currentTime ?? freshManifest.currentTime

    // Re-validate sources against the reconciled manifest (same files, corrected durations).
    guard let freshSources = self.sources(for: reconciledBook, manifest: freshManifest) else {
      recordFailure(bookID: bookID, description: "The iPhone download is incomplete.")
      return
    }

    let transferID = UUID().uuidString
    jobs.append(
      WatchTransferJob(
        transferID: transferID,
        bookID: bookID,
        state: .queued,
        sentFileCount: 0,
        // Parts are staged to disk first so every transferFile hands the
        // queue a stable, right-sized file.
        totalFileCount: 1 + freshManifest.tracks.reduce(0) { $0 + Self.partCount(for: $1.byteCount) }
      )
    )

    let transferManifest = WatchTransferManifest(
      transferID: transferID,
      bookID: freshManifest.bookID,
      title: freshManifest.title,
      authorName: freshManifest.authorName,
      duration: freshManifest.duration,
      currentTime: min(freshCurrentTime, freshManifest.duration),
      tracks: freshManifest.tracks.map { track in
        WatchTransferManifest.Track(
          index: track.index,
          duration: track.duration,
          byteCount: track.byteCount,
          fileExtension: track.fileExtension,
          chunkCount: Self.partCount(for: track.byteCount)
        )
      },
      expectsCover: false,
      expectedCoverByteCount: nil
    )

    let manifestURL: URL
    do {
      manifestURL = try stageManifest(transferManifest)
    } catch {
      updateJob(transferID: transferID) {
        $0.state = .failed
        $0.failureDescription = "Could not prepare the Watch transfer."
        $0.updatedAt = Date()
      }
      return
    }

    do {
      // Cancel deletes staging asynchronously; never let transferFile see a
      // missing file (it raises an uncatchable Objective-C exception).
      func queueExisting(_ url: URL, _ metadata: WatchTransferFileMetadata) {
        guard isActive(transferID: transferID), fileManager.fileExists(atPath: url.path) else {
          return
        }
        queue(fileURL: url, metadata: metadata, session: session)
      }

      queueExisting(manifestURL, .manifest(transferID: transferID, bookID: bookID))
      for source in freshSources.sorted(by: { $0.trackIndex < $1.trackIndex }) {
        guard
          let track = transferManifest.tracks.first(where: { $0.index == source.trackIndex })
        else { continue }
        for part in try stageTrackParts(source: source, track: track, transferID: transferID) {
          queueExisting(
            part.fileURL,
            .trackChunk(
              transferID: transferID,
              bookID: bookID,
              track: track,
              chunkIndex: part.chunkIndex,
              byteCount: part.byteCount
            )
          )
        }
      }
      updateJob(transferID: transferID) {
        $0.state = .transferring
        $0.updatedAt = Date()
      }
    } catch {
      updateJob(transferID: transferID) {
        $0.state = .failed
        $0.failureDescription = "Could not queue the Watch transfer."
        $0.updatedAt = Date()
      }
      return
    }

    // Artwork is optional and must never delay or block the audio queue. The
    // phone may be suspended moments after handling the request, so this runs
    // last; failure simply means no cover art on Watch.
    guard isActive(transferID: transferID) else { return }
    if let coverURL = await stageCover(for: book, transferID: transferID),
      isActive(transferID: transferID),
      fileManager.fileExists(atPath: coverURL.path)
    {
      let byteCount = (try? fileManager.attributesOfItem(atPath: coverURL.path)[.size] as? NSNumber)?
        .int64Value
      queue(
        fileURL: coverURL,
        metadata: .cover(transferID: transferID, bookID: bookID, byteCount: byteCount),
        session: session
      )
      updateJob(transferID: transferID) { $0.totalFileCount += 1 }
    }
  }

  func prepareShareOffer(bookID: String) async throws -> WatchShareOffer {
    if let task = shareOfferTasks[bookID] { return try await task.value }

    let task = Task { @MainActor [self] in
      try await createShareOffer(bookID: bookID)
    }
    shareOfferTasks[bookID] = task
    defer { shareOfferTasks.removeValue(forKey: bookID) }
    return try await task.value
  }

  private func createShareOffer(
    bookID: String,
    replacingTransferID: String? = nil,
    replacementGeneration: Int = 0
  ) async throws -> WatchShareOffer {
    guard let server = Audiobookshelf.shared.authentication.server else {
      throw Audiobookshelf.AudiobookshelfError.networkError("No authenticated server.")
    }
    guard let book = try? LocalBook.fetch(bookID: bookID),
      let localManifest = manifest(for: book)
    else {
      throw RelayError.incomplete
    }

    await cleanupStaleShares()

    let now = Date()
    let descriptors = localManifest.tracks.map {
      WatchShareTrackDescriptor(
        index: $0.index,
        byteCount: $0.byteCount,
        fileExtension: $0.fileExtension
      )
    }

    if replacingTransferID == nil,
      let owned = ownedShares.last(where: {
        $0.serverID == server.id && $0.bookID == bookID && $0.expiresAt > now
      })
    {
      let offer = try makeOffer(owned: owned, serverURL: server.baseURL, tracks: descriptors)
      ensureShareJob(owned: owned, trackCount: descriptors.count)
      return offer
    }

    let remoteBook = try await Audiobookshelf.shared.books.fetch(id: bookID)
    guard let mediaItemID = remoteBook.media.id, !mediaItemID.isEmpty else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "The server did not provide the book media ID required for sharing."
      )
    }

    let transferID = replacingTransferID ?? UUID().uuidString
    let expiresAt = now.addingTimeInterval(Self.shareLifetime)
    let slug = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    let share: MediaItemShare
    do {
      share = try await Audiobookshelf.shared.shares.createMediaItemShare(
        mediaItemID: mediaItemID,
        slug: slug,
        expiresAt: expiresAt
      )
    } catch let NetworkError.httpError(statusCode, _) where statusCode == 409 {
      // A 409 may be another user's share. Only a persisted ID proves ownership.
      guard
        let known = ownedShares.last(where: {
          $0.serverID == server.id && $0.mediaItemID == mediaItemID
        })
      else { throw NetworkError.httpError(statusCode: statusCode, message: nil) }
      try await Audiobookshelf.shared.shares.deleteMediaItemShare(id: known.shareID)
      ownedShares.removeAll { $0.serverID == server.id && $0.shareID == known.shareID }
      share = try await Audiobookshelf.shared.shares.createMediaItemShare(
        mediaItemID: mediaItemID,
        slug: slug,
        expiresAt: expiresAt
      )
    }

    let owned = OwnedShare(
      serverID: server.id,
      transferID: transferID,
      bookID: bookID,
      mediaItemID: mediaItemID,
      shareID: share.id,
      slug: share.slug,
      expiresAt: share.expiresAt,
      replacementGeneration: replacementGeneration
    )
    do {
      let offer = try makeOffer(owned: owned, serverURL: server.baseURL, tracks: descriptors)
      ownedShares.append(owned)
      ensureShareJob(owned: owned, trackCount: descriptors.count)
      return offer
    } catch {
      await revokeOwnedShare(owned)
      throw error
    }
  }

  func replaceShareOffer(transferID: String, bookID: String) async throws -> WatchShareOffer {
    guard
      let current = ownedShares.last(where: {
        $0.transferID == transferID && $0.bookID == bookID
      })
    else {
      throw RelayError.invalidTransfer
    }
    await revokeOwnedShare(current)
    guard !ownedShares.contains(where: { $0.shareID == current.shareID }) else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "The expired share could not be revoked before replacement."
      )
    }
    return try await createShareOffer(
      bookID: bookID,
      replacingTransferID: transferID,
      replacementGeneration: current.replacementGeneration + 1
    )
  }

  func cleanupStaleShares() async {
    guard let server = Audiobookshelf.shared.authentication.server else { return }
    let now = Date()
    let stale = ownedShares.filter { share in
      guard share.serverID == server.id else { return false }
      guard share.expiresAt > now else { return true }
      guard let job = jobs.last(where: { $0.transferID == share.transferID }) else { return true }
      return job.state == .completed || job.state == .cancelled || job.state == .failed
    }
    for share in stale {
      if share.expiresAt <= now {
        ownedShares.removeAll { $0.serverID == share.serverID && $0.shareID == share.shareID }
      } else {
        await revokeOwnedShare(share)
      }
    }
  }

  /// Revokes every owned temporary share on the active server.
  func revokeAllOwnedShares() async {
    guard let server = Audiobookshelf.shared.authentication.server else { return }
    let shares = ownedShares.filter { $0.serverID == server.id }
    guard !shares.isEmpty else { return }
    for share in shares {
      try? await Audiobookshelf.shared.shares.deleteMediaItemShare(id: share.shareID)
    }
    ownedShares.removeAll { $0.serverID == server.id }
  }

  /// Cancels jobs left over from earlier transports so a fresh request always
  /// starts from a clean identity.
  private func retireStaleJobs(bookID: String) {
    for index in jobs.indices
    where jobs[index].bookID == bookID
      && (jobs[index].state == .queued || jobs[index].state == .transferring || jobs[index].state == .failed)
    {
      jobs[index].state = .cancelled
      jobs[index].failureDescription = nil
      jobs[index].updatedAt = Date()
      removeRelayManifest(transferID: jobs[index].transferID)
      try? fileManager.removeItem(at: transferDirectory(transferID: jobs[index].transferID))
    }
  }

  func beginRelay(
    bookID: String,
    preferredTransferID: String? = nil
  ) throws -> WatchTransferManifest {
    guard let book = try? LocalBook.fetch(bookID: bookID) else {
      recordFailure(bookID: bookID, description: RelayError.unavailable.localizedDescription)
      throw RelayError.unavailable
    }

    let activeJob = jobs.last {
      $0.bookID == bookID && ($0.state == .queued || $0.state == .transferring)
    }
    let transferID = activeJob?.transferID ?? preferredTransferID ?? UUID().uuidString
    let transferManifest =
      loadRelayManifest(transferID: transferID)
      ?? manifest(for: book, transferID: transferID)

    guard let transferManifest,
      transferManifest.bookID == bookID,
      transferManifest.transferID == transferID,
      sources(for: book, manifest: transferManifest) != nil
    else {
      if let activeJob {
        updateJob(transferID: activeJob.transferID) {
          $0.state = .failed
          $0.failureDescription = RelayError.incomplete.localizedDescription
          $0.updatedAt = Date()
        }
      } else {
        recordFailure(bookID: bookID, description: RelayError.incomplete.localizedDescription)
      }
      throw RelayError.incomplete
    }

    if activeJob == nil {
      let staleTransferIDs =
        jobs
        .filter { $0.bookID == bookID && isActive(transferID: $0.transferID) }
        .map(\.transferID)
      for transferID in staleTransferIDs {
        updateJob(transferID: transferID) {
          $0.state = .cancelled
          $0.updatedAt = Date()
        }
        removeRelayManifest(transferID: transferID)
      }
      jobs.append(
        WatchTransferJob(
          transferID: transferID,
          bookID: bookID,
          state: .transferring,
          sentFileCount: 0,
          totalFileCount: transferManifest.tracks.reduce(0) {
            $0 + $1.transferChunkCount
          }
        )
      )
    } else {
      updateJob(transferID: transferID) {
        $0.state = .transferring
        $0.failureDescription = nil
        $0.updatedAt = Date()
      }
    }

    do {
      UserDefaults.standard.set(
        try encodeRelayManifest(transferManifest),
        forKey: relayManifestKey(transferID: transferID)
      )
    } catch {
      updateJob(transferID: transferID) {
        $0.state = .failed
        $0.failureDescription = RelayError.unavailable.localizedDescription
        $0.updatedAt = Date()
      }
      throw RelayError.unavailable
    }

    return transferManifest
  }

  func relayChunkResponse(for request: WatchTransferChunkRequest) throws -> WatchTransferChunkResponse {
    guard let job = jobs.last(where: { $0.transferID == request.file.transferID }),
      isActive(transferID: job.transferID),
      job.bookID == request.file.bookID
    else {
      throw RelayError.invalidTransfer
    }

    guard request.file.kind == .track,
      request.file.chunkIndex == nil,
      let trackIndex = request.file.trackIndex,
      let manifest = loadRelayManifest(transferID: job.transferID),
      manifest.transferID == job.transferID,
      manifest.bookID == job.bookID,
      let track = manifest.tracks.first(where: { $0.index == trackIndex }),
      request.file
        == .track(
          transferID: manifest.transferID,
          bookID: manifest.bookID,
          trackIndex: track.index
        ),
      (0..<track.transferChunkCount).contains(request.chunkIndex)
    else {
      throw RelayError.invalidChunk
    }

    guard let book = try? LocalBook.fetch(bookID: job.bookID),
      let source = sources(for: book, manifest: manifest)?.first(where: {
        $0.trackIndex == track.index
      })
    else {
      throw RelayError.incomplete
    }

    let offset = Int64(request.chunkIndex) * Int64(Self.relayChunkSize)
    guard offset >= 0, offset < track.byteCount else {
      throw RelayError.invalidRange
    }
    let byteCount = Int(min(Int64(Self.relayChunkSize), track.byteCount - offset))
    guard byteCount > 0, let data = try readRange(from: source.fileURL, offset: offset, byteCount: byteCount),
      data.count == byteCount
    else {
      throw RelayError.readFailed
    }

    return WatchTransferChunkResponse(
      request: request,
      byteOffset: offset,
      data: data
    )
  }

  func cancelTransfer(bookID: String, session: WCSession) async {
    let activeTransferIDs = Set(
      jobs
        .filter { $0.bookID == bookID && ($0.state == .queued || $0.state == .transferring) }
        .map(\.transferID)
    )
    guard !activeTransferIDs.isEmpty else { return }

    for transfer in session.outstandingFileTransfers {
      guard
        let metadata = Self.metadata(from: transfer.file.metadata),
        activeTransferIDs.contains(metadata.transferID)
      else { continue }
      transfer.cancel()
    }

    for transferID in activeTransferIDs {
      updateJob(transferID: transferID) {
        $0.state = .cancelled
        $0.updatedAt = Date()
      }
      try? fileManager.removeItem(at: transferDirectory(transferID: transferID))
      removeRelayManifest(transferID: transferID)
      await revokeShares(transferID: transferID)
    }
  }

  func cancelAllTransfers(session: WCSession) async {
    for bookID in activeBookIDs {
      await cancelTransfer(bookID: bookID, session: session)
    }
  }

  func receiveCompletion(for fileTransfer: WCSessionFileTransfer, error: Error?) {
    guard let metadata = Self.metadata(from: fileTransfer.file.metadata) else { return }

    if metadata.kind == .thumbnail {
      try? fileManager.removeItem(at: fileTransfer.file.fileURL)
      return
    }

    guard isActive(transferID: metadata.transferID) else { return }

    if error != nil {
      updateJob(transferID: metadata.transferID) {
        $0.state = .failed
        $0.failureDescription = "A file could not be sent to the Watch."
        $0.updatedAt = Date()
      }
      return
    }

    updateJob(transferID: metadata.transferID) {
      $0.sentFileCount = min($0.totalFileCount, $0.sentFileCount + 1)
      $0.updatedAt = Date()
    }
  }

  func receiveWatchShareFailure(
    transferID: String,
    bookID: String
  ) async throws -> WatchTransferManifest {
    guard isActive(transferID: transferID),
      jobs.last(where: { $0.transferID == transferID })?.bookID == bookID
    else { throw RelayError.invalidTransfer }

    await revokeShares(transferID: transferID)
    let manifest = try beginRelay(bookID: bookID, preferredTransferID: transferID)
    updateJob(transferID: transferID) {
      $0.failureDescription = "The public share failed; continuing with the phone relay."
      $0.updatedAt = Date()
    }
    return manifest
  }

  func receiveWatchCancellation(transferID: String) async {
    guard isActive(transferID: transferID) else { return }
    updateJob(transferID: transferID) {
      $0.state = .cancelled
      $0.failureDescription = nil
      $0.updatedAt = Date()
    }
    try? fileManager.removeItem(at: transferDirectory(transferID: transferID))
    removeRelayManifest(transferID: transferID)
    await revokeShares(transferID: transferID)
  }

  /// The Watch calls this only after validating every expected file. It is the only completion signal.
  func receiveWatchCompletion(transferID: String) async {
    guard isActive(transferID: transferID) else { return }
    updateJob(transferID: transferID) {
      $0.state = .completed
      $0.sentFileCount = $0.totalFileCount
      $0.failureDescription = nil
      $0.updatedAt = Date()
    }
    try? fileManager.removeItem(at: transferDirectory(transferID: transferID))
    removeRelayManifest(transferID: transferID)
    await revokeShares(transferID: transferID)
  }

  private func manifest(
    for book: LocalBook,
    transferID: String = "pending"
  ) -> WatchTransferManifest? {
    let tracks = book.orderedTracks.compactMap { track -> WatchTransferManifest.Track? in
      guard
        let localURL = track.localPath,
        let byteCount = try? fileManager.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber
      else { return nil }

      let fileExtension = localURL.pathExtension
      guard !fileExtension.isEmpty else { return nil }
      let size = byteCount.int64Value
      guard size > 0 else { return nil }
      let chunkCount = Int((size - 1) / Int64(Self.trackChunkSize)) + 1
      return WatchTransferManifest.Track(
        index: track.index,
        duration: track.duration,
        byteCount: size,
        fileExtension: ".\(fileExtension)",
        chunkCount: chunkCount
      )
    }
    guard
      tracks.count == book.orderedTracks.count,
      !tracks.isEmpty,
      Set(tracks.map(\.index)).count == tracks.count
    else { return nil }

    return WatchTransferManifest(
      transferID: transferID,
      bookID: book.bookID,
      title: book.title,
      authorName: book.authorNames.nilIfEmpty,
      duration: book.duration,
      currentTime: (try? MediaProgress.fetch(bookID: book.bookID))?.currentTime ?? 0,
      tracks: tracks
    )
  }

  private func sources(
    for book: LocalBook,
    manifest: WatchTransferManifest
  ) -> [WatchTransferSource]? {
    let sources = book.orderedTracks.compactMap { track -> WatchTransferSource? in
      guard let localURL = track.localPath else { return nil }
      return WatchTransferSource(trackIndex: track.index, fileURL: localURL)
    }
    guard
      sources.count == manifest.tracks.count,
      WatchTransferSourceValidator.validate(manifest: manifest, sources: sources) == nil
    else {
      return nil
    }
    return sources
  }

  private func loadRelayManifest(transferID: String) -> WatchTransferManifest? {
    guard let data = UserDefaults.standard.data(forKey: relayManifestKey(transferID: transferID)) else {
      return nil
    }
    return try? PropertyListDecoder().decode(WatchTransferManifest.self, from: data)
  }

  private func removeRelayManifest(transferID: String) {
    UserDefaults.standard.removeObject(forKey: relayManifestKey(transferID: transferID))
  }

  private func relayManifestKey(transferID: String) -> String {
    Keys.relayManifestPrefix + transferID
  }

  private func encodeRelayManifest(_ manifest: WatchTransferManifest) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(manifest)
  }

  private func readRange(from url: URL, offset: Int64, byteCount: Int) throws -> Data? {
    guard offset >= 0, byteCount > 0 else { return nil }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))

    var result = Data(capacity: byteCount)
    while result.count < byteCount {
      guard let data = try handle.read(upToCount: byteCount - result.count), !data.isEmpty else {
        return nil
      }
      result.append(data)
    }
    return result
  }

  private func stageManifest(_ manifest: WatchTransferManifest) throws -> URL {
    let directory = transferDirectory(transferID: manifest.transferID)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("manifest.json")
    try JSONEncoder().encode(manifest).write(to: destination, options: .atomic)
    return destination
  }

  private static func partCount(for byteCount: Int64) -> Int {
    guard byteCount > 0 else { return 1 }
    return Int((byteCount - 1) / Self.fileTransferPartSize) + 1
  }

  private struct StagedPart: Sendable {
    let chunkIndex: Int
    let fileURL: URL
    let byteCount: Int64
  }

  /// Writes fixed-size parts of one source file into the transfer staging area.
  private func stageTrackParts(
    source: WatchTransferSource,
    track: WatchTransferManifest.Track,
    transferID: String
  ) throws -> [StagedPart] {
    let directory = transferDirectory(transferID: transferID).appendingPathComponent(
      "parts",
      isDirectory: true
    )
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    var parts: [StagedPart] = []
    let handle = try FileHandle(forReadingFrom: source.fileURL)
    defer { try? handle.close() }

    for chunkIndex in 0..<Self.partCount(for: track.byteCount) {
      guard let data = try handle.read(upToCount: Int(Self.fileTransferPartSize)),
        !data.isEmpty
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let destination = directory.appendingPathComponent(
        "track-\(track.index)-part-\(chunkIndex)\(track.fileExtension)"
      )
      try data.write(to: destination, options: .atomic)
      parts.append(
        StagedPart(
          chunkIndex: chunkIndex,
          fileURL: destination,
          byteCount: Int64(data.count)
        )
      )
    }
    let stagedBytes = parts.reduce(Int64(0)) { $0 + $1.byteCount }
    guard stagedBytes == track.byteCount else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return parts
  }

  private func stageCover(for book: LocalBook, transferID: String) async -> URL? {
    guard let data = await fetchCoverData(for: book) else { return nil }

    do {
      let directory = transferDirectory(transferID: transferID)
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      let destination = directory.appendingPathComponent("cover.jpg")
      try data.write(to: destination, options: .atomic)
      return destination
    } catch {
      AppLogger.watchConnectivity.warning("Could not stage Watch cover artwork: \(error.localizedDescription)")
      return nil
    }
  }

  private func fetchCoverData(for book: LocalBook) async -> Data? {
    // Route through the authenticated NetworkService pipeline so covers benefit
    // from the same host/alternative-URL fallback and custom headers as every
    // working API call, instead of a raw URLSession against a stored URL.
    do {
      return try await Audiobookshelf.shared.books.fetchCoverData(itemID: book.bookID)
    } catch {
      AppLogger.watchConnectivity.warning(
        "Could not fetch Watch cover artwork: \(error.localizedDescription)"
      )
      return nil
    }
  }

  private static func resolve(_ url: URL, against serverURL: URL) -> URL? {
    guard var cover = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let server = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
    else { return nil }
    cover.scheme = server.scheme
    cover.host = server.host
    cover.port = server.port
    return cover.url
  }

  private func queue(fileURL: URL, metadata: WatchTransferFileMetadata, session: WCSession) {
    session.transferFile(fileURL, metadata: Self.propertyList(from: metadata))
  }

  private func transferDirectory(transferID: String) -> URL {
    stagingDirectory.appendingPathComponent(transferID, isDirectory: true)
  }

  private func recordFailure(bookID: String, description: String) {
    jobs.append(
      WatchTransferJob(
        transferID: UUID().uuidString,
        bookID: bookID,
        state: .failed,
        sentFileCount: 0,
        totalFileCount: 0,
        failureDescription: description
      )
    )
  }

  private func isActive(transferID: String) -> Bool {
    guard let job = jobs.last(where: { $0.transferID == transferID }) else { return false }
    return job.state == .queued || job.state == .transferring
  }

  private func updateJob(transferID: String, update: (inout WatchTransferJob) -> Void) {
    guard let index = jobs.lastIndex(where: { $0.transferID == transferID }) else { return }
    update(&jobs[index])
  }

  private func makeOffer(
    owned: OwnedShare,
    serverURL: URL,
    tracks: [WatchShareTrackDescriptor]
  ) throws -> WatchShareOffer {
    let bootstrapURL =
      serverURL
      .appendingPathComponent("public/share")
      .appendingPathComponent(owned.slug)
    let offer = WatchShareOffer(
      transferID: owned.transferID,
      bookID: owned.bookID,
      shareID: owned.shareID,
      publicBootstrapURL: bootstrapURL,
      expiresAt: owned.expiresAt,
      tracks: tracks,
      replacementGeneration: owned.replacementGeneration
    )
    if let error = offer.validationError() { throw error }
    return offer
  }

  private func ensureShareJob(owned: OwnedShare, trackCount: Int) {
    if let index = jobs.lastIndex(where: { $0.transferID == owned.transferID }) {
      jobs[index].state = .transferring
      jobs[index].failureDescription = nil
      jobs[index].updatedAt = Date()
      return
    }

    for index in jobs.indices where jobs[index].bookID == owned.bookID && isActive(transferID: jobs[index].transferID) {
      jobs[index].state = .cancelled
      jobs[index].updatedAt = Date()
      removeRelayManifest(transferID: jobs[index].transferID)
    }
    jobs.append(
      WatchTransferJob(
        transferID: owned.transferID,
        bookID: owned.bookID,
        state: .transferring,
        sentFileCount: 0,
        totalFileCount: trackCount
      )
    )
  }

  private func revokeShares(transferID: String) async {
    for share in ownedShares.filter({ $0.transferID == transferID }) {
      await revokeOwnedShare(share)
    }
  }

  private func revokeOwnedShare(_ share: OwnedShare) async {
    guard Audiobookshelf.shared.authentication.server?.id == share.serverID else { return }
    do {
      try await Audiobookshelf.shared.shares.deleteMediaItemShare(id: share.shareID)
      ownedShares.removeAll { $0.serverID == share.serverID && $0.shareID == share.shareID }
    } catch let NetworkError.httpError(statusCode, _) where statusCode == 404 {
      ownedShares.removeAll { $0.serverID == share.serverID && $0.shareID == share.shareID }
    } catch {
      AppLogger.watchConnectivity.warning(
        "Could not revoke a temporary Watch share; cleanup will retry later: \(error.localizedDescription)"
      )
    }
  }

  private func saveJobs() {
    guard let data = try? JSONEncoder().encode(jobs) else { return }
    UserDefaults.standard.set(data, forKey: Keys.jobs)
  }

  private func saveOwnedShares() {
    guard let data = try? JSONEncoder().encode(ownedShares) else { return }
    UserDefaults.standard.set(data, forKey: Keys.ownedShares)
  }

  private static func binaryPropertyListData<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(value)
  }

  static func propertyList(from metadata: WatchTransferFileMetadata) -> [String: Any] {
    var result: [String: Any] = [
      "version": metadata.version,
      "kind": metadata.kind.rawValue,
      "transferID": metadata.transferID,
      "bookID": metadata.bookID,
    ]
    if let trackIndex = metadata.trackIndex { result["trackIndex"] = trackIndex }
    if let byteCount = metadata.byteCount { result["byteCount"] = byteCount }
    if let fileExtension = metadata.fileExtension { result["fileExtension"] = fileExtension }
    if let chunkIndex = metadata.chunkIndex { result["chunkIndex"] = chunkIndex }
    if let chunkCount = metadata.chunkCount { result["chunkCount"] = chunkCount }
    return result
  }

  static func metadata(from propertyList: [String: Any]?) -> WatchTransferFileMetadata? {
    guard
      let propertyList,
      let version = propertyList["version"] as? Int,
      let kindRawValue = propertyList["kind"] as? String,
      let kind = WatchTransferFileMetadata.Kind(rawValue: kindRawValue),
      let transferID = propertyList["transferID"] as? String,
      let bookID = propertyList["bookID"] as? String
    else { return nil }

    return WatchTransferFileMetadata(
      version: version,
      kind: kind,
      transferID: transferID,
      bookID: bookID,
      trackIndex: propertyList["trackIndex"] as? Int,
      byteCount: propertyList["byteCount"] as? Int64,
      fileExtension: propertyList["fileExtension"] as? String,
      chunkIndex: propertyList["chunkIndex"] as? Int,
      chunkCount: propertyList["chunkCount"] as? Int
    )
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
