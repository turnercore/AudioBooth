import Combine
import Foundation
import Models
import OSLog
import WatchConnectivity
import WatchKit
import WidgetKit

struct WatchHomeSection: Identifiable, Hashable {
  let id: String
  let name: String
  let count: Int
}

final class WatchConnectivityManager: NSObject, ObservableObject {
  static let shared = WatchConnectivityManager()

  @Published var continueListeningBooks: [WatchBook] = []
  @Published var phoneDownloadedBooks: [WatchPhoneLibraryBook] = []
  @Published var watchTransferJobs: [WatchTransferJob] = []
  @Published private(set) var watchTransferByteProgress: [String: WatchTransferByteProgress] = [:]
  @Published var progress: [String: Double] = [:]
  private(set) var progressUpdatedAt: [String: Double] = [:]
  @Published var hasCurrentBook: Bool = false
  @Published var playbackRate: Float = 1.0
  @Published var homeSections: [WatchHomeSection] = []
  private var chapterProgress: Double?

  var skipForwardInterval: Double {
    get {
      let value = UserDefaults.standard.double(forKey: Keys.skipForwardInterval)
      return value > 0 ? value : 30
    }
    set {
      UserDefaults.standard.set(newValue, forKey: Keys.skipForwardInterval)
    }
  }

  var skipBackwardInterval: Double {
    get {
      let value = UserDefaults.standard.double(forKey: Keys.skipBackwardInterval)
      return value > 0 ? value : 30
    }
    set {
      UserDefaults.standard.set(newValue, forKey: Keys.skipBackwardInterval)
    }
  }

  private var session: WCSession?
  private var cancellables = Set<AnyCancellable>()
  private var pendingWatchRelayBookID: String?
  private var watchRelayRequestInFlightBookID: String?
  @Published private(set) var durablyRequestedBookIDs: Set<String> = []

  private enum Keys {
    static let continueListeningBooks = "continue_listening_books"
    static let progress = "progress"
    static let progressUpdatedAt = "progress_updated_at"
    static let phoneDownloadedBooks = "phone_downloaded_books"
    static let watchTransferJobs = "watch_transfer_jobs"
    static let pendingWatchRelayBookID = "pending_watch_relay_book_id"
    static let durablyRequestedBookIDs = "durably_requested_watch_relay_book_ids"
    static let skipForwardInterval = "skip_forward_interval"
    static let skipBackwardInterval = "skip_backward_interval"
  }

  var isReachable: Bool {
    session?.isReachable ?? false
  }

  private override init() {
    super.init()

    loadPersistedState()
    setupObservers()

    if WCSession.isSupported() {
      session = WCSession.default
      session?.delegate = self
      session?.activate()
    }

    NotificationCenter.default.addObserver(
      forName: WKExtension.applicationDidBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in
        WatchConnectivityManager.shared.resumeWatchRelay()
      }
    }

