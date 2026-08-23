import CryptoKit
import Foundation
import Models
import OSLog
import WatchKit

/// Owns the credential-free public-share path. The existing eight-request phone relay remains separate.
@MainActor
final class WatchShareDownloadCoordinator: NSObject {
  static let shared = WatchShareDownloadCoordinator()
  static let backgroundSessionIdentifier = "me.jgrenier.AudioBS.watch.share-downloads"

  /// Segmented ranged downloads keep units small enough for watchOS to run them
  /// while the display sleeps, and make incremental progress observable.
  fileprivate static let maxInFlightSegmentTasks = 3

  private struct Job: Codable {
    var lifecycle: WatchShareLifecycle
    var manifest: WatchTransferManifest?
    var coverDownloaded = false
    var failureDescription: String?
  }

  nonisolated private struct TaskIdentity: Codable, Hashable {
    enum Kind: String, Codable, Hashable { case track, cover }

    let transferID: String
    let replacementGeneration: Int
    let kind: Kind
    let trackIndex: Int?
    let fileExtension: String?
    var segmentIndex: Int?
    var rangeStart: Int64?
    var rangeLength: Int64?

    var isSegment: Bool { segmentIndex != nil }
  }

  private struct BootstrapResponse: Decodable {
    struct PlaybackSession: Decodable {
      struct AudioTrack: Decodable {
        struct Metadata: Decodable {
          let ext: String?
          let size: Int64?
          let filename: String?
        }

        let index: Int
        let duration: TimeInterval?
        let contentUrl: String?
        let contentURL: String?
        let mimeType: String?
        let metadata: Metadata?

        var remotePath: String? { contentUrl ?? contentURL }
      }

      let audioTracks: [AudioTrack]
    }

    struct MediaItem: Decodable {
      struct Media: Decodable {
        struct Metadata: Decodable {
          let title: String?
          let authorName: String?
        }

        let metadata: Metadata?
        let duration: TimeInterval?
      }

      let media: Media?
    }

    let playbackSession: PlaybackSession
    let mediaItem: MediaItem?
  }

  private enum CoordinatorError: LocalizedError {
    case invalidOffer
    case invalidBootstrapResponse
    case invalidTrackResponse
    case integrityMismatch

    var errorDescription: String? {
      switch self {
      case .invalidOffer: return "The temporary Watch share is invalid."
      case .invalidBootstrapResponse: return "The server returned an invalid Watch share."
      case .invalidTrackResponse: return "The server returned an invalid audio track."
      case .integrityMismatch: return "A downloaded audio track failed validation."
      }
    }
  }

  private enum Keys {
    static let jobs = "watch_share_download_jobs_v1"
    static let queue = "watch_share_download_queue_v1"
    static let activeTransferID = "watch_share_active_transfer_id_v1"
  }

  private let fileManager = FileManager.default
  private let logger = Logger(
    subsystem: "me.jgrenier.AudioBS.watchkitapp",
    category: "share-download"
  )
  private var jobs: [String: Job] = [:]
  private var queuedTransferIDs: [String] = []
  private var activeTransferID: String?
  private var bootstrapTasks: [String: Task<Void, Never>] = [:]
  private var reservedTaskIdentities: Set<TaskIdentity> = []
  private var taskProgress: [TaskIdentity: Int64] = [:]
  private var backgroundTaskCompletions: [() -> Void] = []

  /// Transient radio/suspension interruptions are routine; they must heal
  /// instead of killing the transfer. Only repeated hard failures terminate.
  private var transientFailureCounts: [String: Int] = [:]
  private static let maximumTransientFailures = 15
  private var watchdogTimer: Timer?

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.background(
      withIdentifier: Self.backgroundSessionIdentifier
    )
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.waitsForConnectivity = true
    configuration.allowsCellularAccess = true
    configuration.allowsExpensiveNetworkAccess = true
    configuration.allowsConstrainedNetworkAccess = true
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
    configuration.httpShouldSetCookies = true
    configuration.httpCookieStorage = .shared

