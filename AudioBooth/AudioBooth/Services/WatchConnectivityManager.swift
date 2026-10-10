import API
import Combine
import Foundation
import Logging
import Models
import WatchConnectivity

final class WatchConnectivityManager: NSObject, ObservableObject {
  static let shared = WatchConnectivityManager()

  private var session: WCSession?
  private var context: [String: Any] = [:]
  @MainActor private var progressSyncTasks: [String: Task<Void, Never>] = [:]
  private let fileTransferCoordinator = WatchFileTransferCoordinator.shared
  private var pendingLocalSessions: [String: [String: Any]] = [:]
  private var localSessionSyncTask: Task<Bool, Never>?
  private var lastQueuedDownloadsRefresh: Date?

  private var syncedLocalSessions: [String: Double] {
    didSet { UserDefaults.standard.set(syncedLocalSessions, forKey: Keys.syncedLocalSessions) }
  }

  private enum Keys {
    static let watchDownloadedBookIDs = "watch_downloaded_book_ids"
    static let watchQueuedBookIDs = "watch_queued_book_ids"
    static let syncedLocalSessions = "synced_local_sessions"
  }

  @Published private(set) var watchDownloadedBookIDs: [String] {
    didSet { UserDefaults.standard.set(watchDownloadedBookIDs, forKey: Keys.watchDownloadedBookIDs) }
  }

  @Published private(set) var watchQueuedBookIDs: [String] {
    didSet { UserDefaults.standard.set(watchQueuedBookIDs, forKey: Keys.watchQueuedBookIDs) }
  }

  @Published private(set) var canDownloadToWatch = false

  private override init() {
    syncedLocalSessions =
      UserDefaults.standard.dictionary(forKey: Keys.syncedLocalSessions) as? [String: Double] ?? [:]
    watchDownloadedBookIDs = UserDefaults.standard.stringArray(forKey: Keys.watchDownloadedBookIDs) ?? []
    watchQueuedBookIDs = UserDefaults.standard.stringArray(forKey: Keys.watchQueuedBookIDs) ?? []
    super.init()

    context["syncedLocalSessions"] = syncedLocalSessions

    if WCSession.isSupported() {
      session = WCSession.default
      session?.delegate = self
      session?.activate()
    }
  }

  static var watchDeviceID: String {
    SessionService.deviceID + "-watch"
  }

  func syncProgress(_ bookID: String, chapterProgress: Double? = nil) {
    guard let current = try? MediaProgress.fetch(bookID: bookID) else { return }

    var progress = context["progress"] as? [String: Double] ?? [:]
    progress[bookID] = current.currentTime

    var progressUpdatedAt = context["progressUpdatedAt"] as? [String: Double] ?? [:]
    progressUpdatedAt[bookID] = current.lastUpdate.timeIntervalSince1970

    context["progress"] = progress
    context["progressUpdatedAt"] = progressUpdatedAt

    if let chapterProgress {
      context["chapterProgress"] = chapterProgress
    } else {
      context.removeValue(forKey: "chapterProgress")
    }

    updateContext()
  }

