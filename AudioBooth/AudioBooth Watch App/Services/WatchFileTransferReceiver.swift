import Foundation
import Models
import OSLog
import WatchConnectivity

/// Stages WatchConnectivity files synchronously, then installs a book only after every expected file validates.
enum WatchFileTransferReceiver {
  nonisolated private static let receiptsKey = "watch_file_transfer_receipts"
  nonisolated private static let relayManifestKey = "watch_relay_manifest"
  nonisolated private static let relayStateKey = "watch_relay_receive_state"
  nonisolated private static let downloadLogger = Logger(
    subsystem: "me.jgrenier.AudioBS.watchkitapp",
    category: "download"
  )
  private static let relayWindowSize = 8
  private static var relayRequestsInFlight: Set<WatchTransferChunkRequest> = []

  nonisolated static func receive(_ file: WCSessionFile) {
    guard let metadata = metadata(from: file.metadata), isSafeIdentifier(metadata.transferID),
      isSafeIdentifier(metadata.bookID)
    else {
      downloadLogger.error("Ignoring Watch file transfer with invalid metadata")
      return
    }

    do {
      if metadata.kind == .thumbnail {
        try stageThumbnail(fileURL: file.fileURL, metadata: metadata)
        Task { @MainActor in
          NotificationCenter.default.post(name: .watchCatalogArtworkUpdated, object: metadata.bookID)
        }
        return
      }
      try stage(fileURL: file.fileURL, metadata: metadata)
    } catch {
      downloadLogger.error("Failed to stage Watch file transfer: \(error.localizedDescription)")
      return
    }

    Task { @MainActor in
      processStagedTransfer(transferID: metadata.transferID)
    }
  }

  @MainActor
  static func receiveRelayManifest(_ data: Data, expectedBookID: String? = nil) {
    relayRequestsInFlight.removeAll()
    do {
      let manifest = try PropertyListDecoder().decode(WatchTransferManifest.self, from: data)
      guard isValidRelayManifest(manifest),
        expectedBookID == nil || expectedBookID == manifest.bookID
      else {
        throw CocoaError(.fileReadCorruptFile)
      }

      let state: WatchTransferReceiveState
      if let storedManifest = loadRelayManifest(),
        storedManifest == manifest,
        let storedState = loadRelayState(),
        stateMatchesManifest(storedState, manifest: manifest)
      {
        state = storedState
      } else {
        if let oldTransferID = loadRelayManifest()?.transferID {
          deleteStagingDirectory(transferID: oldTransferID)
        }
        clearRelayState()
        state = makeReceiveState(for: manifest)
      }

      guard saveRelayManifest(manifest), saveRelayState(state) else {
        throw CocoaError(.fileWriteUnknown)
      }
      publishRelayProgress(state)
      requestNextRelayChunks(manifest: manifest, state: state)
    } catch {
      AppLogger.download.error("Failed to receive Watch relay manifest: \(error.localizedDescription)")
    }
  }

  @MainActor
  static func resumeRelayTransfers() {
    relayRequestsInFlight.removeAll()
    guard let manifest = loadRelayManifest(), isValidRelayManifest(manifest) else { return }

    guard let state = loadRelayState(), stateMatchesManifest(state, manifest: manifest) else {
      guard let data = encodePropertyList(manifest) else { return }
      receiveRelayManifest(data)
      return
    }

    publishRelayProgress(state)
    requestNextRelayChunks(manifest: manifest, state: state)
  }

  @MainActor
  static func cancelRelay(bookID: String) {
    guard let manifest = loadRelayManifest(), manifest.bookID == bookID else { return }
    relayRequestsInFlight.removeAll()
    clearRelayState()
    deleteStagingDirectory(transferID: manifest.transferID)
    WatchConnectivityManager.shared.clearWatchTransferProgress(transferID: manifest.transferID)
  }

  @MainActor
  static func pauseRelayTransfers() {
    relayRequestsInFlight.removeAll()
  }