    Task { @MainActor in
      WatchConnectivityManager.shared.resumeWatchRelay()
    }
  }

  @MainActor
  private func resumeWatchRelay() {
    watchRelayRequestInFlightBookID = nil
    WatchFileTransferReceiver.resumeRelayTransfers()
    sendWatchRelayRequestIfPossible()
  }

  private func setupObservers() {
    LocalBookStorage.shared.$books
      .dropFirst()
      .map { books in books.filter { $0.isDownloaded }.map { $0.id } }
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] downloadedBookIDs in
        self?.sendDownloadedBookIDs(downloadedBookIDs)
      }
      .store(in: &cancellables)
  }

  private func loadPersistedState() {
    UserDefaults.standard.removeObject(forKey: "custom_headers")

    if let data = UserDefaults.standard.data(forKey: Keys.continueListeningBooks),
      let books = try? JSONDecoder().decode([WatchBook].self, from: data)
    {
      continueListeningBooks = books
      AppLogger.watchConnectivity.info("Loaded \(books.count) persisted books")
    }

    if let data = UserDefaults.standard.data(forKey: Keys.phoneDownloadedBooks),
      let books = try? JSONDecoder().decode([WatchPhoneLibraryBook].self, from: data)
    {
      phoneDownloadedBooks = books
    }

    if let data = UserDefaults.standard.data(forKey: Keys.watchTransferJobs),
      let jobs = try? JSONDecoder().decode([WatchTransferJob].self, from: data)
    {
      watchTransferJobs = jobs
    }

    pendingWatchRelayBookID = UserDefaults.standard.string(forKey: Keys.pendingWatchRelayBookID)
    durablyRequestedBookIDs = Set(
      UserDefaults.standard.stringArray(forKey: Keys.durablyRequestedBookIDs) ?? []
    )

    if let progressData = UserDefaults.standard.dictionary(forKey: Keys.progress)
      as? [String: Double]
    {
      progress = progressData
    }

    if let updatedAtData = UserDefaults.standard.dictionary(forKey: Keys.progressUpdatedAt)
      as? [String: Double]
    {
      progressUpdatedAt = updatedAtData
    }
  }

  private func persistBooks(_ books: [WatchBook]) {
    guard let data = try? JSONEncoder().encode(books) else { return }
    UserDefaults.standard.set(data, forKey: Keys.continueListeningBooks)
    persistProgress()
  }

  private func persistProgress() {
    UserDefaults.standard.set(progress, forKey: Keys.progress)
    UserDefaults.standard.set(progressUpdatedAt, forKey: Keys.progressUpdatedAt)
  }

  func requestPhoneDownloads() {
    sendTransferCommand(["command": "requestPhoneDownloads"])
  }

  func requestWatchTransfer(bookID: String) {
    // Official transport: a durable, reply-free request the phone answers by
    // queueing WCSession.transferFile chunks. The foreground relay is never
    // started implicitly from this button.
    durablyRequestedBookIDs.insert(bookID)
    persistDurablyRequestedBookIDs()
    guard let session else { return }
    session.transferUserInfo(["command": "requestWatchTransfer", "bookID": bookID])
  }

  func cancelWatchTransfer(bookID: String) {
    if pendingWatchRelayBookID == bookID {
      pendingWatchRelayBookID = nil
      watchRelayRequestInFlightBookID = nil
      UserDefaults.standard.removeObject(forKey: Keys.pendingWatchRelayBookID)
    }
    durablyRequestedBookIDs.remove(bookID)
    persistDurablyRequestedBookIDs()
    WatchShareDownloadCoordinator.shared.cancel(bookID: bookID)
    WatchFileTransferReceiver.cancelRelay(bookID: bookID)
    sendTransferCommand(["command": "cancelWatchTransfer", "bookID": bookID])
  }

  @MainActor
  func publishWatchTransferProgress(
    transferID: String,
    progress: WatchTransferByteProgress
  ) {
    watchTransferByteProgress[transferID] = progress
  }

  @MainActor
  func clearWatchTransferProgress(transferID: String) {
    watchTransferByteProgress.removeValue(forKey: transferID)
  }

  @discardableResult
  func sendWatchRelayChunkRequest(
    _ request: WatchTransferChunkRequest,
    replyHandler: @escaping (Data) -> Void,
    errorHandler: @escaping (Error) -> Void
  ) -> Bool {
    guard let session, session.isReachable else { return false }

    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    guard let data = try? encoder.encode(request) else {
      AppLogger.watchConnectivity.error("Failed to encode Watch relay chunk request")
      return false
    }

    session.sendMessageData(
      data,
      replyHandler: replyHandler,
      errorHandler: errorHandler
    )
    return true
  }

  private func sendWatchRelayRequestIfPossible() {
    guard let bookID = pendingWatchRelayBookID,
      watchRelayRequestInFlightBookID == nil,
      let session,
      session.isReachable
    else { return }

    watchRelayRequestInFlightBookID = bookID
    session.sendMessage(
      ["command": "requestWatchRelay", "bookID": bookID],
      replyHandler: { [weak self] response in
        let shareOfferData = response["shareOffer"] as? Data
        let manifestData =
          response["manifest"] as? Data
          ?? response["manifestData"] as? Data

        Task { @MainActor in
          guard let self, self.watchRelayRequestInFlightBookID == bookID else { return }
          self.watchRelayRequestInFlightBookID = nil
          guard self.pendingWatchRelayBookID == bookID else {
            self.sendWatchRelayRequestIfPossible()
            return
          }

          if let shareOfferData,
            let offer = try? PropertyListDecoder().decode(WatchShareOffer.self, from: shareOfferData),
            offer.bookID == bookID
          {
            self.clearPendingRequest(bookID: bookID)
            WatchShareDownloadCoordinator.shared.receive(offer)
            return
          }

          guard let manifestData else {
            AppLogger.watchConnectivity.error(
              "Watch transfer reply contained neither a share offer nor a relay manifest"
            )
            return
          }
          self.clearPendingRequest(bookID: bookID)
          WatchFileTransferReceiver.receiveRelayManifest(
            manifestData,
            expectedBookID: bookID
          )
        }
      },
      errorHandler: { [weak self] error in
        AppLogger.watchConnectivity.error("Failed to request Watch relay: \(error)")
        Task { @MainActor in
          guard let self, self.watchRelayRequestInFlightBookID == bookID else { return }
          self.watchRelayRequestInFlightBookID = nil
          self.pendingWatchRelayBookID = bookID
          UserDefaults.standard.set(bookID, forKey: Keys.pendingWatchRelayBookID)
          self.enqueueDurableWatchTransferRequestOnce(bookID: bookID)
        }
      }
    )
  }

  private func enqueueDurableWatchTransferRequestOnce(bookID: String) {
    guard let session, durablyRequestedBookIDs.insert(bookID).inserted else { return }
    persistDurablyRequestedBookIDs()
    session.transferUserInfo(["command": "requestWatchTransfer", "bookID": bookID])
  }

  private func clearPendingRequest(bookID: String) {
    if pendingWatchRelayBookID == bookID {
      pendingWatchRelayBookID = nil
      UserDefaults.standard.removeObject(forKey: Keys.pendingWatchRelayBookID)
    }
    durablyRequestedBookIDs.remove(bookID)
    persistDurablyRequestedBookIDs()
  }

  private func persistDurablyRequestedBookIDs() {
    UserDefaults.standard.set(durablyRequestedBookIDs.sorted(), forKey: Keys.durablyRequestedBookIDs)
  }

  func sendWatchTransferCompletion(transferID: String) {
    sendTransferCommand(["command": "watchTransferCompleted", "transferID": transferID])
  }

  func sendWatchShareStatus(
    command: String,
    transferID: String,
    bookID: String,
    shareID: String,
    replacementGeneration: Int
  ) {
    sendTransferCommand([
      "command": command,
      "transferID": transferID,
      "bookID": bookID,
      "shareID": shareID,
      "replacementGeneration": replacementGeneration,
    ])
  }

  private func sendTransferCommand(_ message: [String: Any]) {
    guard let session else { return }
    if session.isReachable {
      session.sendMessage(message, replyHandler: nil) { error in
        AppLogger.watchConnectivity.error("Failed to send Watch transfer command: \(error)")
      }
    } else {
      session.transferUserInfo(message)
    }
  }

  @discardableResult
  func recordLocalProgress(bookID: String, currentTime: Double) -> Date {
    let updatedAt = Date()
    progress[bookID] = currentTime
    progressUpdatedAt[bookID] = updatedAt.timeIntervalSince1970
    persistProgress()
    return updatedAt
  }

  func changePlaybackRate(_ rate: Float) {
    guard let session = session, session.isReachable else {
      AppLogger.watchConnectivity.warning("Cannot change playback rate - session not reachable")
      return
    }

    let message: [String: Any] = [
      "command": "changePlaybackRate",
      "rate": rate,
    ]
    session.sendMessage(message, replyHandler: nil) { error in
      AppLogger.watchConnectivity.error("Failed to send playback rate command to iOS: \(error)")
    }
  }

  func refreshContinueListening() async {
    guard let session = session, session.isReachable else {
      AppLogger.watchConnectivity.warning("Cannot refresh - session not reachable")
      return
    }

    await withCheckedContinuation { continuation in
      let message: [String: Any] = ["command": "refreshContinueListening"]
      session.sendMessage(
        message,
        replyHandler: { _ in
          continuation.resume()
        }
      ) { error in
        AppLogger.watchConnectivity.error("Failed to refresh continue listening: \(error)")
        continuation.resume()
      }
    }
  }

  func fetchSectionBooks(sectionID: String) async -> [WatchBook]? {
    guard let session = session, session.isReachable else {
      AppLogger.watchConnectivity.warning("Cannot fetch section - session not reachable")
      return nil
    }

    return await withCheckedContinuation { continuation in
      let message: [String: Any] = [
        "command": "fetchSectionBooks",
        "sectionID": sectionID,
      ]
      session.sendMessage(
        message,
        replyHandler: { response in
          if let error = response["error"] as? String {
            AppLogger.watchConnectivity.error("Failed to fetch section books: \(error)")
            continuation.resume(returning: nil)
            return
          }
          guard let booksData = response["books"] as? [[String: Any]] else {
            continuation.resume(returning: nil)
            return
          }
          let books = booksData.compactMap { WatchBook(dictionary: $0) }
          continuation.resume(returning: books)
        },
        errorHandler: { error in
          AppLogger.watchConnectivity.error("fetchSectionBooks error: \(error)")
          continuation.resume(returning: nil)
        }
      )
    }
  }

  func sendDownloadedBookIDs(_ ids: [String]) {
    guard let session = session, session.isReachable else {
      AppLogger.watchConnectivity.warning("Cannot send downloaded book IDs - session not reachable")
      return
    }

    let message: [String: Any] = [
      "command": "syncDownloadedBooks",
      "bookIDs": ids,
    ]
    session.sendMessage(message, replyHandler: nil) { error in
      AppLogger.watchConnectivity.error("Failed to send downloaded book IDs to iOS: \(error)")
    }

    AppLogger.watchConnectivity.info("Sent \(ids.count) downloaded book IDs to iPhone")
  }

  func reportProgress(bookID: String, sessionID: String?, currentTime: Double, timeListened: Double, duration: Double) {
    let updatedAt = recordLocalProgress(bookID: bookID, currentTime: currentTime)

    guard let session, session.isReachable, let sessionID, !sessionID.isEmpty else {
      WatchLocalSessionStore.shared.record(
        bookID: bookID,
        currentTime: currentTime,
        timeListened: timeListened,
        duration: duration
      )
      return
    }

    let message: [String: Any] = [
      "command": "reportProgress",
      "bookID": bookID,
      "sessionID": sessionID,
      "currentTime": currentTime,
      "timeListened": timeListened,
      "duration": duration,
      "updatedAt": updatedAt.timeIntervalSince1970,
    ]

    session.sendMessage(message, replyHandler: nil) { _ in
      Task { @MainActor in
        WatchLocalSessionStore.shared.record(
          bookID: bookID,
          currentTime: currentTime,
          timeListened: timeListened,
          duration: duration
        )
      }
    }
  }

  func flushLocalSessions() {
    guard let session, session.isReachable else { return }

    let localSessions = WatchLocalSessionStore.shared.sessions
    guard !localSessions.isEmpty else { return }

    let payload: [[String: Any]] = localSessions.map { localSession in
      [
        "id": localSession.id,
        "bookID": localSession.bookID,
        "duration": localSession.duration,
        "startTime": localSession.startTime,
        "currentTime": localSession.currentTime,
        "timeListening": localSession.timeListening,
        "startedAt": localSession.startedAt.timeIntervalSince1970,
        "updatedAt": localSession.updatedAt.timeIntervalSince1970,
      ]
    }

    let message: [String: Any] = [
      "command": "syncLocalSessions",
      "sessions": payload,
    ]

    AppLogger.watchConnectivity.info("Flushing \(localSessions.count) local sessions to iPhone")

    session.sendMessage(
      message,
      replyHandler: { response in
        if let error = response["error"] as? String {
          AppLogger.watchConnectivity.error("Failed to sync local sessions: \(error)")
          return
        }
        Task { @MainActor in
          WatchLocalSessionStore.shared.remove(ids: localSessions.map(\.id))
        }
      },
      errorHandler: { error in
        AppLogger.watchConnectivity.error("Failed to send local sessions: \(error)")
      }
    )
  }

  func startSession(bookID: String, forDownload: Bool = false) async -> WatchBook? {
    await withCheckedContinuation { continuation in
      startSessionWithCallback(bookID: bookID, forDownload: forDownload) { book in
        continuation.resume(returning: book)
      }
    }
  }

  private func startSessionWithCallback(
    bookID: String,
    forDownload: Bool,
    completion: @escaping (WatchBook?) -> Void
  ) {
    AppLogger.watchConnectivity.info(
      "startSession called for \(bookID), forDownload=\(forDownload)"
    )

    guard let session = session else {
      AppLogger.watchConnectivity.error("Cannot start session - no WCSession instance")
      completion(nil)
      return
    }

    AppLogger.watchConnectivity.info(
      "Session state - isReachable: \(session.isReachable), activationState: \(session.activationState.rawValue)"
    )

    guard session.isReachable else {
      AppLogger.watchConnectivity.error("Cannot start session - session not reachable")
      completion(nil)
      return
    }

    AppLogger.watchConnectivity.info("Sending startSession message to iOS...")

    let message: [String: Any] = [
      "command": "startSession",
      "bookID": bookID,
      "forDownload": forDownload,
    ]

    session.sendMessage(
      message,
      replyHandler: { response in
        AppLogger.watchConnectivity.info("Received reply from iOS")

        guard let id = response["id"] as? String,
          let title = response["title"] as? String,
          let duration = response["duration"] as? Double,
          let tracksData = response["tracks"] as? [[String: Any]],
          let chaptersData = response["chapters"] as? [[String: Any]]
        else {
          if let error = response["error"] as? String {
            AppLogger.watchConnectivity.error("Failed to start session: \(error)")
          }
          completion(nil)
          return
        }

        let tracks = tracksData.compactMap { dict -> WatchTrack? in
          guard let index = dict["index"] as? Int,
            let trackDuration = dict["duration"] as? Double
          else { return nil }
          let url = (dict["url"] as? String).flatMap { URL(string: $0) }
          return WatchTrack(
            index: index,
            duration: trackDuration,
            size: dict["size"] as? Int64,
            ext: dict["ext"] as? String,
            url: url,
            relativePath: nil
          )
        }

        let chapters = chaptersData.compactMap { dict -> WatchChapter? in
          guard let chapterID = dict["id"] as? Int,
            let chapterTitle = dict["title"] as? String,
            let start = dict["start"] as? Double,
            let end = dict["end"] as? Double
          else { return nil }
          return WatchChapter(id: chapterID, title: chapterTitle, start: start, end: end)
        }

        let coverURL = (response["coverURL"] as? String).flatMap { URL(string: $0) }
        let sessionID = response["sessionID"] as? String

        let book = WatchBook(
          id: id,
          sessionID: sessionID,
          title: title,
          authorName: response["authorName"] as? String,
          coverURL: coverURL,
          duration: duration,
          chapters: chapters,
          tracks: tracks,
          currentTime: self.progress[id, default: 0]
        )

        AppLogger.watchConnectivity.info("Started session for \(id)")
        completion(book)
      },
      errorHandler: { error in
        AppLogger.watchConnectivity.error("sendMessage error: \(error.localizedDescription)")
        completion(nil)
      }
    )
  }
}