  func syncContinueListening(books: [Book]) {
    let allProgress = (try? MediaProgress.fetchAll()) ?? []
    let progressByBookID = Dictionary(
      allProgress.map { ($0.bookID, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    var continueListening: [[String: Any]] = []
    var progress: [String: Double] = [:]
    var progressUpdatedAt: [String: Double] = [:]

    for book in books {
      continueListening.append([
        "id": book.id,
        "title": book.title,
        "author": book.authorName as Any,
        "duration": book.duration,
      ])

      if let mediaProgress = progressByBookID[book.id] {
        progress[book.id] = mediaProgress.currentTime
        progressUpdatedAt[book.id] = mediaProgress.lastUpdate.timeIntervalSince1970
      }

      if continueListening.count >= 5 { break }
    }

    for bookID in watchDownloadedBookIDs {
      if let mediaProgress = progressByBookID[bookID] {
        progress[bookID] = mediaProgress.currentTime
        progressUpdatedAt[bookID] = mediaProgress.lastUpdate.timeIntervalSince1970
      }
    }

    context["continueListening"] = continueListening
    context["progress"] = progress
    context["progressUpdatedAt"] = progressUpdatedAt
    updateContext()

    AppLogger.watchConnectivity.info(
      "Synced \(continueListening.count) continue listening books"
    )
  }

  private func refreshContinueListening() {
    Task {
      do {
        let personalized = try await Audiobookshelf.shared.libraries.fetchPersonalized()

        for section in personalized.sections {
          if section.id == "continue-listening" {
            if case .books(let books) = section.entities {
              syncContinueListening(books: books)
              AppLogger.watchConnectivity.info("Refreshed continue listening from server on watch request")
            }
            break
          }
        }
      } catch {
        AppLogger.watchConnectivity.error("Failed to fetch personalized data for watch refresh: \(error)")
      }
    }
  }

  private func refreshProgress() {
    let continueListening = context["continueListening"] as? [[String: Any]] ?? []
    var progress: [String: Double] = [:]
    var progressUpdatedAt: [String: Double] = [:]

    let allProgress = (try? MediaProgress.fetchAll()) ?? []
    let progressByBookID = Dictionary(
      allProgress.map { ($0.bookID, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    var bookIDs = continueListening.compactMap { $0["id"] as? String }
    bookIDs.append(contentsOf: watchDownloadedBookIDs)
    if let currentID = PlayerManager.shared.current?.id {
      bookIDs.append(currentID)
    }

    for bookID in bookIDs {
      guard let mediaProgress = progressByBookID[bookID] else { continue }
      progress[bookID] = mediaProgress.currentTime
      progressUpdatedAt[bookID] = mediaProgress.lastUpdate.timeIntervalSince1970
    }

    context["progress"] = progress
    context["progressUpdatedAt"] = progressUpdatedAt
    updateContext()
  }

  func syncPhoneDownloadedBooks() {
    publishPhoneDownloadedBooks()
    guard let session else { return }
    Task { @MainActor in
      await fileTransferCoordinator.prepareCatalogThumbnails(session: session)
    }
  }

  private func publishPhoneDownloadedBooks() {
    context["phoneDownloadedBooks"] = try? JSONEncoder().encode(
      fileTransferCoordinator.phoneDownloadedBooks()
    )
    context["watchTransferJobs"] = try? JSONEncoder().encode(fileTransferCoordinator.jobs)
    updateContext()
  }

  func cancelWatchTransfers(for bookID: String) {
    guard let session else { return }
    Task { @MainActor in
      await fileTransferCoordinator.cancelTransfer(bookID: bookID, session: session)
      syncPhoneDownloadedBooks()
    }
  }

  func cancelAllWatchTransfers() {
    guard let session else { return }
    Task { @MainActor in
      await fileTransferCoordinator.cancelAllTransfers(session: session)
      syncPhoneDownloadedBooks()
    }
  }

  private func updateContext() {
    guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
      return
    }
    context["skipForwardInterval"] = UserPreferences.shared.skipForwardInterval
    context["skipBackwardInterval"] = UserPreferences.shared.skipBackwardInterval
    do {
      try session.updateApplicationContext(context)
    } catch {
      AppLogger.watchConnectivity.error(
        "Failed to sync context to watch: \(error)"
      )
    }
  }

  func syncHomeSections(sections: [Personalized.Section], enabledSections: [HomeSection]) {
    let excludedIDs: Set<String> = ["continue-listening", "continue-reading"]

    var bookCountByID: [String: Int] = [:]
    for section in sections {
      guard !excludedIDs.contains(section.id) else { continue }
      guard case .books(let books) = section.entities, !books.isEmpty else { continue }
      bookCountByID[section.id] = books.count
    }

    var sectionMetadata: [[String: Any]] = []
    for sectionCase in enabledSections {
      guard let count = bookCountByID[sectionCase.rawValue] else { continue }
      sectionMetadata.append([
        "id": sectionCase.rawValue,
        "name": sectionCase.displayName,
        "count": count,
      ])
    }

    context["homeSections"] = sectionMetadata
    updateContext()
  }

  func sendPlaybackRate(_ rate: Float?) {
    if let rate {
      context["playbackRate"] = rate
      context["hasCurrentBook"] = true
    } else {
      context.removeValue(forKey: "playbackRate")
      context.removeValue(forKey: "hasCurrentBook")
      context.removeValue(forKey: "chapterProgress")
      context.removeValue(forKey: "currentBook")
    }

    updateContext()
  }

  func sendCurrentBook(id: String, title: String, author: String?, coverURL: URL?, duration: TimeInterval) {
    context["currentBook"] = [
      "id": id,
      "title": title,
      "author": author as Any,
      "coverURL": watchCompatibleCoverURL(from: coverURL) as Any,
      "duration": duration,
    ]
    updateContext()
  }

  func requestWatchDownload(bookID: String) {
    Task {
      await sendDownloadRequest(bookID: bookID, refreshOnly: false)
    }
  }

  func refreshQueuedWatchDownloads() {
    let queuedBookIDs = watchQueuedBookIDs
    guard !queuedBookIDs.isEmpty, canDownloadToWatch else { return }

    if let lastQueuedDownloadsRefresh, Date().timeIntervalSince(lastQueuedDownloadsRefresh) < 60 {
      return
    }
    lastQueuedDownloadsRefresh = Date()

    Task {
      for bookID in queuedBookIDs {
        await sendDownloadRequest(bookID: bookID, refreshOnly: true)
      }
    }
  }

  private func sendDownloadRequest(bookID: String, refreshOnly: Bool) async {
    guard let session, canDownloadToWatch else { return }

    // Refresh the existing catalog without creating another transfer. New requests
    // use bounded public shares and the phone's local-file chunk fallback.
    if !refreshOnly {
      await fileTransferCoordinator.queueTransfer(bookID: bookID, session: session)
    }
    syncPhoneDownloadedBooks()
  }

  private func updateWatchDownloadStatus(downloaded: [String], queued: [String]) {
    watchDownloadedBookIDs = downloaded
    watchQueuedBookIDs = queued
  }

  private func updateCanDownloadToWatch() {
    guard let session else { return }
    canDownloadToWatch = session.activationState == .activated && session.isPaired && session.isWatchAppInstalled
  }

  private func watchCompatibleCoverURL(from url: URL?) -> String? {
    guard let url = url else { return nil }

    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "width", value: "200"),
      URLQueryItem(name: "format", value: "jpeg"),
    ]
    return components?.url?.absoluteString ?? url.absoluteString
  }

  private static func binaryPropertyListData<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try encoder.encode(value)
  }
}

extension WatchConnectivityManager: WCSessionDelegate {
  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if let error {
      AppLogger.watchConnectivity.error(
        "Watch session activation failed: \(error)"
      )
    } else {
      AppLogger.watchConnectivity.info(
        "Watch session activated with state: \(activationState.rawValue)"
      )

      Task { @MainActor in
        updateCanDownloadToWatch()
        refreshQueuedWatchDownloads()
      }

      Task {
        guard activationState == .activated else { return }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        syncPhoneDownloadedBooks()
        if Audiobookshelf.shared.authentication.server != nil {
          syncCachedDataToWatch()
        }
      }
    }
  }

  private func syncCachedDataToWatch() {
    syncPhoneDownloadedBooks()

    guard let personalized = Audiobookshelf.shared.libraries.getCachedPersonalized() else {
      AppLogger.watchConnectivity.info("No cached personalized data to sync to watch")
      return
    }

    for section in personalized.sections {
      if section.id == "continue-listening" {
        if case .books(let books) = section.entities {
          syncContinueListening(books: books)
          AppLogger.watchConnectivity.info(
            "Synced cached continue listening to watch on activation"
          )
        }
        break
      }
    }

    syncHomeSections(
      sections: personalized.sections,
      enabledSections: UserPreferences.shared.homeSections
    )
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    Task { @MainActor in
      updateCanDownloadToWatch()
    }
  }

  func sessionDidBecomeInactive(_ session: WCSession) {
    AppLogger.watchConnectivity.info("Watch session became inactive")
  }

  func sessionDidDeactivate(_ session: WCSession) {
    AppLogger.watchConnectivity.info("Watch session deactivated, reactivating...")
    session.activate()
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    AppLogger.watchConnectivity.debug("Received message from watch: \(message)")

    guard let command = message["command"] as? String else { return }

    Task { @MainActor in
      switch command {
      case "play":
        if let bookID = message["bookID"] as? String {
          handlePlayCommand(bookID: bookID, currentTime: message["currentTime"] as? Double)
        } else {
          PlayerManager.shared.current?.onPlayTapped()
        }
      case "pause":
        PlayerManager.shared.current?.onPauseTapped()
      case "skipForward":
        PlayerManager.shared.current?.onSkipForwardTapped(seconds: UserPreferences.shared.skipForwardInterval)
      case "skipBackward":
        PlayerManager.shared.current?.onSkipBackwardTapped(seconds: UserPreferences.shared.skipBackwardInterval)
      case "changePlaybackRate":
        if let rate = message["rate"] as? Float {
          PlayerManager.shared.current?.speed.onValueChanged(Double(rate))
        }
      case "refreshContinueListening":
        refreshContinueListening()
      case "syncDownloadedBooks":
        updateWatchDownloadStatus(
          downloaded: message["bookIDs"] as? [String] ?? [],
          queued: message["queuedBookIDs"] as? [String] ?? []
        )
        refreshProgress()
      case "requestPhoneDownloads":
        syncPhoneDownloadedBooks()
      case "requestWatchTransfer":
        guard let bookID = message["bookID"] as? String else { return }
        await fileTransferCoordinator.queueTransfer(bookID: bookID, session: session)
        syncPhoneDownloadedBooks()
      case "cancelWatchTransfer":
        guard let bookID = message["bookID"] as? String else { return }
        cancelWatchTransfers(for: bookID)
      case "watchTransferCompleted", "watchShareCompleted":
        guard let transferID = message["transferID"] as? String else { return }
        await fileTransferCoordinator.receiveWatchCompletion(transferID: transferID)
        syncPhoneDownloadedBooks()
      case "watchShareCancelled":
        guard let transferID = message["transferID"] as? String else { return }
        await fileTransferCoordinator.receiveWatchCancellation(transferID: transferID)
        syncPhoneDownloadedBooks()
      case "watchShareFailed":
        guard let transferID = message["transferID"] as? String,
          let bookID = message["bookID"] as? String
        else { return }
        await deliverRelayFallback(transferID: transferID, bookID: bookID, session: session)
        syncPhoneDownloadedBooks()
      case "requestWatchShareReplacement":
        guard let transferID = message["transferID"] as? String,
          let bookID = message["bookID"] as? String
        else { return }
        await sendReplacementShare(transferID: transferID, bookID: bookID, session: session)
      default:
        AppLogger.watchConnectivity.warning(
          "Unknown command from watch: \(command)"
        )
      }
    }
  }

  func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
    Task { @MainActor in
      fileTransferCoordinator.receiveCompletion(for: fileTransfer, error: error)
      syncPhoneDownloadedBooks()
    }
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    guard let command = userInfo["command"] as? String else { return }

    Task { @MainActor in
      switch command {
      case "syncLocalSessions":
        guard let sessionsData = userInfo["sessions"] as? [[String: Any]] else { return }
        _ = await receiveLocalSessions(sessionsData)
      case "syncDownloadedBooks":
        updateWatchDownloadStatus(
          downloaded: userInfo["bookIDs"] as? [String] ?? [],
          queued: userInfo["queuedBookIDs"] as? [String] ?? []
        )
        refreshProgress()
      case "requestPhoneDownloads":
        syncPhoneDownloadedBooks()
      case "requestWatchTransfer":
        guard let bookID = userInfo["bookID"] as? String else { return }
        await fileTransferCoordinator.queueTransfer(bookID: bookID, session: session)
        syncPhoneDownloadedBooks()
      case "cancelWatchTransfer":
        guard let bookID = userInfo["bookID"] as? String else { return }
        await fileTransferCoordinator.cancelTransfer(bookID: bookID, session: session)
        syncPhoneDownloadedBooks()
      case "watchTransferCompleted", "watchShareCompleted":
        guard let transferID = userInfo["transferID"] as? String else { return }
        await fileTransferCoordinator.receiveWatchCompletion(transferID: transferID)
        syncPhoneDownloadedBooks()
      case "watchShareCancelled":
        guard let transferID = userInfo["transferID"] as? String else { return }
        await fileTransferCoordinator.receiveWatchCancellation(transferID: transferID)
        syncPhoneDownloadedBooks()
      case "watchShareFailed":
        guard let transferID = userInfo["transferID"] as? String,
          let bookID = userInfo["bookID"] as? String
        else { return }
        await deliverRelayFallback(transferID: transferID, bookID: bookID, session: session)
        syncPhoneDownloadedBooks()
      case "requestWatchShareReplacement":
        guard let transferID = userInfo["transferID"] as? String,
          let bookID = userInfo["bookID"] as? String
        else { return }
        await sendReplacementShare(transferID: transferID, bookID: bookID, session: session)
      default:
        break
      }
    }
  }