  @MainActor
  private static func requestNextRelayChunks(
    manifest: WatchTransferManifest,
    state: WatchTransferReceiveState
  ) {
    guard loadRelayManifest()?.manifestIdentity == manifest.manifestIdentity else { return }
    guard !audioTransferIsComplete(manifest: manifest, state: state) else {
      finishRelayTransfer(manifest: manifest, state: state)
      return
    }
    guard WatchConnectivityManager.shared.isReachable else { return }

    let availableSlots = relayWindowSize - relayRequestsInFlight.count
    guard availableSlots > 0 else { return }

    let requests = state.missingChunkRequests()
      .filter { $0.file.kind == .track && !relayRequestsInFlight.contains($0) }
      .prefix(availableSlots)
    guard !requests.isEmpty else {
      AppLogger.download.error("Watch relay has no missing audio chunk for \(manifest.transferID)")
      return
    }

    for request in requests {
      relayRequestsInFlight.insert(request)
      let sent = WatchConnectivityManager.shared.sendWatchRelayChunkRequest(
        request,
        replyHandler: { data in
          Task { @MainActor in
            guard relayRequestsInFlight.remove(request) != nil,
              loadRelayManifest()?.manifestIdentity == manifest.manifestIdentity
            else { return }
            receiveRelayChunk(data, request: request, manifest: manifest)
          }
        },
        errorHandler: { error in
          Task { @MainActor in
            guard relayRequestsInFlight.remove(request) != nil else { return }
            AppLogger.download.error(
              "Watch relay chunk request paused: \(error.localizedDescription)"
            )
            resumeRelayWindow(manifest: manifest)
          }
        }
      )
      if !sent {
        relayRequestsInFlight.remove(request)
      }
    }
  }

  @MainActor
  private static func resumeRelayWindow(manifest: WatchTransferManifest) {
    guard let state = loadRelayState(), stateMatchesManifest(state, manifest: manifest) else { return }
    publishRelayProgress(state)
    requestNextRelayChunks(manifest: manifest, state: state)
  }

  @MainActor
  private static func receiveRelayChunk(
    _ data: Data,
    request: WatchTransferChunkRequest,
    manifest: WatchTransferManifest
  ) {
    guard let state = loadRelayState(), stateMatchesManifest(state, manifest: manifest),
      let descriptor = manifest.fileDescriptors.first(where: { $0.identity == request.file })
    else {
      AppLogger.download.error("Ignoring Watch relay chunk for unknown transfer state")
      return
    }

    do {
      let response = try PropertyListDecoder().decode(WatchTransferChunkResponse.self, from: data)
      guard response.request == request else {
        throw CocoaError(.fileReadCorruptFile)
      }
      guard response.validate(against: descriptor) == nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
      guard !response.data.isEmpty else {
        throw CocoaError(.fileReadCorruptFile)
      }

      try writeRelayChunk(response, manifest: manifest)
      var updatedState = state
      guard updatedState.record(response, descriptor: descriptor) == nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
      guard saveRelayState(updatedState) else {
        throw CocoaError(.fileWriteUnknown)
      }

      publishRelayProgress(updatedState)
      if audioTransferIsComplete(manifest: manifest, state: updatedState) {
        finishRelayTransfer(manifest: manifest, state: updatedState)
      } else {
        requestNextRelayChunks(manifest: manifest, state: updatedState)
      }
    } catch {
      AppLogger.download.error("Ignoring invalid Watch relay chunk: \(error.localizedDescription)")
      resumeRelayWindow(manifest: manifest)
    }
  }

  @MainActor
  private static func finishRelayTransfer(
    manifest: WatchTransferManifest,
    state: WatchTransferReceiveState
  ) {
    do {
      for track in manifest.tracks {
        try assembleTrackIfComplete(track, transferID: manifest.transferID)
        let source = stagingDirectory(transferID: manifest.transferID)
          .appendingPathComponent("track-\(track.index)\(track.fileExtension)")
        guard fileSize(at: source) == track.byteCount else {
          throw CocoaError(.fileReadCorruptFile)
        }
      }

      let book = try install(manifest: manifest)
      LocalBookStorage.shared.saveBook(book)
      WatchConnectivityManager.shared.sendWatchTransferCompletion(transferID: manifest.transferID)
      clearRelayState()
      deleteStagingDirectory(transferID: manifest.transferID)
      WatchConnectivityManager.shared.clearWatchTransferProgress(transferID: manifest.transferID)
      AppLogger.download.info("Installed relayed Watch book \(manifest.bookID)")
    } catch {
      publishRelayProgress(state)
      AppLogger.download.error("Failed to install Watch relay: \(error.localizedDescription)")
    }
  }