extension WatchConnectivityManager: WCSessionDelegate {
  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if let error {
      AppLogger.watchConnectivity.error("Watch session activation failed: \(error)")
    } else {
      AppLogger.watchConnectivity.info(
        "Watch session activated with state: \(activationState.rawValue)"
      )

      if activationState == .activated {
        let context = session.receivedApplicationContext
        Task { @MainActor in
          handleContext(context)
          resumeWatchRelay()
        }

        if session.isReachable {
          let downloadedBookIDs = LocalBookStorage.shared.books
            .filter { $0.isDownloaded }
            .map { $0.id }
          sendDownloadedBookIDs(downloadedBookIDs)
          flushLocalSessions()
        }
      }
    }
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in
      guard session.isReachable else {
        WatchFileTransferReceiver.pauseRelayTransfers()
        return
      }
      flushLocalSessions()
      resumeWatchRelay()
    }
  }

  func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    Task { @MainActor in
      handleContext(applicationContext)
    }
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    Task { @MainActor in
      handleMessage(message)
    }
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
    Task { @MainActor in
      handleMessage(userInfo)
    }
  }

  func session(_ session: WCSession, didReceive file: WCSessionFile) {
    WatchFileTransferReceiver.receive(file)
  }

  private func handleContext(_ context: [String: Any]) {
    hasCurrentBook = context["hasCurrentBook"] as? Bool ?? false
    playbackRate = context["playbackRate"] as? Float ?? 1.0
    chapterProgress = context["chapterProgress"] as? Double

    let continueListeningData = context["continueListening"] as? [[String: Any]] ?? []
    handleContinueListening(continueListeningData)

    if let data = context["phoneDownloadedBooks"] as? Data,
      let books = try? JSONDecoder().decode([WatchPhoneLibraryBook].self, from: data)
    {
      phoneDownloadedBooks = books
      UserDefaults.standard.set(data, forKey: Keys.phoneDownloadedBooks)
    }

    if let data = context["watchTransferJobs"] as? Data,
      let jobs = try? JSONDecoder().decode([WatchTransferJob].self, from: data)
    {
      watchTransferJobs = jobs
      UserDefaults.standard.set(data, forKey: Keys.watchTransferJobs)
      for job in jobs where durablyRequestedBookIDs.contains(job.bookID) {
        durablyRequestedBookIDs.remove(job.bookID)
      }
      persistDurablyRequestedBookIDs()
    }

    let progressData = context["progress"] as? [String: Double] ?? [:]
    let updatedAtData = context["progressUpdatedAt"] as? [String: Double] ?? [:]
    handleProgress(progressData, updatedAt: updatedAtData)

    let homeSectionsData = context["homeSections"] as? [[String: Any]] ?? []
    homeSections = homeSectionsData.compactMap { dict in
      guard let id = dict["id"] as? String,
        let name = dict["name"] as? String,
        let count = dict["count"] as? Int
      else { return nil }
      return WatchHomeSection(id: id, name: name, count: count)
    }

    if let forward = context["skipForwardInterval"] as? Double {
      skipForwardInterval = forward
    }

    if let backward = context["skipBackwardInterval"] as? Double {
      skipBackwardInterval = backward
    }

    receiveWatchShareOffer(from: context)
  }

  private func handleMessage(_ message: [String: Any]) {
    if let progressData = message["progress"] as? [String: Double] {
      handleProgress(progressData)
    }
    receiveWatchShareOffer(from: message)
    receiveWatchRelayFallback(from: message)
  }

  private func receiveWatchShareOffer(from payload: [String: Any]) {
    let data =
      payload["watchShareOffer"] as? Data
      ?? payload["shareOffer"] as? Data
      ?? payload["offer"] as? Data
    guard let data else { return }

    let offer =
      (try? JSONDecoder().decode(WatchShareOffer.self, from: data))
      ?? (try? PropertyListDecoder().decode(WatchShareOffer.self, from: data))
    guard let offer else {
      AppLogger.watchConnectivity.error("Rejected undecodable Watch share offer")
      return
    }
    clearPendingRequest(bookID: offer.bookID)
    WatchShareDownloadCoordinator.shared.receive(offer)
  }

  private func receiveWatchRelayFallback(from payload: [String: Any]) {
    guard let data = payload["watchRelayManifest"] as? Data,
      let transferID = payload["transferID"] as? String,
      let bookID = payload["bookID"] as? String,
      WatchShareDownloadCoordinator.shared.acceptsRelayFallback(
        transferID: transferID,
        bookID: bookID
      ),
      let manifest = try? PropertyListDecoder().decode(WatchTransferManifest.self, from: data),
      manifest.transferID == transferID,
      manifest.bookID == bookID
    else { return }

    clearPendingRequest(bookID: bookID)
    WatchFileTransferReceiver.receiveRelayManifest(data, expectedBookID: bookID)
  }

  private func handleContinueListening(_ data: [[String: Any]]) {
    let books = data.compactMap { dict -> WatchBook? in
      let currentTime = progress[dict["id"] as? String ?? ""] ?? 0
      return WatchBook(dictionary: dict, currentTime: currentTime)
    }

    continueListeningBooks = books
    persistBooks(books)
    updateComplication()
  }

  private func handleProgress(_ data: [String: Double], updatedAt: [String: Double] = [:]) {
    var updatedBooks = continueListeningBooks

    for (bookID, currentTime) in data {
      if let remoteUpdatedAt = updatedAt[bookID] {
        let localUpdatedAt = progressUpdatedAt[bookID] ?? 0
        guard remoteUpdatedAt > localUpdatedAt else { continue }
        progressUpdatedAt[bookID] = remoteUpdatedAt
      } else {
        let localTime = progress[bookID] ?? 0
        guard currentTime > localTime else { continue }
      }

      progress[bookID] = currentTime

      if let index = updatedBooks.firstIndex(where: { $0.id == bookID }) {
        updatedBooks[index].currentTime = currentTime
      }

      LocalBookStorage.shared.updateProgress(for: bookID, currentTime: currentTime)
    }

    continueListeningBooks = updatedBooks
    persistBooks(continueListeningBooks)
    updateComplication()
  }

  func updateComplication() {
    if WatchComplicationStorage.load()?.isPlaying == true {
      return
    }

    if let book = continueListeningBooks.first {
      let state = WatchComplicationState(
        bookTitle: book.title,
        progress: book.progress,
        chapterProgress: chapterProgress,
        currentTime: book.currentTime,
        duration: book.duration,
        isPlaying: false
      )
      WatchComplicationStorage.save(state)
    } else {
      WatchComplicationStorage.clear()
    }
    WidgetCenter.shared.reloadAllTimelines()
  }

}