  func session(
    _ session: WCSession,
    didReceiveMessageData messageData: Data,
    replyHandler: @escaping (Data) -> Void
  ) {
    let request: WatchTransferChunkRequest
    do {
      request = try PropertyListDecoder().decode(WatchTransferChunkRequest.self, from: messageData)
    } catch {
      AppLogger.watchConnectivity.warning("Rejected invalid Watch relay chunk request")
      replyHandler(Data())
      return
    }

    Task { @MainActor in
      do {
        let response = try fileTransferCoordinator.relayChunkResponse(for: request)
        replyHandler(try Self.binaryPropertyListData(response))
      } catch {
        AppLogger.watchConnectivity.warning(
          "Rejected Watch relay chunk request: \(error.localizedDescription)"
        )
        replyHandler(Data())
      }
    }
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    AppLogger.watchConnectivity.debug("Received message with reply from watch: \(message)")

    guard let command = message["command"] as? String else {
      replyHandler(["error": "Missing command"])
      return
    }

    Task {
      switch command {
      case "requestWatchRelay":
        guard let bookID = message["bookID"] as? String else {
          replyHandler(["error": "Missing bookID"])
          return
        }
        await handleWatchRelayRequest(bookID: bookID, replyHandler: replyHandler)

      case "startSession":
        guard let bookID = message["bookID"] as? String else {
          replyHandler(["error": "Missing bookID"])
          return
        }

        let forDownload = message["forDownload"] as? Bool ?? false
        await handleStartSession(
          bookID: bookID,
          forDownload: forDownload,
          replyHandler: replyHandler
        )

      case "fetchSectionBooks":
        guard let sectionID = message["sectionID"] as? String else {
          replyHandler(["error": "Missing sectionID"])
          return
        }
        await handleFetchSectionBooks(sectionID: sectionID, replyHandler: replyHandler)

      case "syncLocalSessions":
        guard let sessionsData = message["sessions"] as? [[String: Any]] else {
          replyHandler(["error": "Missing sessions"])
          return
        }
        if await receiveLocalSessions(sessionsData) {
          replyHandler(["success": true])
        } else {
          replyHandler(["error": "Failed to sync local sessions"])
        }

      default:
        replyHandler(["error": "Unknown command: \(command)"])
      }
    }
  }