  nonisolated private static func writeRelayChunk(
    _ response: WatchTransferChunkResponse,
    manifest: WatchTransferManifest
  ) throws {
    guard let track = manifest.tracks.first(where: { $0.index == response.file.trackIndex }),
      response.file.kind == .track,
      isSafeTrackExtension(track.fileExtension)
    else {
      throw CocoaError(.fileReadCorruptFile)
    }

    let directory = stagingDirectory(transferID: manifest.transferID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(
      "track-\(track.index)-part-\(response.chunkIndex)\(track.fileExtension)"
    )
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).chunk")
    try response.data.write(to: temporary, options: .atomic)
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
    guard fileSize(at: destination) == response.byteCount else {
      try? FileManager.default.removeItem(at: destination)
      throw CocoaError(.fileReadCorruptFile)
    }
  }

  @MainActor
  private static func publishRelayProgress(_ state: WatchTransferReceiveState) {
    WatchConnectivityManager.shared.publishWatchTransferProgress(
      transferID: state.identity.transferID,
      progress: state.byteProgress
    )
  }

  private static func audioTransferIsComplete(
    manifest: WatchTransferManifest,
    state: WatchTransferReceiveState
  ) -> Bool {
    !manifest.tracks.isEmpty
      && manifest.tracks.allSatisfy { track in
        let identity = WatchTransferFileIdentity.track(
          transferID: manifest.transferID,
          bookID: manifest.bookID,
          trackIndex: track.index
        )
        return state.state(for: identity)?.isComplete == true
      }
  }

  private static func makeReceiveState(for manifest: WatchTransferManifest) -> WatchTransferReceiveState {
    WatchTransferReceiveState(
      identity: manifest.manifestIdentity,
      files: manifest.fileDescriptors.map {
        WatchTransferFileReceiveState(
          file: $0.identity,
          expectedByteCount: $0.byteCount,
          expectedChunkCount: $0.chunkCount
        )
      }
    )
  }

  private static func stateMatchesManifest(
    _ state: WatchTransferReceiveState,
    manifest: WatchTransferManifest
  ) -> Bool {
    guard state.identity == manifest.manifestIdentity else { return false }
    let descriptors = manifest.fileDescriptors
    guard state.files.count == descriptors.count else { return false }
    return state.files.allSatisfy { fileState in
      guard let descriptor = descriptors.first(where: { $0.identity == fileState.file }) else {
        return false
      }
      return fileState.expectedByteCount == descriptor.byteCount
        && fileState.expectedChunkCount == descriptor.chunkCount
        && fileState.validate() == nil
    }
  }

  private static func isValidRelayManifest(_ manifest: WatchTransferManifest) -> Bool {
    guard isSafeIdentifier(manifest.transferID), isSafeIdentifier(manifest.bookID),
      !manifest.tracks.isEmpty,
      Set(manifest.tracks.map(\.index)).count == manifest.tracks.count
    else { return false }
    guard
      manifest.tracks.allSatisfy({ track in
        track.byteCount > 0
          && track.duration >= 0
          && track.transferChunkCount > 0
          && isSafeTrackExtension(track.fileExtension)
      })
    else { return false }
    if let coverSize = manifest.expectedCoverByteCount {
      guard coverSize >= 0 else { return false }
    }
    return manifest.fileDescriptors.allSatisfy(\.isWellFormed)
  }

  private static func loadRelayManifest() -> WatchTransferManifest? {
    guard let data = UserDefaults.standard.data(forKey: relayManifestKey) else { return nil }
    return try? PropertyListDecoder().decode(WatchTransferManifest.self, from: data)
  }

  private static func saveRelayManifest(_ manifest: WatchTransferManifest) -> Bool {
    guard let data = encodePropertyList(manifest) else { return false }
    UserDefaults.standard.set(data, forKey: relayManifestKey)
    return true
  }

  private static func loadRelayState() -> WatchTransferReceiveState? {
    guard let data = UserDefaults.standard.data(forKey: relayStateKey) else { return nil }
    return try? PropertyListDecoder().decode(WatchTransferReceiveState.self, from: data)
  }