    let delegateQueue = OperationQueue()
    delegateQueue.name = "me.jgrenier.AudioBS.watch.share-download-delegate"
    delegateQueue.maxConcurrentOperationCount = 1
    return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
  }()

  private override init() {
    super.init()
    loadJobs()
    queuedTransferIDs = UserDefaults.standard.stringArray(forKey: Keys.queue) ?? jobs.keys.sorted()
    activeTransferID = UserDefaults.standard.string(forKey: Keys.activeTransferID)
  }

  func resumePersistedTransfers() {
    _ = session
    startWatchdogIfNeeded()
    session.getAllTasks { tasks in
      Task { @MainActor [weak self] in
        guard let self else { return }
        reservedTaskIdentities = Set(
          tasks.compactMap { Self.taskIdentity(from: $0.taskDescription) }
        )
        startNextTransferIfPossible()
      }
    }
  }

  func receive(_ offer: WatchShareOffer) {
    guard offer.validationError() == nil,
      Self.isSafeIdentifier(offer.transferID),
      Self.isSafeIdentifier(offer.bookID),
      offer.tracks.allSatisfy({ Self.isSafeFileExtension(normalizedExtension($0.fileExtension)) })
    else {
      logger.error("Rejected invalid Watch share offer")
      return
    }

    if var existing = jobs[offer.transferID] {
      if existing.lifecycle.state == .completed {
        sendCompletion(for: existing)
        return
      }
      if existing.lifecycle.activeOffer == offer {
        startNextTransferIfPossible()
        return
      }

      guard offer.replacementGeneration == existing.lifecycle.replacementGeneration + 1 else {
        logger.error("Rejected out-of-order Watch share replacement")
        return
      }
      cancelTasks(transferID: offer.transferID)
      existing.lifecycle.fail()
      guard existing.lifecycle.replace(with: offer) else {
        logger.error("Rejected incompatible Watch share replacement")
        return
      }
      existing.failureDescription = nil
      existing.manifest = existing.manifest.map { reusableManifest in
        WatchTransferManifest(
          transferID: reusableManifest.transferID,
          bookID: reusableManifest.bookID,
          title: reusableManifest.title,
          authorName: reusableManifest.authorName,
          duration: reusableManifest.duration,
          currentTime: reusableManifest.currentTime,
          tracks: reusableManifest.tracks.filter { track in
            offer.tracks.contains { descriptor in
              descriptor.index == track.index
                && descriptor.byteCount == track.byteCount
                && normalizedExtension(descriptor.fileExtension) == track.fileExtension
            }
          }
        )
      }
      jobs[offer.transferID] = existing
    } else {
      // Only one transfer for a book may install at a time.
      for (transferID, job) in jobs
      where job.lifecycle.bookID == offer.bookID && transferID != offer.transferID
        && !job.lifecycle.state.isTerminal
      {
        cancel(transferID: transferID, notifyPhone: true)
      }
      jobs[offer.transferID] = Job(lifecycle: WatchShareLifecycle(offer: offer))
      if !queuedTransferIDs.contains(offer.transferID) {
        queuedTransferIDs.append(offer.transferID)
      }
    }

    saveJobs()
    startWatchdogIfNeeded()
    startNextTransferIfPossible()
  }

  func cancel(bookID: String) {
    for (transferID, job) in jobs where job.lifecycle.bookID == bookID {
      cancel(transferID: transferID, notifyPhone: true)
    }
  }

  func acceptsRelayFallback(transferID: String, bookID: String) -> Bool {
    guard let job = jobs[transferID] else { return false }
    return job.lifecycle.bookID == bookID && job.lifecycle.state == .failed
  }

  func reconnectBackgroundSession(
    withIdentifier identifier: String,
    completion: @escaping () -> Void
  ) {
    guard identifier == Self.backgroundSessionIdentifier else {
      completion()
      return
    }
    backgroundTaskCompletions.append(completion)
    _ = session
    resumePersistedTransfers()
  }

  private func startNextTransferIfPossible() {
    if let activeTransferID,
      let active = jobs[activeTransferID],
      active.lifecycle.state != .completed,
      active.lifecycle.state != .cancelled,
      active.lifecycle.state != .failed
    {
      resume(transferID: activeTransferID)
      return
    }

    activeTransferID = queuedTransferIDs.first { transferID in
      guard let job = jobs[transferID] else { return false }
      return !job.lifecycle.state.isTerminal
    }
    saveQueueState()
    if let activeTransferID { resume(transferID: activeTransferID) }
  }

  private func finishActiveTransfer(_ transferID: String) {
    queuedTransferIDs.removeAll { $0 == transferID }
    if activeTransferID == transferID { activeTransferID = nil }
    saveQueueState()
    startNextTransferIfPossible()
  }

  private func resume(transferID: String) {
    guard activeTransferID == transferID,
      var job = jobs[transferID], !job.lifecycle.state.isTerminal
    else { return }
    guard let offer = job.lifecycle.activeOffer else { return }

    if offer.isExpired {
      _ = job.lifecycle.markExpired()
      jobs[transferID] = job
      saveJobs()
      cancelTasks(transferID: transferID)
      requestReplacement(for: job)
      return
    }

    if let manifest = job.manifest {
      validateExistingTracks(for: &job, manifest: manifest)
      jobs[transferID] = job
      saveJobs()
      if job.lifecycle.isComplete {
        finishIfReady(transferID: transferID)
      } else {
        scheduleDownloads(for: transferID)
      }
      return
    }

    bootstrap(transferID: transferID)
  }

  private func bootstrap(transferID: String) {
    guard bootstrapTasks[transferID] == nil, var job = jobs[transferID],
      let offer = job.lifecycle.activeOffer
    else { return }
    if job.lifecycle.state == .offered {
      guard job.lifecycle.beginBootstrap() else { return }
      jobs[transferID] = job
      saveJobs()
    }

    bootstrapTasks[transferID] = Task { [weak self] in
      guard let self else { return }
      defer { bootstrapTasks[transferID] = nil }
      do {
        // A default, credential-free session lets Foundation persist the HttpOnly share cookie.
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = .shared
        let bootstrapSession = URLSession(configuration: configuration)
        defer { bootstrapSession.finishTasksAndInvalidate() }
        let (data, response) = try await bootstrapSession.data(from: offer.publicBootstrapURL)
        guard let response = response as? HTTPURLResponse else {
          throw CoordinatorError.invalidBootstrapResponse
        }
        if response.statusCode == 404 || response.statusCode == 410 {
          expireAndRequestReplacement(transferID: transferID)
          return
        }
        guard (200...299).contains(response.statusCode) else {
          throw CoordinatorError.invalidBootstrapResponse
        }

        let decoded = try JSONDecoder().decode(BootstrapResponse.self, from: data)
        let manifest = try makeManifest(from: decoded, offer: offer)
        guard var current = jobs[transferID], current.lifecycle.activeOffer == offer,
          current.lifecycle.beginDownload()
        else { return }
        current.manifest = manifest
        current.failureDescription = nil
        jobs[transferID] = current
        saveJobs()
        scheduleDownloads(for: transferID)
      } catch is CancellationError {
        return
      } catch {
        fail(transferID: transferID, error: error)
      }
    }
  }

  private func makeManifest(
    from response: BootstrapResponse,
    offer: WatchShareOffer
  ) throws -> WatchTransferManifest {
    let remoteByIndex = Dictionary(
      uniqueKeysWithValues: response.playbackSession.audioTracks.map { ($0.index, $0) }
    )
    guard remoteByIndex.count == response.playbackSession.audioTracks.count,
      Set(remoteByIndex.keys) == Set(offer.expectedTrackIndexes)
    else { throw CoordinatorError.invalidBootstrapResponse }

    let tracks = try offer.tracks.map { expected -> WatchTransferManifest.Track in
      guard let remote = remoteByIndex[expected.index],
        let remoteSize = remote.metadata?.size,
        remoteSize == expected.byteCount,
        let remotePath = remote.remotePath,
        validTrackPath(remotePath, offer: offer, index: expected.index)
      else { throw CoordinatorError.invalidBootstrapResponse }

      let expectedExtension = normalizedExtension(expected.fileExtension)
      if let remoteExtension = remote.metadata?.ext, !remoteExtension.isEmpty,
        normalizedExtension(remoteExtension).lowercased() != expectedExtension.lowercased()
      {
        throw CoordinatorError.invalidBootstrapResponse
      }
      return WatchTransferManifest.Track(
        index: expected.index,
        duration: remote.duration ?? 0,
        byteCount: expected.byteCount,
        fileExtension: expectedExtension
      )
    }

    let metadata = response.mediaItem?.media
    return WatchTransferManifest(
      transferID: offer.transferID,
      bookID: offer.bookID,
      title: metadata?.metadata?.title ?? offer.bookID,
      authorName: metadata?.metadata?.authorName,
      duration: metadata?.duration ?? tracks.reduce(0) { $0 + $1.duration },
      tracks: tracks
    )
  }

  private func scheduleDownloads(for transferID: String) {
    guard let job = jobs[transferID], let offer = job.lifecycle.activeOffer,
      let manifest = job.manifest, !offer.isExpired
    else { return }

    session.getAllTasks { tasks in
      Task { @MainActor [weak self] in
        guard let self, activeTransferID == transferID,
          let current = jobs[transferID], !current.lifecycle.state.isTerminal,
          current.lifecycle.activeOffer == offer
        else { return }
        let active = Set(tasks.compactMap { Self.taskIdentity(from: $0.taskDescription) })
        reservedTaskIdentities.formUnion(active)

        // Plan segmented ranged work for every not-yet-validated track.
        var pendingWork: [(track: WatchTransferManifest.Track, segment: WatchShareSegmentPlanner.Segment)] = []
        for track in manifest.tracks where !current.lifecycle.completedTrackIndexes.contains(track.index) {
          let plan = WatchShareSegmentPlanner.plan(totalByteCount: track.byteCount)
          if plan.isEmpty {
            // Zero-byte edge: fetch as one whole file.
            pendingWork.append(
              (
                track,
                WatchShareSegmentPlanner.Segment(index: -1, startOffset: 0, byteCount: track.byteCount)
              )
            )
            continue
          }
          let stored = storedSegmentByteCounts(
            transferID: transferID,
            trackIndex: track.index,
            fileExtension: normalizedExtension(track.fileExtension),
            plan: plan
          )
          for segment in WatchShareSegmentPlanner.missingSegments(from: plan, storedSegmentByteCounts: stored) {
            pendingWork.append((track, segment))
          }
        }

        var inFlightCount = reservedTaskIdentities.filter { identity in
          identity.transferID == transferID
            && identity.replacementGeneration == offer.replacementGeneration
            && identity.kind == .track
        }.count
        for work in pendingWork {
          guard inFlightCount < Self.maxInFlightSegmentTasks else { break }
          let isSegment = work.segment.index >= 0
          let identity = TaskIdentity(
            transferID: transferID,
            replacementGeneration: offer.replacementGeneration,
            kind: .track,
            trackIndex: work.track.index,
            fileExtension: work.track.fileExtension,
            segmentIndex: isSegment ? work.segment.index : nil,
            rangeStart: isSegment ? work.segment.startOffset : nil,
            rangeLength: isSegment ? work.segment.byteCount : nil
          )
          guard !reservedTaskIdentities.contains(identity) else {
            inFlightCount += 1
            continue
          }
          reservedTaskIdentities.insert(identity)
          inFlightCount += 1

          let url = offer.publicBootstrapURL
            .appendingPathComponent("track")
            .appendingPathComponent(String(work.track.index))
          var request = URLRequest(url: url)
          request.httpShouldHandleCookies = true
          if isSegment {
            request.setValue(work.segment.rangeHeaderValue, forHTTPHeaderField: "Range")
          }
          let task = session.downloadTask(with: request)
          task.taskDescription = Self.encodeTaskIdentity(identity)
          task.countOfBytesClientExpectsToReceive =
            isSegment ? work.segment.byteCount : work.track.byteCount
          task.resume()
        }

        let coverIdentity = TaskIdentity(
          transferID: transferID,
          replacementGeneration: offer.replacementGeneration,
          kind: .cover,
          trackIndex: nil,
          fileExtension: nil
        )
        if !current.coverDownloaded,
          !reservedTaskIdentities.contains(where: { $0.transferID == transferID && $0.kind == .cover })
        {
          reservedTaskIdentities.insert(coverIdentity)
          let task = session.downloadTask(
            with: offer.publicBootstrapURL.appendingPathComponent("cover")
          )
          task.taskDescription = Self.encodeTaskIdentity(coverIdentity)
          task.resume()
        }
      }
    }
  }

  private func validateExistingTracks(for job: inout Job, manifest: WatchTransferManifest) {
    for track in manifest.tracks where !job.lifecycle.completedTrackIndexes.contains(track.index) {
      let url = trackURL(transferID: manifest.transferID, track: track)
      guard
        validate(
          url: url,
          descriptor: job.lifecycle.activeOffer?.tracks.first(where: {
            $0.index == track.index
          })
        )
      else {
        try? fileManager.removeItem(at: url)
        continue
      }
      guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
      _ = job.lifecycle.recordValidatedTrack(index: track.index, data: data)

      // Prune segments that no longer match their planned size so planning
      // re-downloads exactly what is missing after relaunch.
      let plan = WatchShareSegmentPlanner.plan(totalByteCount: track.byteCount)
      for segment in plan {
        let segmentFile = segmentURL(
          transferID: manifest.transferID,
          trackIndex: track.index,
          segmentIndex: segment.index,
          fileExtension: normalizedExtension(track.fileExtension)
        )
        guard fileSize(at: segmentFile) == segment.byteCount else {
          try? fileManager.removeItem(at: segmentFile)
          continue
        }
      }
    }
  }

  private func finishIfReady(transferID: String) {
    guard var job = jobs[transferID], job.lifecycle.isComplete, let manifest = job.manifest else {
      return
    }
    do {
      let coverURL = stagingDirectory(transferID: transferID).appendingPathComponent("cover.jpg")
      let installManifest = WatchTransferManifest(
        transferID: manifest.transferID,
        bookID: manifest.bookID,
        title: manifest.title,
        authorName: manifest.authorName,
        duration: manifest.duration,
        currentTime: manifest.currentTime,
        tracks: manifest.tracks,
        expectsCover: fileManager.fileExists(atPath: coverURL.path),
        expectedCoverByteCount: fileSize(at: coverURL)
      )
      try WatchFileTransferReceiver.installValidatedShare(manifest: installManifest)
      guard job.lifecycle.markCompleted() else { return }
      jobs[transferID] = job
      saveJobs()
      cancelTasks(transferID: transferID)
      WatchConnectivityManager.shared.clearWatchTransferProgress(transferID: transferID)
      sendCompletion(for: job)
      try? fileManager.removeItem(at: stagingDirectory(transferID: transferID))
      logger.info("Installed public-share Watch book \(manifest.bookID)")
      finishActiveTransfer(transferID)
    } catch {
      fail(transferID: transferID, error: error)
    }
  }

  private func processStagedDownload(
    response: HTTPURLResponse,
    identity: TaskIdentity,
    destination: URL?
  ) {
    reservedTaskIdentities.remove(identity)
    taskProgress.removeValue(forKey: identity)
    guard var job = jobs[identity.transferID],
      let offer = job.lifecycle.activeOffer,
      offer.replacementGeneration == identity.replacementGeneration
    else {
      destination.map { try? fileManager.removeItem(at: $0) }
      return
    }
    if response.statusCode == 404 || response.statusCode == 410 {
      destination.map { try? fileManager.removeItem(at: $0) }
      expireAndRequestReplacement(transferID: identity.transferID)
      return
    }
    guard (200...299).contains(response.statusCode), let destination else {
      if identity.kind == .track {
        destination.map { try? fileManager.removeItem(at: $0) }
        handleTransientError(
          transferID: identity.transferID,
          error: CoordinatorError.invalidTrackResponse
        )
      }
      return
    }

    switch identity.kind {
    case .track:
      guard let index = identity.trackIndex,
        let track = offer.tracks.first(where: { $0.index == index }),
        let manifestTrack = job.manifest?.tracks.first(where: { $0.index == index })
      else {
        try? fileManager.removeItem(at: destination)
        fail(transferID: identity.transferID, error: CoordinatorError.invalidTrackResponse)
        return
      }

      // The server ignored the Range header for a mid-track segment; fall back
      // to one whole-track task instead of failing the transfer.
      if response.statusCode == 200, identity.segmentIndex != nil, (identity.rangeStart ?? 0) > 0 {
        try? fileManager.removeItem(at: destination)
        scheduleWholeTrackFallback(
          transferID: identity.transferID,
          track: manifestTrack,
          offer: offer
        )
        return
      }

      if let segmentIndex = identity.segmentIndex, segmentIndex >= 0 {
        let plannedSegment = WatchShareSegmentPlanner.plan(totalByteCount: track.byteCount)
          .first { $0.index == segmentIndex }
        guard response.statusCode == 206,
          let plannedSegment,
          fileSize(at: destination) == plannedSegment.byteCount
        else {
          try? fileManager.removeItem(at: destination)
          handleTransientError(
            transferID: identity.transferID,
            error: CoordinatorError.invalidTrackResponse
          )
          return
        }
        transientFailureCounts[identity.transferID] = nil
        publishProgress(job)
        assembleTrackIfComplete(
          transferID: identity.transferID,
          manifestTrack: manifestTrack,
          offer: offer
        )
        return
      }

      var updatedJob = job
      if installWholeTrack(
        stagedURL: destination,
        transferID: identity.transferID,
        descriptor: track,
        manifestTrack: manifestTrack,
        job: &updatedJob
      ) {
        transientFailureCounts[identity.transferID] = nil
        jobs[identity.transferID] = updatedJob
        saveJobs()
        publishProgress(updatedJob)
        finishIfReady(transferID: identity.transferID)
      } else {
        fail(transferID: identity.transferID, error: CoordinatorError.integrityMismatch)
      }

    case .cover:
      guard let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
        contentType.hasPrefix("image/"), (fileSize(at: destination) ?? 0) > 0
      else {
        try? fileManager.removeItem(at: destination)
        return
      }
      do {
        try replacePersistentFile(
          destination,
          at: stagingDirectory(transferID: identity.transferID).appendingPathComponent("cover.jpg")
        )
      } catch {
        try? fileManager.removeItem(at: destination)
        return
      }
      job.coverDownloaded = true
      jobs[identity.transferID] = job
      saveJobs()
    }
  }

  /// Moves the delegate-owned temporary file synchronously before its callback returns.
  nonisolated private static func stageTemporaryDownload(
    _ source: URL,
    identity: TaskIdentity
  ) throws -> URL {
    let directory = URL.documentsDirectory.appendingPathComponent(
      "watch-transfer-inbox/\(identity.transferID)"
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination: URL
    guard isSafeIdentifier(identity.transferID) else {
      throw CoordinatorError.invalidTrackResponse
    }
    switch identity.kind {
    case .track:
      guard let index = identity.trackIndex, index >= 0,
        let fileExtension = identity.fileExtension, isSafeFileExtension(fileExtension)
      else {
        throw CoordinatorError.invalidTrackResponse
      }
      let fileName: String
      if let segmentIndex = identity.segmentIndex, segmentIndex >= 0 {
        fileName = "track-\(index).seg\(segmentIndex)\(fileExtension)"
      } else {
        fileName = "track-\(index)\(fileExtension)"
      }
      destination = directory.appendingPathComponent(fileName)
    case .cover:
      destination = directory.appendingPathComponent(
        ".share-\(identity.replacementGeneration)-cover.downloaded"
      )
    }

    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).download")
    try FileManager.default.moveItem(at: source, to: temporary)
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
    return destination
  }

  private func replacePersistentFile(_ source: URL, at destination: URL) throws {
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: source)
    } else {
      try fileManager.moveItem(at: source, to: destination)
    }
  }

  private func validate(url: URL, descriptor: WatchShareTrackDescriptor?) -> Bool {
    guard let descriptor, fileSize(at: url) == descriptor.byteCount else { return false }
    guard let integrity = descriptor.integrity else { return true }
    guard integrity.byteCount == descriptor.byteCount,
      let handle = try? FileHandle(forReadingFrom: url)
    else { return false }
    defer { try? handle.close() }

    var hasher = SHA256()
    do {
      while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
        hasher.update(data: data)
      }
    } catch {
      return false
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return digest.caseInsensitiveCompare(integrity.digest) == .orderedSame
  }

  private func fail(transferID: String, error: Error) {
    guard var job = jobs[transferID], !job.lifecycle.state.isTerminal else { return }
    job.lifecycle.fail()
    job.failureDescription = error.localizedDescription
    jobs[transferID] = job
    saveJobs()
    cancelTasks(transferID: transferID)
    sendStatus(command: "watchShareFailed", job: job)
    logger.error("Watch share failed: \(error.localizedDescription)")
    finishActiveTransfer(transferID)
  }

  private func expireAndRequestReplacement(transferID: String) {
    guard var job = jobs[transferID], !job.lifecycle.state.isTerminal else { return }
    // A server 404 is authoritative even if the local clock has not reached expiresAt.
    if !job.lifecycle.markExpired() {
      job.lifecycle.fail()
    }
    jobs[transferID] = job
    saveJobs()
    cancelTasks(transferID: transferID)
    requestReplacement(for: job)
  }

  private func requestReplacement(for job: Job) {
    sendStatus(command: "requestWatchShareReplacement", job: job)
  }

  private func startWatchdogIfNeeded() {
    guard watchdogTimer == nil else { return }
    let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.watchdogTick()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    watchdogTimer = timer
  }

  /// Self-heals interrupted downloads: anything active with no in-flight track
  /// work gets its scheduler nudged, which re-plans exactly the missing pieces.
  private func watchdogTick() {
    guard !jobs.isEmpty else { return }
    for transferID in jobs.keys.sorted() {
      guard let job = jobs[transferID], !job.lifecycle.state.isTerminal,
        job.lifecycle.activeOffer != nil,
        bootstrapTasks[transferID] == nil
      else { continue }
      let hasInFlightTrackWork = reservedTaskIdentities.contains { identity in
        identity.transferID == transferID && identity.kind == .track
      }
      guard !hasInFlightTrackWork else { continue }
      resume(transferID: transferID)
    }
  }

  private func handleTransientError(transferID: String, error: Error) {
    guard let job = jobs[transferID], !job.lifecycle.state.isTerminal else { return }
    let count = (transientFailureCounts[transferID] ?? 0) + 1
    transientFailureCounts[transferID] = count
    logger.warning("Share download interrupted (\(count)): \(error.localizedDescription)")
    guard count <= Self.maximumTransientFailures else {
      transientFailureCounts[transferID] = nil
      fail(transferID: transferID, error: error)
      return
    }
  }

  private func cancel(transferID: String, notifyPhone: Bool) {
    guard var job = jobs[transferID], job.lifecycle.state != .completed else { return }
    _ = job.lifecycle.cancel()
    transientFailureCounts[transferID] = nil
    jobs[transferID] = job
    saveJobs()
    bootstrapTasks[transferID]?.cancel()
    bootstrapTasks.removeValue(forKey: transferID)
    cancelTasks(transferID: transferID)
    try? fileManager.removeItem(at: stagingDirectory(transferID: transferID))
    WatchConnectivityManager.shared.clearWatchTransferProgress(transferID: transferID)
    if notifyPhone { sendStatus(command: "watchShareCancelled", job: job) }
    finishActiveTransfer(transferID)
  }

  private func sendCompletion(for job: Job) {
    sendStatus(command: "watchShareCompleted", job: job)
  }

  private func sendStatus(command: String, job: Job) {
    WatchConnectivityManager.shared.sendWatchShareStatus(
      command: command,
      transferID: job.lifecycle.transferID,
      bookID: job.lifecycle.bookID,
      shareID: job.lifecycle.lastShareID,
      replacementGeneration: job.lifecycle.replacementGeneration
    )
  }

  private func cancelTasks(transferID: String) {
    reservedTaskIdentities = reservedTaskIdentities.filter { $0.transferID != transferID }
    taskProgress = taskProgress.filter { $0.key.transferID != transferID }
    session.getAllTasks { tasks in
      for task in tasks where Self.taskIdentity(from: task.taskDescription)?.transferID == transferID {
        task.cancel()
      }
    }
  }

  private func publishProgress(_ job: Job) {
    guard let offer = job.lifecycle.activeOffer else { return }
    let totalByteCount = offer.tracks.reduce(0) { $0 + $1.byteCount }
    let completedIndexes = Set(job.lifecycle.completedTrackIndexes)
    var receivedByteCount: Int64 = 0
    for track in offer.tracks {
      if completedIndexes.contains(track.index) {
        receivedByteCount += track.byteCount
        continue
      }
      let plan = WatchShareSegmentPlanner.plan(totalByteCount: track.byteCount)
      let stored = storedSegmentByteCounts(
        transferID: job.lifecycle.transferID,
        trackIndex: track.index,
        fileExtension: normalizedExtension(track.fileExtension),
        plan: plan
      )
      receivedByteCount += WatchShareSegmentPlanner.completedByteCount(
        for: plan,
        storedSegmentByteCounts: stored
      )
      receivedByteCount += taskProgress.reduce(Int64(0)) { partial, entry in
        guard entry.key.transferID == job.lifecycle.transferID,
          entry.key.kind == .track,
          entry.key.trackIndex == track.index
        else { return partial }
        return partial + entry.value
      }
    }
    WatchConnectivityManager.shared.publishWatchTransferProgress(
      transferID: job.lifecycle.transferID,
      progress: WatchTransferByteProgress(
        receivedByteCount: min(receivedByteCount, totalByteCount),
        totalByteCount: totalByteCount
      )
    )
  }

  private func recordProgress(identity: TaskIdentity, totalBytesWritten: Int64) {
    guard identity.kind == .track, let job = jobs[identity.transferID],
      job.lifecycle.replacementGeneration == identity.replacementGeneration
    else { return }
    taskProgress[identity] = max(0, totalBytesWritten)
    publishProgress(job)
  }

  private func segmentURL(
    transferID: String,
    trackIndex: Int,
    segmentIndex: Int,
    fileExtension: String
  ) -> URL {
    stagingDirectory(transferID: transferID).appendingPathComponent(
      "track-\(trackIndex).seg\(segmentIndex)\(fileExtension)"
    )
  }

  private func storedSegmentByteCounts(
    transferID: String,
    trackIndex: Int,
    fileExtension: String,
    plan: [WatchShareSegmentPlanner.Segment]
  ) -> [Int: Int64] {
    var counts: [Int: Int64] = [:]
    for segment in plan {
      let url = segmentURL(
        transferID: transferID,
        trackIndex: trackIndex,
        segmentIndex: segment.index,
        fileExtension: fileExtension
      )
      counts[segment.index] = fileSize(at: url) ?? 0
    }
    return counts
  }

  /// Used only when a server ignores Range headers mid-track.
  private func scheduleWholeTrackFallback(
    transferID: String,
    track: WatchTransferManifest.Track,
    offer: WatchShareOffer
  ) {
    let identity = TaskIdentity(
      transferID: transferID,
      replacementGeneration: offer.replacementGeneration,
      kind: .track,
      trackIndex: track.index,
      fileExtension: track.fileExtension
    )
    guard !reservedTaskIdentities.contains(identity) else { return }
    reservedTaskIdentities.insert(identity)
    let url = offer.publicBootstrapURL
      .appendingPathComponent("track")
      .appendingPathComponent(String(track.index))
    var request = URLRequest(url: url)
    request.httpShouldHandleCookies = true
    let task = session.downloadTask(with: request)
    task.taskDescription = Self.encodeTaskIdentity(identity)
    task.countOfBytesClientExpectsToReceive = track.byteCount
    task.resume()
  }

  private func installWholeTrack(
    stagedURL: URL,
    transferID: String,
    descriptor: WatchShareTrackDescriptor?,
    manifestTrack: WatchTransferManifest.Track,
    job: inout Job
  ) -> Bool {
    guard validate(url: stagedURL, descriptor: descriptor) else {
      try? fileManager.removeItem(at: stagedURL)
      return false
    }
    let installedURL = trackURL(transferID: transferID, track: manifestTrack)
    do {
      try replacePersistentFile(stagedURL, at: installedURL)
    } catch {
      try? fileManager.removeItem(at: stagedURL)
      return false
    }
    guard let data = try? Data(contentsOf: installedURL, options: .mappedIfSafe),
      job.lifecycle.recordValidatedTrack(index: manifestTrack.index, data: data) != .rejected
    else {
      try? fileManager.removeItem(at: installedURL)
      return false
    }
    return true
  }

  /// Concatenates finished segments into the validated whole-track file.
  private func assembleTrackIfComplete(
    transferID: String,
    manifestTrack: WatchTransferManifest.Track,
    offer: WatchShareOffer
  ) {
    let plan = WatchShareSegmentPlanner.plan(totalByteCount: manifestTrack.byteCount)
    guard !plan.isEmpty else { return }
    let extensionValue = normalizedExtension(manifestTrack.fileExtension)
    let stored = storedSegmentByteCounts(
      transferID: transferID,
      trackIndex: manifestTrack.index,
      fileExtension: extensionValue,
      plan: plan
    )
    guard WatchShareSegmentPlanner.missingSegments(from: plan, storedSegmentByteCounts: stored).isEmpty
    else { return }

    let finalURL = trackURL(transferID: transferID, track: manifestTrack)
    do {
      try fileManager.createDirectory(
        at: stagingDirectory(transferID: transferID),
        withIntermediateDirectories: true
      )
      if fileManager.fileExists(atPath: finalURL.path) {
        try fileManager.removeItem(at: finalURL)
      }
      FileManager.default.createFile(atPath: finalURL.path, contents: nil)
      let handle = try FileHandle(forWritingTo: finalURL)
      defer { try? handle.close() }
      for segment in plan {
        let data = try Data(
          contentsOf: segmentURL(
            transferID: transferID,
            trackIndex: manifestTrack.index,
            segmentIndex: segment.index,
            fileExtension: extensionValue
          ),
          options: .mappedIfSafe
        )
        try handle.write(contentsOf: data)
      }
      try handle.close()

      guard
        let descriptor = offer.tracks.first(where: { $0.index == manifestTrack.index }),
        validate(url: finalURL, descriptor: descriptor),
        var job = jobs[transferID],
        let data = try? Data(contentsOf: finalURL, options: .mappedIfSafe),
        job.lifecycle.recordValidatedTrack(index: manifestTrack.index, data: data) != .rejected
      else {
        throw CoordinatorError.integrityMismatch
      }
      for segment in plan {
        try? fileManager.removeItem(
          at: segmentURL(
            transferID: transferID,
            trackIndex: manifestTrack.index,
            segmentIndex: segment.index,
            fileExtension: extensionValue
          )
        )
      }
      jobs[transferID] = job
      saveJobs()
      publishProgress(job)
      logger.info("Assembled segmented share track \(manifestTrack.index)")
      finishIfReady(transferID: transferID)
    } catch {
      try? fileManager.removeItem(at: finalURL)
      logger.error("Could not assemble segmented track: \(error.localizedDescription)")
    }
  }

  private func stagingDirectory(transferID: String) -> URL {
    URL.documentsDirectory.appendingPathComponent("watch-transfer-inbox/\(transferID)")
  }

  private func trackURL(
    transferID: String,
    track: WatchTransferManifest.Track
  ) -> URL {
    stagingDirectory(transferID: transferID).appendingPathComponent(
      "track-\(track.index)\(track.fileExtension)"
    )
  }

  private func fileSize(at url: URL) -> Int64? {
    (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
  }

  private func validTrackPath(_ value: String, offer: WatchShareOffer, index: Int) -> Bool {
    guard let resolved = URL(string: value, relativeTo: offer.publicBootstrapURL)?.absoluteURL else {
      return false
    }
    let expected = offer.publicBootstrapURL
      .appendingPathComponent("track")
      .appendingPathComponent(String(index))
    guard
      let lhs = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
      let rhs = URLComponents(url: expected, resolvingAgainstBaseURL: false)
    else { return false }
    return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host?.lowercased() == rhs.host?.lowercased()
      && lhs.port == rhs.port
      && lhs.path == rhs.path
      && lhs.user == nil && lhs.password == nil && lhs.query == nil && lhs.fragment == nil
  }

  private func normalizedExtension(_ value: String) -> String {
    value.hasPrefix(".") ? value : ".\(value)"
  }

  nonisolated private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
  }

  nonisolated private static func isSafeFileExtension(_ value: String) -> Bool {
    value.first == "." && value.count > 1
      && value.dropFirst().allSatisfy { $0.isLetter || $0.isNumber }
  }

  nonisolated private static func encodeTaskIdentity(_ identity: TaskIdentity) -> String? {
    guard let data = try? JSONEncoder().encode(identity) else { return nil }
    return data.base64EncodedString()
  }

  nonisolated private static func taskIdentity(from description: String?) -> TaskIdentity? {
    guard let description, let data = Data(base64Encoded: description) else { return nil }
    return try? JSONDecoder().decode(TaskIdentity.self, from: data)
  }

  private func loadJobs() {
    guard let data = UserDefaults.standard.data(forKey: Keys.jobs),
      let decoded = try? JSONDecoder().decode([String: Job].self, from: data)
    else { return }
    jobs = decoded
    for job in decoded.values { publishProgress(job) }
  }

  private func saveJobs() {
    guard let data = try? JSONEncoder().encode(jobs) else { return }
    UserDefaults.standard.set(data, forKey: Keys.jobs)
    saveQueueState()
  }

  private func saveQueueState() {
    UserDefaults.standard.set(queuedTransferIDs, forKey: Keys.queue)
    if let activeTransferID {
      UserDefaults.standard.set(activeTransferID, forKey: Keys.activeTransferID)
    } else {
      UserDefaults.standard.removeObject(forKey: Keys.activeTransferID)
    }
  }
}

extension WatchShareDownloadCoordinator: URLSessionDownloadDelegate {
  nonisolated func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard let description = downloadTask.taskDescription else { return }
    Task { @MainActor in
      guard let identity = Self.taskIdentity(from: description) else { return }
      recordProgress(identity: identity, totalBytesWritten: totalBytesWritten)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let identity = Self.taskIdentity(from: downloadTask.taskDescription),
      let response = downloadTask.response as? HTTPURLResponse
    else { return }
    let destination: URL?
    do {
      destination = try Self.stageTemporaryDownload(location, identity: identity)
    } catch {
      destination = nil
    }
    Task { @MainActor in
      processStagedDownload(response: response, identity: identity, destination: destination)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let description = task.taskDescription else { return }
    Task { @MainActor in
      guard let identity = Self.taskIdentity(from: description) else { return }
      reservedTaskIdentities.remove(identity)
      guard let error, identity.kind == .track else { return }
      let urlError = error as? URLError
      guard urlError?.code != .cancelled else { return }
      handleTransientError(transferID: identity.transferID, error: error)
    }
  }

  nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor in
      let completions = backgroundTaskCompletions
      backgroundTaskCompletions.removeAll()
      for completion in completions {
        completion()
      }
    }
  }
}