  @MainActor
  private func deliverRelayFallback(
    transferID: String,
    bookID: String,
    session: WCSession
  ) async {
    do {
      let manifest = try await fileTransferCoordinator.receiveWatchShareFailure(
        transferID: transferID,
        bookID: bookID
      )
      session.transferUserInfo([
        "watchRelayManifest": try Self.binaryPropertyListData(manifest),
        "transferID": transferID,
        "bookID": bookID,
      ])
    } catch {
      AppLogger.watchConnectivity.warning(
        "Could not start Watch relay fallback: \(error.localizedDescription)"
      )
    }
  }

  @MainActor
  private func sendReplacementShare(
    transferID: String,
    bookID: String,
    session: WCSession
  ) async {
    do {
      let offer = try await fileTransferCoordinator.replaceShareOffer(
        transferID: transferID,
        bookID: bookID
      )
      session.transferUserInfo([
        "watchShareOffer": try Self.binaryPropertyListData(offer)
      ])
      syncPhoneDownloadedBooks()
    } catch {
      AppLogger.watchConnectivity.warning(
        "Could not replace an expired Watch share: \(error.localizedDescription)"
      )
    }
  }

  @MainActor
  private func handleWatchRelayRequest(
    bookID: String,
    replyHandler: @escaping ([String: Any]) -> Void
  ) async {
    do {
      do {
        let offer = try await fileTransferCoordinator.prepareShareOffer(bookID: bookID)
        let offerData = try Self.binaryPropertyListData(offer)
        replyHandler(["shareOffer": offerData])
        session?.transferUserInfo(["watchShareOffer": offerData])
      } catch {
        AppLogger.watchConnectivity.warning(
          "Could not prepare public Watch share; continuing with relay: \(error.localizedDescription)"
        )
        let manifest = try fileTransferCoordinator.beginRelay(bookID: bookID)
        replyHandler(["manifest": try Self.binaryPropertyListData(manifest)])
      }
      syncPhoneDownloadedBooks()
    } catch {
      AppLogger.watchConnectivity.warning(
        "Could not start Watch relay: \(error.localizedDescription)"
      )
      replyHandler(["error": error.localizedDescription])
    }
  }