  private static func saveRelayState(_ state: WatchTransferReceiveState) -> Bool {
    guard let data = encodePropertyList(state) else { return false }
    UserDefaults.standard.set(data, forKey: relayStateKey)
    return true
  }

  private static func clearRelayState() {
    UserDefaults.standard.removeObject(forKey: relayManifestKey)
    UserDefaults.standard.removeObject(forKey: relayStateKey)
  }

  private static func encodePropertyList<T: Encodable>(_ value: T) -> Data? {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return try? encoder.encode(value)
  }

  nonisolated private static func isSafeTrackExtension(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.contains("/")
      && !value.contains("\\")
  }

  static func recoverStagedTransfers() {
    let root = URL.documentsDirectory.appendingPathComponent("watch-transfer-inbox", isDirectory: true)
    let directories =
      (try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
      )) ?? []
    let ids = directories.filter { isSafeIdentifier($0.lastPathComponent) }.map(\.lastPathComponent)
    Task.detached(priority: .utility) {
      for id in ids {
        await processStagedTransferBackground(transferID: id)
      }
    }
  }

  @MainActor
  private static func processStagedTransfer(transferID: String) {
    Task.detached(priority: .utility) {
      await processStagedTransferBackground(transferID: transferID)
    }
  }

  private static func processStagedTransferBackground(transferID: String) async {
    guard let manifest = loadManifest(transferID: transferID) else { return }

    var receipt = loadReceipts()[transferID] ?? WatchTransferReceipt(manifest: manifest)
    guard receipt.manifest == manifest else {
      deleteStagingDirectory(transferID: transferID)
      return
    }

    for track in manifest.tracks {
      try? assembleTrackIfComplete(track, transferID: transferID)
      let source = stagingDirectory(transferID: transferID)
        .appendingPathComponent("track-\(track.index)\(track.fileExtension)")
      guard let size = fileSize(at: source), size == track.byteCount else { continue }
      receipt.recordReceivedTrack(index: track.index)
    }

    if manifest.expectsCover,
      let expectedSize = manifest.expectedCoverByteCount,
      let size = fileSize(
        at: stagingDirectory(transferID: transferID).appendingPathComponent("cover.jpg")
      ),
      size == expectedSize,
      size > 0
    {
      receipt.recordReceivedCover()
    }

    await MainActor.run {
      saveReceipt(receipt)
      let tracksComplete = manifest.tracks.allSatisfy {
        receipt.receivedTrackIndexes.contains($0.index)
      }
      guard tracksComplete else { return }

      do {
        let book = try install(manifest: manifest)
        LocalBookStorage.shared.saveBook(book)
        WatchConnectivityManager.shared.sendWatchTransferCompletion(transferID: transferID)
        deleteReceipt(transferID: transferID)
        deleteStagingDirectory(transferID: transferID)
        AppLogger.download.info("Installed offline Watch book \(manifest.bookID)")
      } catch {
        AppLogger.download.error("Failed to install Watch transfer: \(error.localizedDescription)")
      }
    }
  }

  /// Installs already validated public-share tracks staged by WatchShareDownloadCoordinator.
  @MainActor
  static func installValidatedShare(manifest: WatchTransferManifest) throws {
    let book = try install(manifest: manifest)
    LocalBookStorage.shared.saveBook(book)
  }

  @MainActor
  private static func install(manifest: WatchTransferManifest) throws -> WatchBook {
    let audiobooksDirectory = URL.documentsDirectory.appendingPathComponent(
      "audiobooks",
      isDirectory: true
    )
    let destinationDirectory = audiobooksDirectory.appendingPathComponent(
      manifest.bookID,
      isDirectory: true
    )
    let incomingDirectory = audiobooksDirectory.appendingPathComponent(
      ".\(manifest.bookID).\(manifest.transferID).incoming",
      isDirectory: true
    )
    let transferDirectory = stagingDirectory(transferID: manifest.transferID)

    try FileManager.default.createDirectory(at: audiobooksDirectory, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: incomingDirectory)
    try FileManager.default.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)

    do {
      for track in manifest.tracks {
        let source = transferDirectory.appendingPathComponent("track-\(track.index)\(track.fileExtension)")
        let destination = incomingDirectory.appendingPathComponent("\(track.index)\(track.fileExtension)")
        try FileManager.default.copyItem(at: source, to: destination)
      }
      let coverSource = transferDirectory.appendingPathComponent("cover.jpg")
      let hasCover: Bool
      if manifest.expectsCover,
        let expectedCoverSize = manifest.expectedCoverByteCount,
        expectedCoverSize > 0,
        fileSize(at: coverSource) == expectedCoverSize
      {
        hasCover = true
      } else {
        hasCover = false
      }
      if hasCover {
        try FileManager.default.copyItem(
          at: coverSource,
          to: incomingDirectory.appendingPathComponent("cover.jpg")
        )
      }

      if FileManager.default.fileExists(atPath: destinationDirectory.path) {
        _ = try FileManager.default.replaceItemAt(destinationDirectory, withItemAt: incomingDirectory)
      } else {
        try FileManager.default.moveItem(at: incomingDirectory, to: destinationDirectory)
      }
    } catch {
      try? FileManager.default.removeItem(at: incomingDirectory)
      throw error
    }

    let tracks = manifest.tracks.map { track in
      WatchTrack(
        index: track.index,
        duration: track.duration,
        size: track.byteCount,
        ext: track.fileExtension,
        url: nil,
        relativePath: "audiobooks/\(manifest.bookID)/\(track.index)\(track.fileExtension)"
      )
    }
    let installedCover = destinationDirectory.appendingPathComponent("cover.jpg")
    return WatchBook(
      id: manifest.bookID,
      title: manifest.title,
      authorName: manifest.authorName,
      coverURL: nil,
      coverRelativePath: FileManager.default.fileExists(atPath: installedCover.path)
        ? "audiobooks/\(manifest.bookID)/cover.jpg"
        : nil,
      duration: manifest.duration,
      chapters: [],
      tracks: tracks,
      currentTime: manifest.currentTime
    )
  }

  nonisolated private static func assembleTrackIfComplete(
    _ track: WatchTransferManifest.Track,
    transferID: String
  ) throws {
    let directory = stagingDirectory(transferID: transferID)
    let destination = directory.appendingPathComponent("track-\(track.index)\(track.fileExtension)")
    if fileSize(at: destination) == track.byteCount { return }

    let chunks = (0..<track.transferChunkCount).map { index in
      directory.appendingPathComponent("track-\(track.index)-part-\(index)\(track.fileExtension)")
    }
    guard chunks.allSatisfy({ fileSize(at: $0) != nil }),
      chunks.compactMap({ fileSize(at: $0) }).reduce(0, +) == track.byteCount
    else { return }

    let temporary = directory.appendingPathComponent(".track-\(track.index).assembling")
    try? FileManager.default.removeItem(at: temporary)
    FileManager.default.createFile(atPath: temporary.path, contents: nil)
    let output = try FileHandle(forWritingTo: temporary)
    do {
      for chunk in chunks {
        try autoreleasepool {
          let input = try FileHandle(forReadingFrom: chunk)
          defer { try? input.close() }
          while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try autoreleasepool {
              try output.write(contentsOf: data)
            }
          }
        }
      }
      try output.close()
      guard fileSize(at: temporary) == track.byteCount else {
        throw CocoaError(.fileReadCorruptFile)
      }
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
      for chunk in chunks { try? FileManager.default.removeItem(at: chunk) }
    } catch {
      try? output.close()
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  nonisolated private static func stageThumbnail(
    fileURL: URL,
    metadata: WatchTransferFileMetadata
  ) throws {
    guard let expectedSize = metadata.byteCount, expectedSize > 0 else {
      throw CocoaError(.fileReadCorruptFile)
    }

    let directory = URL.documentsDirectory.appendingPathComponent("catalog-artwork", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).incoming")
    try FileManager.default.moveItem(at: fileURL, to: temporary)
    guard fileSize(at: temporary) == expectedSize else {
      try? FileManager.default.removeItem(at: temporary)
      throw CocoaError(.fileReadCorruptFile)
    }

    let destination = directory.appendingPathComponent("\(metadata.bookID).jpg")
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
  }

  nonisolated private static func stage(fileURL: URL, metadata: WatchTransferFileMetadata) throws {
    let directory = stagingDirectory(transferID: metadata.transferID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let destination: URL
    switch metadata.kind {
    case .manifest:
      destination = directory.appendingPathComponent("manifest.json")
    case .cover:
      destination = directory.appendingPathComponent("cover.jpg")
    case .thumbnail:
      throw CocoaError(.fileReadCorruptFile)
    case .track:
      guard
        let index = metadata.trackIndex,
        let fileExtension = metadata.fileExtension,
        isSafeFileExtension(fileExtension)
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
      let chunkIndex = metadata.chunkIndex ?? 0
      let chunkCount = metadata.chunkCount ?? 1
      guard chunkIndex >= 0, chunkIndex < chunkCount, chunkCount > 0 else {
        throw CocoaError(.fileReadCorruptFile)
      }
      destination = directory.appendingPathComponent(
        "track-\(index)-part-\(chunkIndex)\(fileExtension)"
      )
    }

    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).incoming")
    try FileManager.default.moveItem(at: fileURL, to: temporary)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: temporary, to: destination)

    if let expectedSize = metadata.byteCount, fileSize(at: destination) != expectedSize {
      try? FileManager.default.removeItem(at: destination)
      throw CocoaError(.fileReadCorruptFile)
    }

    if metadata.kind == .manifest {
      let manifest = try JSONDecoder().decode(WatchTransferManifest.self, from: Data(contentsOf: destination))
      guard
        manifest.transferID == metadata.transferID,
        manifest.bookID == metadata.bookID,
        Set(manifest.tracks.map(\.index)).count == manifest.tracks.count,
        manifest.tracks.allSatisfy({ track in
          track.byteCount > 0 && track.duration >= 0 && track.transferChunkCount > 0
            && isSafeFileExtension(track.fileExtension)
        })
      else {
        throw CocoaError(.fileReadCorruptFile)
      }
    }
  }

  nonisolated private static func loadManifest(transferID: String) -> WatchTransferManifest? {
    let url = stagingDirectory(transferID: transferID).appendingPathComponent("manifest.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(WatchTransferManifest.self, from: data)
  }

  nonisolated private static func loadReceipts() -> [String: WatchTransferReceipt] {
    guard
      let data = UserDefaults.standard.data(forKey: receiptsKey),
      let receipts = try? JSONDecoder().decode([String: WatchTransferReceipt].self, from: data)
    else { return [:] }
    return receipts
  }

  nonisolated private static func saveReceipt(_ receipt: WatchTransferReceipt) {
    var receipts = loadReceipts()
    receipts[receipt.manifest.transferID] = receipt
    guard let data = try? JSONEncoder().encode(receipts) else { return }
    UserDefaults.standard.set(data, forKey: receiptsKey)
  }

  nonisolated private static func deleteReceipt(transferID: String) {
    var receipts = loadReceipts()
    receipts.removeValue(forKey: transferID)
    guard let data = try? JSONEncoder().encode(receipts) else { return }
    UserDefaults.standard.set(data, forKey: receiptsKey)
  }

  nonisolated private static func deleteStagingDirectory(transferID: String) {
    try? FileManager.default.removeItem(at: stagingDirectory(transferID: transferID))
  }

  nonisolated private static func stagingDirectory(transferID: String) -> URL {
    URL.documentsDirectory.appendingPathComponent("watch-transfer-inbox/\(transferID)")
  }

  nonisolated private static func fileSize(at url: URL) -> Int64? {
    guard let number = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
      return nil
    }
    return number.int64Value
  }

  nonisolated private static func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
      && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
  }

  nonisolated private static func isSafeFileExtension(_ value: String) -> Bool {
    value.first == "."
      && value.count > 1
      && !value.contains("/")
      && !value.contains("\\")
  }

  nonisolated private static func metadata(from propertyList: [String: Any]?) -> WatchTransferFileMetadata? {
    guard
      let propertyList,
      let version = propertyList["version"] as? Int,
      version == 1,
      let rawKind = propertyList["kind"] as? String,
      let kind = WatchTransferFileMetadata.Kind(rawValue: rawKind),
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

extension Notification.Name {
  static let watchCatalogArtworkUpdated = Notification.Name("watchCatalogArtworkUpdated")
}