  private func handleStartSession(
    bookID: String,
    forDownload: Bool,
    replyHandler: @escaping ([String: Any]) -> Void
  ) async {
    do {
      replyHandler(try await makeSessionPayload(bookID: bookID, forDownload: forDownload))
    } catch {
      AppLogger.watchConnectivity.error("Failed to start session: \(error)")
      replyHandler(["error": error.localizedDescription])
    }
  }

  private func makeSessionPayload(bookID: String, forDownload: Bool) async throws -> [String: Any] {
    guard let serverURL = Audiobookshelf.shared.authentication.serverURL else {
      throw NSError(
        domain: "WatchConnectivity",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "No server URL"]
      )
    }

    let book: Book
    let sessionID: String?
    let audioTracks: [AudioTrack]

    if forDownload {
      book = try await Audiobookshelf.shared.books.fetch(id: bookID)
      sessionID = nil
      audioTracks = book.tracks ?? []
    } else {
      let playSession = try await Audiobookshelf.shared.sessions.start(
        itemID: bookID,
        forceTranscode: true,
        sessionType: .watch,
        timeout: 30
      )
      switch playSession.libraryItem {
      case .book(let b): book = b
      case .podcast: throw NSError(domain: "WatchConnectivity", code: -1)
      }
      sessionID = playSession.id
      audioTracks = playSession.audioTracks ?? []
    }

    let tracks: [[String: Any]] = audioTracks.map { audioTrack in
      let trackURL: String
      if forDownload, let ino = audioTrack.ino {
        let url = serverURL.appendingPathComponent("api/items/\(bookID)/file/\(ino)/download")
        trackURL = url.absoluteString
      } else if let sessionID = sessionID {
        let baseURLString = serverURL.absoluteString.trimmingCharacters(
          in: CharacterSet(charactersIn: "/")
        )
        trackURL =
          "\(baseURLString)/public/session/\(sessionID)/track/\(audioTrack.index)"
      } else {
        trackURL = ""
      }

      return [
        "index": audioTrack.index,
        "duration": audioTrack.duration,
        "size": audioTrack.metadata?.size ?? 0,
        "ext": audioTrack.metadata?.ext ?? "",
        "url": trackURL,
      ]
    }

    let chapters: [[String: Any]] =
      book.chapters?.enumerated().map { index, chapter in
        [
          "id": index,
          "title": chapter.title,
          "start": chapter.start,
          "end": chapter.end,
        ]
      } ?? []

    if let sessionID = sessionID {
      AppLogger.watchConnectivity.info(
        "Created session \(sessionID) for book \(bookID), forDownload=\(forDownload)"
      )
    } else {
      AppLogger.watchConnectivity.info(
        "Fetched book \(bookID) for download, forDownload=\(forDownload)"
      )
    }

    let coverURLString = watchCompatibleCoverURL(from: book.coverURL())

    return [
      "id": bookID,
      "sessionID": sessionID ?? "",
      "title": book.title,
      "authorName": book.authorName ?? "",
      "coverURL": coverURLString ?? "",
      "duration": book.duration,
      "tracks": tracks,
      "chapters": chapters,
    ]
  }

  private func handleFetchSectionBooks(
    sectionID: String,
    replyHandler: @escaping ([String: Any]) -> Void
  ) async {
    do {
      let personalized: Personalized
      if let cached = Audiobookshelf.shared.libraries.getCachedPersonalized() {
        personalized = cached
      } else {
        personalized = try await Audiobookshelf.shared.libraries.fetchPersonalized()
      }

      guard let section = personalized.sections.first(where: { $0.id == sectionID }),
        case .books(let books) = section.entities
      else {
        replyHandler(["error": "Section not found"])
        return
      }

      let bookDicts: [[String: Any]] = books.map { book in
        [
          "id": book.id,
          "title": book.title,
          "author": book.authorName as Any,
          "duration": book.duration,
        ]
      }

      replyHandler(["books": bookDicts])
    } catch {
      AppLogger.watchConnectivity.error("Failed to fetch section books: \(error)")
      replyHandler(["error": error.localizedDescription])
    }
  }

  private func applyWatchProgress(
    bookID: String,
    currentTime: TimeInterval,
    duration: TimeInterval,
    updatedAt: Date
  ) -> Bool {
    let safeDuration = max(duration, 1)
    let incoming = WatchProgressSnapshot(
      bookID: bookID,
      currentTime: currentTime,
      duration: safeDuration,
      updatedAt: updatedAt
    )

    if let existing = try? MediaProgress.fetch(bookID: bookID) {
      let local = WatchProgressSnapshot(
        bookID: bookID,
        currentTime: existing.currentTime,
        duration: existing.duration,
        updatedAt: existing.lastUpdate
      )
      guard WatchProgressReconciler.resolve(local: local, incoming: incoming) == incoming,
        incoming.updatedAt > local.updatedAt
      else { return false }

      existing.currentTime = incoming.currentTime
      existing.duration = incoming.duration
      existing.progress = min(1, max(0, incoming.currentTime / incoming.duration))
      existing.lastPlayedAt = incoming.updatedAt
      existing.lastUpdate = incoming.updatedAt
      existing.isFinished = existing.progress >= 1
      existing.finishedAt = existing.isFinished ? incoming.updatedAt : nil
      do {
        try existing.save()
        return true
      } catch {
        AppLogger.watchConnectivity.error("Failed to save Watch progress: \(error.localizedDescription)")
        return false
      }
    }

    do {
      try MediaProgress(
        bookID: bookID,
        lastPlayedAt: incoming.updatedAt,
        currentTime: incoming.currentTime,
        duration: incoming.duration,
        progress: min(1, max(0, incoming.currentTime / incoming.duration)),
        isFinished: incoming.currentTime >= incoming.duration,
        finishedAt: incoming.currentTime >= incoming.duration ? incoming.updatedAt : nil,
        lastUpdate: incoming.updatedAt
      ).save()
      return true
    } catch {
      AppLogger.watchConnectivity.error("Failed to save Watch progress: \(error.localizedDescription)")
      return false
    }
  }

  private func receiveLocalSessions(_ sessionsData: [[String: Any]]) async -> Bool {
    let sessionIDs = Set(sessionsData.compactMap { $0["id"] as? String })
    syncedLocalSessions = syncedLocalSessions.filter { sessionIDs.contains($0.key) }

    for dict in sessionsData {
      guard let id = dict["id"] as? String,
        let bookID = dict["bookID"] as? String,
        let duration = dict["duration"] as? Double,
        let currentTime = dict["currentTime"] as? Double,
        let updatedAt = dict["updatedAt"] as? Double,
        updatedAt > syncedLocalSessions[id, default: 0],
        updatedAt > (pendingLocalSessions[id]?["updatedAt"] as? Double ?? 0)
      else { continue }

      let watchUpdatedAt = Date(timeIntervalSince1970: updatedAt)
      _ = applyWatchProgress(
        bookID: bookID,
        currentTime: currentTime,
        duration: duration,
        updatedAt: watchUpdatedAt
      )

      pendingLocalSessions[id] = dict
    }

    if localSessionSyncTask == nil, !pendingLocalSessions.isEmpty {
      localSessionSyncTask = Task { await drainLocalSessions() }
    }

    return await localSessionSyncTask?.value ?? true
  }

  private func drainLocalSessions() async -> Bool {
    var attempts = 0
    while session?.hasContentPending == true, attempts < 10 {
      try? await Task.sleep(for: .seconds(1))
      attempts += 1
    }

    var succeeded = true
    while !pendingLocalSessions.isEmpty {
      let sessionsData = pendingLocalSessions.values.filter { dict in
        guard let id = dict["id"] as? String, let updatedAt = dict["updatedAt"] as? Double else { return false }
        return updatedAt > syncedLocalSessions[id, default: 0]
      }
      pendingLocalSessions.removeAll()

      let posted = await postLocalSessions(sessionsData)
      if !posted {
        succeeded = false
      }
    }

    localSessionSyncTask = nil
    context["syncedLocalSessions"] = syncedLocalSessions
    refreshProgress()
    return succeeded
  }

  private func postLocalSessions(_ sessionsData: [[String: Any]]) async -> Bool {
    var sessionSyncs: [SessionSync] = []
    var syncedUpdatedAt: [String: Double] = [:]

    for dict in sessionsData {
      guard let id = dict["id"] as? String,
        let bookID = dict["bookID"] as? String,
        let duration = dict["duration"] as? Double,
        let startTime = dict["startTime"] as? Double,
        let currentTime = dict["currentTime"] as? Double,
        let timeListening = dict["timeListening"] as? Double,
        let startedAt = dict["startedAt"] as? Double,
        let updatedAt = dict["updatedAt"] as? Double
      else { continue }

      sessionSyncs.append(
        SessionSync(
          id: id,
          libraryItemId: bookID,
          duration: duration,
          startTime: startTime,
          currentTime: currentTime,
          timeListening: timeListening,
          startedAt: Int(startedAt * 1000),
          updatedAt: Int(updatedAt * 1000),
          deviceInfo: SessionSync.DeviceInfo(
            deviceID: Self.watchDeviceID,
            clientName: "AudioBooth Watch"
          )
        )
      )
      syncedUpdatedAt[id] = updatedAt
    }

    guard !sessionSyncs.isEmpty else { return true }

    do {
      try await Audiobookshelf.shared.sessions.syncLocalSessions(sessionSyncs)
      syncedLocalSessions.merge(syncedUpdatedAt) { max($0, $1) }
      AppLogger.watchConnectivity.info("Synced \(sessionSyncs.count) watch local sessions")
      return true
    } catch {
      AppLogger.watchConnectivity.error("Failed to sync watch local sessions: \(error)")
      return false
    }
  }

  private func handleProgressReport(
    bookID: String,
    sessionID: String,
    currentTime: Double,
    timeListened: Double,
    duration: Double,
    updatedAt: Date
  ) {
    Task { @MainActor in
      let previous = progressSyncTasks[bookID]
      let task = Task { @MainActor in
        await previous?.value
        do {
          guard
            applyWatchProgress(
              bookID: bookID,
              currentTime: currentTime,
              duration: duration,
              updatedAt: updatedAt
            )
          else {
            AppLogger.watchConnectivity.debug("Ignored stale Watch progress for \(bookID)")
            return
          }

          try await Audiobookshelf.shared.sessions.sync(
            sessionID,
            timeListened: timeListened,
            currentTime: currentTime
          )
          AppLogger.watchConnectivity.debug("Synced watch progress: \(currentTime)s")
        } catch {
          AppLogger.watchConnectivity.error("Failed to sync watch progress: \(error)")
        }
      }
      progressSyncTasks[bookID] = task
    }
  }

  private func handlePlayCommand(bookID: String, currentTime: Double? = nil) {
    Task { @MainActor in
      do {
        if let book = try LocalBook.fetch(bookID: bookID) {
          PlayerManager.shared.setCurrent(book)
          if let currentTime, let player = PlayerManager.shared.current as? BookPlayerModel {
            player.seekToTime(currentTime)
          }
          PlayerManager.shared.current?.onPlayTapped()
          PlayerManager.shared.showFullPlayer()
        } else {
          AppLogger.watchConnectivity.info("Book not found locally, fetching from server...")
          let session = try await Audiobookshelf.shared.sessions.start(
            itemID: bookID,
            forceTranscode: false,
            timeout: 30
          )

          if case .book(let book) = session.libraryItem {
            PlayerManager.shared.setCurrent(book)
          }
          if let currentTime, let player = PlayerManager.shared.current as? BookPlayerModel {
            player.seekToTime(currentTime)
          }
          PlayerManager.shared.current?.onPlayTapped()
          PlayerManager.shared.showFullPlayer()
        }
      } catch {
        AppLogger.watchConnectivity.error(
          "Failed to handle play command: \(error)"
        )
      }
    }
  }
}
