import CryptoKit
import Foundation

/// Metadata shared by the iPhone and Watch to describe a credential-free offline transfer.
public struct WatchTransferManifest: Codable, Equatable, Sendable, Identifiable {
  public struct Track: Codable, Equatable, Sendable, Identifiable {
    public let index: Int
    public let duration: TimeInterval
    public let byteCount: Int64
    public let fileExtension: String
    public let chunkCount: Int?

    public var id: Int { index }
    public var transferChunkCount: Int { chunkCount ?? 1 }

    public init(
      index: Int,
      duration: TimeInterval,
      byteCount: Int64,
      fileExtension: String,
      chunkCount: Int = 1
    ) {
      self.index = index
      self.duration = duration
      self.byteCount = byteCount
      self.fileExtension = fileExtension
      self.chunkCount = chunkCount
    }
  }

  public let transferID: String
  public let bookID: String
  public let title: String
  public let authorName: String?
  public let duration: TimeInterval
  public let currentTime: TimeInterval
  public let tracks: [Track]
  public let expectsCover: Bool
  public let expectedCoverByteCount: Int64?

  public var id: String { transferID }

  public init(
    transferID: String,
    bookID: String,
    title: String,
    authorName: String?,
    duration: TimeInterval,
    currentTime: TimeInterval = 0,
    tracks: [Track],
    expectsCover: Bool = false,
    expectedCoverByteCount: Int64? = nil
  ) {
    self.transferID = transferID
    self.bookID = bookID
    self.title = title
    self.authorName = authorName
    self.duration = duration
    self.currentTime = currentTime
    self.tracks = tracks.sorted { $0.index < $1.index }
    self.expectsCover = expectsCover
    self.expectedCoverByteCount = expectedCoverByteCount
  }
}

/// The property-list-safe metadata paired with one WatchConnectivity file transfer.
/// It deliberately contains no server URL, credentials, or request headers.
public struct WatchTransferFileMetadata: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case manifest
    case cover
    case thumbnail
    case track
  }

  public let version: Int
  public let kind: Kind
  public let transferID: String
  public let bookID: String
  public let trackIndex: Int?
  public let byteCount: Int64?
  public let fileExtension: String?
  public let chunkIndex: Int?
  public let chunkCount: Int?

  public init(
    version: Int,
    kind: Kind,
    transferID: String,
    bookID: String,
    trackIndex: Int?,
    byteCount: Int64?,
    fileExtension: String?,
    chunkIndex: Int? = nil,
    chunkCount: Int? = nil
  ) {
    self.version = version
    self.kind = kind
    self.transferID = transferID
    self.bookID = bookID
    self.trackIndex = trackIndex
    self.byteCount = byteCount
    self.fileExtension = fileExtension
    self.chunkIndex = chunkIndex
    self.chunkCount = chunkCount
  }

  public static func manifest(transferID: String, bookID: String) -> Self {
    Self(
      version: 1,
      kind: .manifest,
      transferID: transferID,
      bookID: bookID,
      trackIndex: nil,
      byteCount: nil,
      fileExtension: nil
    )
  }

  public static func cover(transferID: String, bookID: String, byteCount: Int64? = nil) -> Self {
    Self(
      version: 1,
      kind: .cover,
      transferID: transferID,
      bookID: bookID,
      trackIndex: nil,
      byteCount: byteCount,
      fileExtension: "jpg"
    )
  }

  public static func thumbnail(bookID: String, byteCount: Int64) -> Self {
    Self(
      version: 1,
      kind: .thumbnail,
      transferID: "catalog",
      bookID: bookID,
      trackIndex: nil,
      byteCount: byteCount,
      fileExtension: ".jpg"
    )
  }

  public static func trackChunk(
    transferID: String,
    bookID: String,
    track: WatchTransferManifest.Track,
    chunkIndex: Int,
    byteCount: Int64
  ) -> Self {
    Self(
      version: 1,
      kind: .track,
      transferID: transferID,
      bookID: bookID,
      trackIndex: track.index,
      byteCount: byteCount,
      fileExtension: track.fileExtension,
      chunkIndex: chunkIndex,
      chunkCount: track.chunkCount
    )
  }
}

/// A book that can be copied from a fully downloaded iPhone library to the Watch.
/// Artwork is transferred as a file after selection, so this catalog has no server URL.
public struct WatchPhoneLibraryBook: Codable, Equatable, Sendable, Identifiable {
  public let bookID: String
  public let title: String
  public let authorName: String?
  public let duration: TimeInterval
  public let currentTime: TimeInterval
  public let lastPlayedAt: Date?

  public var id: String { bookID }

  public init(
    bookID: String,
    title: String,
    authorName: String?,
    duration: TimeInterval,
    currentTime: TimeInterval,
    lastPlayedAt: Date? = nil
  ) {
    self.bookID = bookID
    self.title = title
    self.authorName = authorName
    self.duration = duration
    self.currentTime = currentTime
    self.lastPlayedAt = lastPlayedAt
  }
}

public enum WatchTransferJobState: String, Codable, Equatable, Sendable {
  case queued
  case transferring
  case failed
  case completed
  case cancelled
}

/// Persisted sender/receiver status. Completion is set only after the Watch acknowledges valid files.
public struct WatchTransferJob: Codable, Equatable, Sendable, Identifiable {
  public let transferID: String
  public let bookID: String
  public var state: WatchTransferJobState
  public var sentFileCount: Int
  public var totalFileCount: Int
  public var failureDescription: String?
  public var updatedAt: Date

  public var id: String { transferID }
  public var progress: Double {
    guard totalFileCount > 0 else { return 0 }
    return min(1, max(0, Double(sentFileCount) / Double(totalFileCount)))
  }

  public init(
    transferID: String,
    bookID: String,
    state: WatchTransferJobState,
    sentFileCount: Int,
    totalFileCount: Int,
    failureDescription: String? = nil,
    updatedAt: Date = Date()
  ) {
    self.transferID = transferID
    self.bookID = bookID
    self.state = state
    self.sentFileCount = sentFileCount
    self.totalFileCount = totalFileCount
    self.failureDescription = failureDescription
    self.updatedAt = updatedAt
  }
}

public struct WatchTransferSource: Sendable {
  public let trackIndex: Int
  public let fileURL: URL

  public init(trackIndex: Int, fileURL: URL) {
    self.trackIndex = trackIndex
    self.fileURL = fileURL
  }
}

public enum WatchTransferSourceValidationError: Error, Equatable, Sendable {
  case duplicateSource(trackIndex: Int)
  case missingSource(trackIndex: Int)
  case sizeMismatch(trackIndex: Int, expected: Int64, actual: Int64)
}

public enum WatchTransferSourceValidator {
  public static func validate(
    manifest: WatchTransferManifest,
    sources: [WatchTransferSource],
    fileManager: FileManager = .default
  ) -> WatchTransferSourceValidationError? {
    var sourcesByTrack: [Int: URL] = [:]
    for source in sources {
      guard sourcesByTrack[source.trackIndex] == nil else {
        return .duplicateSource(trackIndex: source.trackIndex)
      }
      sourcesByTrack[source.trackIndex] = source.fileURL
    }

    for track in manifest.tracks {
      guard let sourceURL = sourcesByTrack[track.index], fileManager.fileExists(atPath: sourceURL.path)
      else {
        return .missingSource(trackIndex: track.index)
      }

      let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path)
      let actual = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
      guard actual == track.byteCount else {
        return .sizeMismatch(trackIndex: track.index, expected: track.byteCount, actual: actual)
      }
    }

    return nil
  }
}

/// Persisted receive state. A track can safely arrive more than once or before another track.
public struct WatchTransferReceipt: Codable, Equatable, Sendable {
  public let manifest: WatchTransferManifest
  private var receivedIndexes: Set<Int>
  public private(set) var receivedCover: Bool

  public var receivedTrackIndexes: [Int] { receivedIndexes.sorted() }
  /// Artwork is best-effort; validated audio tracks alone complete an offline transfer.
  public var isComplete: Bool {
    Set(manifest.tracks.map(\.index)).isSubset(of: receivedIndexes)
  }

  public init(
    manifest: WatchTransferManifest,
    receivedTrackIndexes: Set<Int> = [],
    receivedCover: Bool = false
  ) {
    self.manifest = manifest
    self.receivedIndexes =
      receivedTrackIndexes
      .intersection(Set(manifest.tracks.map(\.index)))
    self.receivedCover = receivedCover
  }

  public mutating func recordReceivedTrack(index: Int) {
    guard manifest.tracks.contains(where: { $0.index == index }) else { return }
    receivedIndexes.insert(index)
  }

  public mutating func recordReceivedCover() {
    receivedCover = true
  }
}

/// A Watch-only deletion plan. Source files remain owned by the iPhone download manager.
public struct WatchTransferRemovalPlan: Equatable, Sendable {
  public let bookID: String
  public let watchRelativePaths: [String]

  public init(bookID: String, watchRelativePaths: [String]) {
    self.bookID = bookID
    self.watchRelativePaths = watchRelativePaths
  }
}

public struct WatchProgressSnapshot: Codable, Equatable, Sendable {
  public let bookID: String
  public let currentTime: TimeInterval
  public let duration: TimeInterval
  public let updatedAt: Date

  public init(bookID: String, currentTime: TimeInterval, duration: TimeInterval, updatedAt: Date) {
    self.bookID = bookID
    self.currentTime = currentTime
    self.duration = duration
    self.updatedAt = updatedAt
  }
}

public enum WatchProgressReconciler {
  /// A tie keeps local progress so a duplicate or stale delivery cannot overwrite it.
  public static func resolve(
    local: WatchProgressSnapshot,
    incoming: WatchProgressSnapshot
  ) -> WatchProgressSnapshot {
    incoming.updatedAt > local.updatedAt ? incoming : local
  }
}

/// The credential-free identity shared by a transfer offer and its manifest.
public struct WatchTransferManifestIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let transferID: String
  public let bookID: String

  public var id: String { transferID }

  public init(transferID: String, bookID: String) {
    self.transferID = transferID
    self.bookID = bookID
  }

  public init(manifest: WatchTransferManifest) {
    self.init(transferID: manifest.transferID, bookID: manifest.bookID)
  }

  public func matches(_ manifest: WatchTransferManifest) -> Bool {
    self == WatchTransferManifestIdentity(manifest: manifest)
  }
}

/// A small offer that can be sent before the full manifest or file payloads.
public struct WatchTransferOffer: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let identity: WatchTransferManifestIdentity
  public let fileCount: Int
  public let totalByteCount: Int64
  public let expectsCover: Bool

  public var id: String { identity.id }
  public var transferID: String { identity.transferID }
  public var bookID: String { identity.bookID }
  public var manifestIdentity: WatchTransferManifestIdentity { identity }

  public init(
    identity: WatchTransferManifestIdentity,
    fileCount: Int,
    totalByteCount: Int64,
    expectsCover: Bool = false
  ) {
    self.identity = identity
    self.fileCount = fileCount
    self.totalByteCount = totalByteCount
    self.expectsCover = expectsCover
  }

  public init(manifest: WatchTransferManifest) {
    let coverByteCount = manifest.expectsCover ? (manifest.expectedCoverByteCount ?? 0) : 0
    self.init(
      identity: WatchTransferManifestIdentity(manifest: manifest),
      fileCount: manifest.tracks.count + (manifest.expectsCover ? 1 : 0),
      totalByteCount: manifest.tracks.reduce(0) { $0 + max(0, $1.byteCount) } + coverByteCount,
      expectsCover: manifest.expectsCover
    )
  }
}

/// Identity for one manifest, cover, thumbnail, or track file.
public struct WatchTransferFileIdentity: Codable, Equatable, Hashable, Sendable, Identifiable {
  public enum Kind: String, Codable, Equatable, Hashable, Sendable {
    case manifest
    case cover
    case thumbnail
    case track

    public init(_ kind: WatchTransferFileMetadata.Kind) {
      switch kind {
      case .manifest: self = .manifest
      case .cover: self = .cover
      case .thumbnail: self = .thumbnail
      case .track: self = .track
      }
    }

    public var metadataKind: WatchTransferFileMetadata.Kind {
      switch self {
      case .manifest: return .manifest
      case .cover: return .cover
      case .thumbnail: return .thumbnail
      case .track: return .track
      }
    }
  }

  public let transferID: String
  public let bookID: String
  public let kind: Kind
  public let trackIndex: Int?
  public let chunkIndex: Int?

  public var id: String {
    [
      transferID,
      bookID,
      kind.rawValue,
      trackIndex.map(String.init) ?? "-",
      chunkIndex.map(String.init) ?? "-",
    ].joined(separator: "/")
  }

  public init(
    transferID: String,
    bookID: String,
    kind: Kind,
    trackIndex: Int? = nil,
    chunkIndex: Int? = nil
  ) {
    self.transferID = transferID
    self.bookID = bookID
    self.kind = kind
    self.trackIndex = trackIndex
    self.chunkIndex = chunkIndex
  }

  public init(
    identity: WatchTransferManifestIdentity,
    kind: Kind,
    trackIndex: Int? = nil,
    chunkIndex: Int? = nil
  ) {
    self.init(
      transferID: identity.transferID,
      bookID: identity.bookID,
      kind: kind,
      trackIndex: trackIndex,
      chunkIndex: chunkIndex
    )
  }

  public init(metadata: WatchTransferFileMetadata) {
    self.init(
      transferID: metadata.transferID,
      bookID: metadata.bookID,
      kind: Kind(metadata.kind),
      trackIndex: metadata.trackIndex,
      chunkIndex: metadata.chunkIndex
    )
  }

  public static func manifest(transferID: String, bookID: String) -> Self {
    Self(transferID: transferID, bookID: bookID, kind: .manifest)
  }

  public static func cover(transferID: String, bookID: String) -> Self {
    Self(transferID: transferID, bookID: bookID, kind: .cover)
  }

  public static func thumbnail(bookID: String) -> Self {
    Self(transferID: "catalog", bookID: bookID, kind: .thumbnail)
  }

  public static func track(transferID: String, bookID: String, trackIndex: Int) -> Self {
    Self(
      transferID: transferID,
      bookID: bookID,
      kind: .track,
      trackIndex: trackIndex
    )
  }
}

/// The digest and byte count expected for a file payload.
public struct WatchTransferIntegrity: Codable, Equatable, Hashable, Sendable {
  public enum Algorithm: String, Codable, Equatable, Sendable {
    case sha256
  }

  public let algorithm: Algorithm
  public let digest: String
  public let byteCount: Int64

  public init(
    algorithm: Algorithm = .sha256,
    digest: String,
    byteCount: Int64
  ) {
    self.algorithm = algorithm
    self.digest = digest
    self.byteCount = byteCount
  }

  public init(sha256: String, byteCount: Int64) {
    self.init(algorithm: .sha256, digest: sha256, byteCount: byteCount)
  }

  public init(data: Data) {
    self.init(sha256: Self.digest(for: data), byteCount: Int64(data.count))
  }

  public var sha256: String? {
    algorithm == .sha256 ? digest : nil
  }

  public static func digest(for data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public func matches(_ data: Data) -> Bool {
    validate(data: data) == nil
  }

  public func validate(data: Data) -> WatchTransferValidationError? {
    guard byteCount >= 0, !digest.isEmpty else { return .invalidDescriptor }
    guard Int64(data.count) == byteCount else {
      return .sizeMismatch(expected: byteCount, actual: Int64(data.count))
    }

    let actualDigest = Self.digest(for: data)
    guard actualDigest.caseInsensitiveCompare(digest) == .orderedSame else {
      return .digestMismatch(expected: digest, actual: actualDigest)
    }
    return nil
  }
}

/// Description of one file in a relay transfer. A descriptor contains no URL or credentials.
public struct WatchTransferFileDescriptor: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let identity: WatchTransferFileIdentity
  public let byteCount: Int64
  public let chunkCount: Int
  public let chunkByteCounts: [Int64]?
  public let integrity: WatchTransferIntegrity?

  public var id: String { identity.id }
  public var transferID: String { identity.transferID }
  public var bookID: String { identity.bookID }

  public init(
    identity: WatchTransferFileIdentity,
    byteCount: Int64,
    chunkCount: Int = 1,
    chunkByteCounts: [Int64]? = nil,
    integrity: WatchTransferIntegrity? = nil
  ) {
    self.identity = identity
    self.byteCount = byteCount
    self.chunkCount = chunkCount
    self.chunkByteCounts = chunkByteCounts
    self.integrity = integrity
  }

  public init(
    identity: WatchTransferFileIdentity,
    byteCount: Int64,
    chunkCount: Int = 1,
    chunkByteCounts: [Int64]? = nil,
    sha256: String
  ) {
    self.init(
      identity: identity,
      byteCount: byteCount,
      chunkCount: chunkCount,
      chunkByteCounts: chunkByteCounts,
      integrity: WatchTransferIntegrity(sha256: sha256, byteCount: byteCount)
    )
  }

  public var isWellFormed: Bool {
    guard byteCount >= 0, chunkCount > 0 else { return false }
    guard let chunkByteCounts else {
      return integrity?.byteCount == byteCount || integrity == nil
    }
    return chunkByteCounts.count == chunkCount
      && chunkByteCounts.allSatisfy { $0 >= 0 }
      && chunkByteCounts.reduce(0, +) == byteCount
      && (integrity?.byteCount == byteCount || integrity == nil)
  }

  public func expectedChunkByteCount(for index: Int) -> Int64? {
    guard let chunkByteCounts, chunkByteCounts.indices.contains(index) else { return nil }
    return chunkByteCounts[index]
  }

  public func expectedChunkByteOffset(for index: Int) -> Int64? {
    guard let chunkByteCounts, chunkByteCounts.indices.contains(index) else { return nil }
    return chunkByteCounts.prefix(index).reduce(0, +)
  }

  public func validate(data: Data) -> WatchTransferValidationError? {
    guard isWellFormed else { return .invalidDescriptor }
    guard Int64(data.count) == byteCount else {
      return .sizeMismatch(expected: byteCount, actual: Int64(data.count))
    }
    return integrity?.validate(data: data)
  }

  public func isValid(data: Data) -> Bool {
    validate(data: data) == nil
  }

  public func validate(
    chunkData: Data,
    chunkIndex: Int,
    byteOffset: Int64
  ) -> WatchTransferValidationError? {
    guard isWellFormed else { return .invalidDescriptor }
    guard (0..<chunkCount).contains(chunkIndex) else {
      return .invalidChunkIndex(chunkIndex)
    }
    guard byteOffset >= 0, byteOffset <= byteCount else {
      return .chunkOffsetMismatch(expected: 0, actual: byteOffset)
    }
    guard Int64(chunkData.count) <= byteCount - byteOffset else {
      return .sizeMismatch(expected: byteCount - byteOffset, actual: Int64(chunkData.count))
    }

    if let expectedByteCount = expectedChunkByteCount(for: chunkIndex) {
      guard Int64(chunkData.count) == expectedByteCount else {
        return .chunkSizeMismatch(expected: expectedByteCount, actual: Int64(chunkData.count))
      }
      if let expectedOffset = expectedChunkByteOffset(for: chunkIndex), byteOffset != expectedOffset {
        return .chunkOffsetMismatch(expected: expectedOffset, actual: byteOffset)
      }
    }
    return nil
  }
}

/// A request for one missing file chunk.
public struct WatchTransferChunkRequest: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let file: WatchTransferFileIdentity
  public let chunkIndex: Int

  public var id: String { "\(file.id)#\(chunkIndex)" }
  public var identity: WatchTransferFileIdentity { file }

  public init(file: WatchTransferFileIdentity, chunkIndex: Int) {
    self.file = file
    self.chunkIndex = chunkIndex
  }

  public init(identity: WatchTransferFileIdentity, chunkIndex: Int) {
    self.init(file: identity, chunkIndex: chunkIndex)
  }
}

/// A response or relay envelope carrying one requested chunk.
public struct WatchTransferChunkResponse: Codable, Equatable, Sendable {
  public let request: WatchTransferChunkRequest
  public let byteOffset: Int64
  public let data: Data

  public var file: WatchTransferFileIdentity { request.file }
  public var chunkIndex: Int { request.chunkIndex }
  public var payload: Data { data }
  public var byteCount: Int64 { Int64(data.count) }

  public init(
    request: WatchTransferChunkRequest,
    byteOffset: Int64,
    data: Data
  ) {
    self.request = request
    self.byteOffset = byteOffset
    self.data = data
  }

  public init(
    file: WatchTransferFileIdentity,
    chunkIndex: Int,
    byteOffset: Int64,
    data: Data
  ) {
    self.init(
      request: WatchTransferChunkRequest(file: file, chunkIndex: chunkIndex),
      byteOffset: byteOffset,
      data: data
    )
  }

  public func validate(against descriptor: WatchTransferFileDescriptor) -> WatchTransferValidationError? {
    guard descriptor.identity == file else { return .fileIdentityMismatch }
    return descriptor.validate(
      chunkData: data,
      chunkIndex: chunkIndex,
      byteOffset: byteOffset
    )
  }
}

public typealias WatchTransferChunkEnvelope = WatchTransferChunkResponse

/// Persisted receive state for one file. The byte map makes duplicate chunks idempotent.
public struct WatchTransferFileReceiveState: Codable, Equatable, Sendable, Identifiable {
  public let file: WatchTransferFileIdentity
  public let expectedByteCount: Int64
  public let expectedChunkCount: Int
  public private(set) var receivedByteCount: Int64
  public private(set) var receivedChunkByteCounts: [Int: Int64]

  public var id: String { file.id }
  public var receivedChunkIndexes: [Int] { receivedChunkByteCounts.keys.sorted() }
  public var missingChunkIndexes: [Int] {
    WatchTransferResumeSelector.missingChunkIndexes(
      expectedChunkCount: expectedChunkCount,
      receivedChunkIndexes: Set(receivedChunkByteCounts.keys)
    )
  }
  public var missingChunks: [Int] { missingChunkIndexes }
  public var isComplete: Bool {
    validate() == nil
      && receivedChunkByteCounts.count == expectedChunkCount
      && receivedByteCount == expectedByteCount
  }
  public var byteProgress: WatchTransferByteProgress {
    WatchTransferByteProgress(
      receivedByteCount: receivedByteCount,
      totalByteCount: expectedByteCount
    )
  }
  public var progress: Double { byteProgress.fraction }

  public init(
    file: WatchTransferFileIdentity,
    expectedByteCount: Int64,
    expectedChunkCount: Int,
    receivedByteCount: Int64 = 0,
    receivedChunkIndexes: Set<Int> = []
  ) {
    self.file = file
    self.expectedByteCount = expectedByteCount
    self.expectedChunkCount = expectedChunkCount
    self.receivedByteCount = receivedByteCount
    self.receivedChunkByteCounts = Dictionary(
      uniqueKeysWithValues: receivedChunkIndexes.map { ($0, 0) }
    )
  }

  public init(
    file: WatchTransferFileIdentity,
    expectedByteCount: Int64,
    expectedChunkCount: Int,
    receivedChunkByteCounts: [Int: Int64]
  ) {
    self.file = file
    self.expectedByteCount = expectedByteCount
    self.expectedChunkCount = expectedChunkCount
    self.receivedChunkByteCounts = receivedChunkByteCounts
    self.receivedByteCount = receivedChunkByteCounts.values.reduce(0, +)
  }

  /// Records a chunk once. A repeated chunk is accepted only with the same size.
  @discardableResult
  public mutating func recordChunk(index: Int, byteCount: Int64) -> Bool {
    guard (0..<expectedChunkCount).contains(index), byteCount >= 0 else { return false }
    if let existingByteCount = receivedChunkByteCounts[index] {
      return existingByteCount == byteCount
    }
    guard receivedByteCount <= expectedByteCount,
      byteCount <= expectedByteCount - receivedByteCount
    else { return false }

    receivedChunkByteCounts[index] = byteCount
    receivedByteCount += byteCount
    return true
  }

  @discardableResult
  public mutating func record(
    _ response: WatchTransferChunkResponse,
    descriptor: WatchTransferFileDescriptor
  ) -> WatchTransferValidationError? {
    guard response.file == file else { return .fileIdentityMismatch }
    if let validationError = response.validate(against: descriptor) {
      return validationError
    }
    guard recordChunk(index: response.chunkIndex, byteCount: response.byteCount) else {
      return .invalidReceivedState
    }
    return nil
  }

  public func validate() -> WatchTransferValidationError? {
    guard expectedByteCount >= 0, expectedChunkCount > 0 else {
      return .invalidDescriptor
    }
    guard receivedByteCount >= 0, receivedByteCount <= expectedByteCount else {
      return .invalidReceivedState
    }
    for (index, byteCount) in receivedChunkByteCounts {
      guard (0..<expectedChunkCount).contains(index), byteCount >= 0 else {
        return .invalidReceivedState
      }
    }
    guard receivedChunkByteCounts.values.reduce(0, +) == receivedByteCount else {
      return .invalidReceivedState
    }
    return nil
  }
}

public typealias WatchTransferFileState = WatchTransferFileReceiveState
public typealias WatchTransferFileReceipt = WatchTransferFileReceiveState

/// Persisted receive state for all files in one transfer.
public struct WatchTransferReceiveState: Codable, Equatable, Sendable, Identifiable {
  public let identity: WatchTransferManifestIdentity
  public private(set) var files: [WatchTransferFileReceiveState]

  public var id: String { identity.id }
  public var receivedByteCount: Int64 { files.reduce(0) { $0 + max(0, $1.receivedByteCount) } }
  public var totalByteCount: Int64 { files.reduce(0) { $0 + max(0, $1.expectedByteCount) } }
  public var byteProgress: WatchTransferByteProgress {
    WatchTransferByteProgress(
      receivedByteCount: receivedByteCount,
      totalByteCount: totalByteCount
    )
  }
  public var progress: Double { byteProgress.fraction }
  public var isComplete: Bool { !files.isEmpty && files.allSatisfy(\.isComplete) }

  public init(
    identity: WatchTransferManifestIdentity,
    files: [WatchTransferFileReceiveState]
  ) {
    self.identity = identity
    self.files = files
  }

  public func state(for file: WatchTransferFileIdentity) -> WatchTransferFileReceiveState? {
    files.first { $0.file == file }
  }

  public func missingChunkRequests(limit: Int? = nil) -> [WatchTransferChunkRequest] {
    let requests =
      files
      .sorted { $0.file.id < $1.file.id }
      .flatMap { state in
        state.missingChunkIndexes.map {
          WatchTransferChunkRequest(file: state.file, chunkIndex: $0)
        }
      }
    guard let limit else { return requests }
    return Array(requests.prefix(max(0, limit)))
  }

  @discardableResult
  public mutating func record(
    _ response: WatchTransferChunkResponse,
    descriptor: WatchTransferFileDescriptor
  ) -> WatchTransferValidationError? {
    guard let fileIndex = files.firstIndex(where: { $0.file == response.file }) else {
      return .fileIdentityMismatch
    }
    return files[fileIndex].record(response, descriptor: descriptor)
  }
}

public typealias WatchTransferResumeState = WatchTransferReceiveState

/// Chooses only chunks that are absent from persisted receive state.
public enum WatchTransferResumeSelector {
  public static func missingChunkIndexes(
    expectedChunkCount: Int,
    receivedChunkIndexes: Set<Int>
  ) -> [Int] {
    guard expectedChunkCount > 0 else { return [] }
    return (0..<expectedChunkCount).filter { !receivedChunkIndexes.contains($0) }
  }

  public static func missingChunkIndexes(
    expectedChunkCount: Int,
    receivedChunkIndexes: [Int]
  ) -> [Int] {
    missingChunkIndexes(
      expectedChunkCount: expectedChunkCount,
      receivedChunkIndexes: Set(receivedChunkIndexes)
    )
  }

  public static func nextMissingChunkIndex(
    expectedChunkCount: Int,
    receivedChunkIndexes: Set<Int>
  ) -> Int? {
    missingChunkIndexes(
      expectedChunkCount: expectedChunkCount,
      receivedChunkIndexes: receivedChunkIndexes
    ).first
  }

  public static func requests(
    for file: WatchTransferFileIdentity,
    expectedChunkCount: Int,
    receivedChunkIndexes: Set<Int>,
    limit: Int? = nil
  ) -> [WatchTransferChunkRequest] {
    let indexes = missingChunkIndexes(
      expectedChunkCount: expectedChunkCount,
      receivedChunkIndexes: receivedChunkIndexes
    )
    guard let limit else {
      return indexes.map { WatchTransferChunkRequest(file: file, chunkIndex: $0) }
    }
    return indexes.prefix(max(0, limit)).map {
      WatchTransferChunkRequest(file: file, chunkIndex: $0)
    }
  }
}

/// Byte-based progress shared by sender and receiver.
public struct WatchTransferByteProgress: Codable, Equatable, Sendable {
  public let receivedByteCount: Int64
  public let totalByteCount: Int64

  public var fraction: Double {
    guard totalByteCount > 0 else { return receivedByteCount == 0 ? 1 : 0 }
    return min(1, max(0, Double(receivedByteCount) / Double(totalByteCount)))
  }
  public var progress: Double { fraction }
  public var isComplete: Bool { receivedByteCount >= totalByteCount }

  public init(receivedByteCount: Int64, totalByteCount: Int64) {
    self.receivedByteCount = max(0, receivedByteCount)
    self.totalByteCount = max(0, totalByteCount)
  }
}

public typealias WatchTransferProgress = WatchTransferByteProgress

public extension WatchTransferManifest {
  var manifestIdentity: WatchTransferManifestIdentity {
    WatchTransferManifestIdentity(manifest: self)
  }

  var transferOffer: WatchTransferOffer {
    WatchTransferOffer(manifest: self)
  }

  var fileDescriptors: [WatchTransferFileDescriptor] {
    var descriptors = tracks.map { track in
      WatchTransferFileDescriptor(
        identity: .track(
          transferID: transferID,
          bookID: bookID,
          trackIndex: track.index
        ),
        byteCount: track.byteCount,
        chunkCount: track.transferChunkCount
      )
    }
    if expectsCover, let expectedCoverByteCount {
      descriptors.append(
        WatchTransferFileDescriptor(
          identity: .cover(transferID: transferID, bookID: bookID),
          byteCount: expectedCoverByteCount
        )
      )
    }
    return descriptors
  }
}

public extension WatchTransferManifest.Track {
  func fileDescriptor(
    identity: WatchTransferFileIdentity,
    integrity: WatchTransferIntegrity? = nil,
    chunkByteCounts: [Int64]? = nil
  ) -> WatchTransferFileDescriptor {
    WatchTransferFileDescriptor(
      identity: identity,
      byteCount: byteCount,
      chunkCount: transferChunkCount,
      chunkByteCounts: chunkByteCounts,
      integrity: integrity
    )
  }
}

public enum WatchTransferValidationError: Error, Equatable, Sendable {
  case invalidDescriptor
  case invalidChunkIndex(Int)
  case fileIdentityMismatch
  case sizeMismatch(expected: Int64, actual: Int64)
  case chunkSizeMismatch(expected: Int64, actual: Int64)
  case chunkOffsetMismatch(expected: Int64, actual: Int64)
  case digestMismatch(expected: String, actual: String)
  case invalidReceivedState
}

/// The public, credential-free description of one track in a temporary share.
public struct WatchShareTrackDescriptor: Codable, Equatable, Hashable, Sendable, Identifiable {
  public let index: Int
  public let byteCount: Int64
  public let fileExtension: String
  public let integrity: WatchTransferIntegrity?

  public var id: Int { index }

  public init(
    index: Int,
    byteCount: Int64,
    fileExtension: String,
    integrity: WatchTransferIntegrity? = nil
  ) {
    self.index = index
    self.byteCount = byteCount
    self.fileExtension = fileExtension
    self.integrity = integrity
  }

  public init(
    index: Int,
    byteCount: Int64,
    fileExtension: String,
    sha256: String
  ) {
    self.init(
      index: index,
      byteCount: byteCount,
      fileExtension: fileExtension,
      integrity: WatchTransferIntegrity(sha256: sha256, byteCount: byteCount)
    )
  }

  public var isWellFormed: Bool {
    index >= 0
      && byteCount >= 0
      && !fileExtension.isEmpty
      && !fileExtension.contains("/")
      && !fileExtension.contains("\\")
      && (integrity == nil || integrity?.byteCount == byteCount)
  }

  public func validate(data: Data) -> WatchTransferValidationError? {
    guard isWellFormed else { return .invalidDescriptor }
    guard Int64(data.count) == byteCount else {
      return .sizeMismatch(expected: byteCount, actual: Int64(data.count))
    }
    return integrity?.validate(data: data)
  }

  public func isValid(data: Data) -> Bool {
    validate(data: data) == nil
  }
}

public enum WatchShareOfferValidationError: Error, Equatable, Sendable {
  case emptyIdentifier
  case invalidBootstrapURL
  case nonHTTPSBootstrapURL
  case privateOrTailscaleBootstrapAddress
  case bootstrapURLContainsCredentials
  case bootstrapURLContainsQuery
  case bootstrapURLContainsFragment
  case expired
  case unboundedExpiry
  case invalidReplacementGeneration
  case noTracks
  case duplicateTrackIndex(Int)
  case invalidTrack(Int)
}

private enum WatchShareBootstrapURLValidator {
  static func validate(_ url: URL) -> WatchShareOfferValidationError? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      !host.isEmpty
    else {
      return .invalidBootstrapURL
    }

    guard scheme == "https" else { return .nonHTTPSBootstrapURL }
    guard components.user == nil, components.password == nil else {
      return .bootstrapURLContainsCredentials
    }
    guard components.query == nil else { return .bootstrapURLContainsQuery }
    guard components.fragment == nil else { return .bootstrapURLContainsFragment }
    guard !isPrivateOrTailscaleAddress(host) else {
      return .privateOrTailscaleBootstrapAddress
    }
    return nil
  }

  private static func isPrivateOrTailscaleAddress(_ host: String) -> Bool {
    let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmedDot
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
      return true
    }

    // URLComponents leaves IPv6 literals containing colons. Rejecting all literal
    // IPv6 addresses keeps the public contract hostname-based and avoids local ranges.
    if host.contains(":") { return true }

    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    let values = octets.compactMap { Int($0) }
    guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else {
      return false
    }

    switch values {
    case let values where values[0] == 0 || values[0] == 10 || values[0] == 127:
      return true
    case let values where values[0] == 100 && (64...127).contains(values[1]):
      return true  // RFC 6598, including Tailscale's 100.64.0.0/10 addresses.
    case let values where values[0] == 169 && values[1] == 254:
      return true
    case let values where values[0] == 172 && (16...31).contains(values[1]):
      return true
    case let values where values[0] == 192 && values[1] == 168:
      return true
    default:
      return false
    }
  }
}

private extension String {
  var trimmedDot: String {
    hasSuffix(".") ? String(dropLast()) : self
  }
}

/// A temporary public Audiobookshelf share. The URL is the public bootstrap URL,
/// which may contain a hostname and server base path but never credentials or headers.
public struct WatchShareOffer: Codable, Equatable, Sendable, Identifiable {
  /// Shares live for at most one week in the client contract.
  public static let maximumLifetime: TimeInterval = 7 * 24 * 60 * 60

  public let transferID: String
  public let bookID: String
  public let shareID: String
  public let publicBootstrapURL: URL
  public let expiresAt: Date
  public let tracks: [WatchShareTrackDescriptor]
  public let replacementGeneration: Int

  public var id: String { transferID }
  public var bootstrapURL: URL { publicBootstrapURL }
  public var expectedTrackIndexes: [Int] { tracks.map(\.index) }

  public init(
    transferID: String,
    bookID: String,
    shareID: String,
    publicBootstrapURL: URL,
    expiresAt: Date,
    tracks: [WatchShareTrackDescriptor],
    replacementGeneration: Int = 0
  ) {
    self.transferID = transferID
    self.bookID = bookID
    self.shareID = shareID
    self.publicBootstrapURL = publicBootstrapURL
    self.expiresAt = expiresAt
    self.tracks = tracks.sorted { $0.index < $1.index }
    self.replacementGeneration = replacementGeneration
  }

  public var isExpired: Bool { isExpired(at: Date()) }

  public func isExpired(at date: Date) -> Bool {
    date >= expiresAt
  }

  public func validationError(at date: Date = Date()) -> WatchShareOfferValidationError? {
    guard !transferID.isEmpty, !bookID.isEmpty, !shareID.isEmpty else {
      return .emptyIdentifier
    }
    if let urlError = WatchShareBootstrapURLValidator.validate(publicBootstrapURL) {
      return urlError
    }
    guard expiresAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970 > 0 else {
      return .unboundedExpiry
    }
    let lifetime = expiresAt.timeIntervalSince(date)
    guard lifetime > 0 else { return .expired }
    guard lifetime <= Self.maximumLifetime else { return .unboundedExpiry }
    guard replacementGeneration >= 0 else { return .invalidReplacementGeneration }
    guard !tracks.isEmpty else { return .noTracks }

    var indexes = Set<Int>()
    for track in tracks {
      guard track.isWellFormed else { return .invalidTrack(track.index) }
      guard indexes.insert(track.index).inserted else {
        return .duplicateTrackIndex(track.index)
      }
    }
    return nil
  }

  public func isValid(at date: Date = Date()) -> Bool {
    validationError(at: date) == nil
  }

  /// Replaces only the public share. Completed tracks can be reused when their
  /// descriptor is unchanged, while partial ranges are discarded by the lifecycle.
  public func replacing(
    shareID: String,
    publicBootstrapURL: URL,
    expiresAt: Date,
    tracks: [WatchShareTrackDescriptor]? = nil
  ) -> Self {
    Self(
      transferID: transferID,
      bookID: bookID,
      shareID: shareID,
      publicBootstrapURL: publicBootstrapURL,
      expiresAt: expiresAt,
      tracks: tracks ?? self.tracks,
      replacementGeneration: replacementGeneration + 1
    )
  }
}

/// The server validators and contiguous prefix needed to resume one track with a range request.
public struct WatchShareResumeMetadata: Codable, Equatable, Sendable {
  public let receivedByteCount: Int64
  public let totalByteCount: Int64
  public let entityTag: String?
  public let lastModified: Date?

  public var isPartial: Bool {
    receivedByteCount > 0 && receivedByteCount < totalByteCount
  }

  public var rangeHeader: String? {
    guard isPartial else { return nil }
    return "bytes=\(receivedByteCount)-"
  }

  public init(
    receivedByteCount: Int64,
    totalByteCount: Int64,
    entityTag: String? = nil,
    lastModified: Date? = nil
  ) {
    self.receivedByteCount = receivedByteCount
    self.totalByteCount = totalByteCount
    self.entityTag = entityTag
    self.lastModified = lastModified
  }

  public func validationError(
    against track: WatchShareTrackDescriptor
  ) -> WatchTransferValidationError? {
    guard
      track.isWellFormed,
      totalByteCount == track.byteCount,
      receivedByteCount >= 0,
      receivedByteCount <= totalByteCount
    else {
      return .invalidDescriptor
    }
    return nil
  }
}

public enum WatchShareTrackReceiptState: String, Codable, Equatable, Sendable {
  case partial
  case completed
}

public enum WatchShareReceiptResult: String, Codable, Equatable, Sendable {
  case accepted
  case duplicate
  case rejected
}

/// A persisted receipt for one public track. A completed receipt is safe to reuse
/// after share replacement only when its descriptor still matches.
public struct WatchShareTrackReceipt: Codable, Equatable, Sendable, Identifiable {
  public let track: WatchShareTrackDescriptor
  public let replacementGeneration: Int
  public private(set) var state: WatchShareTrackReceiptState
  public private(set) var resumeMetadata: WatchShareResumeMetadata?

  public var id: Int { track.index }
  public var trackIndex: Int { track.index }
  public var isComplete: Bool { state == .completed }

  fileprivate init(
    track: WatchShareTrackDescriptor,
    state: WatchShareTrackReceiptState,
    resumeMetadata: WatchShareResumeMetadata?,
    replacementGeneration: Int
  ) {
    self.track = track
    self.state = state
    self.resumeMetadata = resumeMetadata
    self.replacementGeneration = replacementGeneration
  }
}

public enum WatchShareLifecycleState: String, Codable, Equatable, Sendable {
  case offered
  case bootstrapping
  case downloading
  case completed
  case expired
  case cancelled
  case failed

  public var isTerminal: Bool {
    switch self {
    case .completed, .expired, .cancelled, .failed: return true
    case .offered, .bootstrapping, .downloading: return false
    }
  }
}

/// The cleanup work an authenticated iPhone may perform after a terminal job.
/// It contains identifiers only. It never carries the URL, a token, or headers.
public struct WatchShareCleanup: Codable, Equatable, Sendable {
  public let transferID: String
  public let bookID: String
  public let shareID: String
  public let removeActiveURL: Bool
  public let revokeShare: Bool
  public let removePartialTrackFiles: Bool
  public let retainValidatedTrackFiles: Bool

  public init(
    transferID: String,
    bookID: String,
    shareID: String,
    removeActiveURL: Bool = true,
    revokeShare: Bool = true,
    removePartialTrackFiles: Bool,
    retainValidatedTrackFiles: Bool = true
  ) {
    self.transferID = transferID
    self.bookID = bookID
    self.shareID = shareID
    self.removeActiveURL = removeActiveURL
    self.revokeShare = revokeShare
    self.removePartialTrackFiles = removePartialTrackFiles
    self.retainValidatedTrackFiles = retainValidatedTrackFiles
  }
}

/// Pure persisted state for one temporary-share download.
public struct WatchShareLifecycle: Codable, Equatable, Sendable, Identifiable {
  public let transferID: String
  public let bookID: String
  public private(set) var state: WatchShareLifecycleState
  public private(set) var activeOffer: WatchShareOffer?
  public private(set) var lastShareID: String
  public private(set) var replacementGeneration: Int
  public private(set) var receipts: [WatchShareTrackReceipt]

  public var id: String { transferID }
  public var activeURL: URL? { activeOffer?.publicBootstrapURL }
  public var completedTrackIndexes: [Int] {
    receipts.filter(\.isComplete).map(\.trackIndex).sorted()
  }
  public var missingTrackIndexes: [Int] {
    guard let activeOffer else { return [] }
    let completed = Set(completedTrackIndexes)
    return activeOffer.tracks.map(\.index).filter { !completed.contains($0) }
  }
  public var isComplete: Bool {
    guard let activeOffer else { return false }
    return !activeOffer.tracks.isEmpty && missingTrackIndexes.isEmpty
  }
  public var reusableCompletedTrackIndexes: [Int] {
    guard let activeOffer else { return [] }
    let receiptsByIndex = Dictionary(uniqueKeysWithValues: receipts.map { ($0.trackIndex, $0) })
    return activeOffer.tracks.compactMap { track in
      guard let receipt = receiptsByIndex[track.index], receipt.isComplete,
        receipt.track == track
      else { return nil }
      return track.index
    }
  }
  public var cleanupPlan: WatchShareCleanup? {
    guard state.isTerminal else { return nil }
    return WatchShareCleanup(
      transferID: transferID,
      bookID: bookID,
      shareID: lastShareID,
      removePartialTrackFiles: state != .completed,
      retainValidatedTrackFiles: state == .completed
    )
  }

  public init(offer: WatchShareOffer) {
    self.transferID = offer.transferID
    self.bookID = offer.bookID
    self.state = .offered
    self.activeOffer = offer
    self.lastShareID = offer.shareID
    self.replacementGeneration = offer.replacementGeneration
    self.receipts = []
  }

  public mutating func beginBootstrap(at date: Date = Date()) -> Bool {
    guard state == .offered, let activeOffer, activeOffer.isValid(at: date) else { return false }
    state = .bootstrapping
    return true
  }

  public mutating func beginDownload(at date: Date = Date()) -> Bool {
    guard state == .offered || state == .bootstrapping,
      let activeOffer,
      activeOffer.isValid(at: date)
    else { return false }
    state = .downloading
    return true
  }

  @discardableResult
  public mutating func recordPartialRange(
    index: Int,
    metadata: WatchShareResumeMetadata
  ) -> WatchShareReceiptResult {
    guard let activeOffer, !state.isTerminal,
      let track = activeOffer.tracks.first(where: { $0.index == index }),
      metadata.validationError(against: track) == nil
    else { return .rejected }

    if let receiptIndex = receipts.firstIndex(where: { $0.trackIndex == index }) {
      let existing = receipts[receiptIndex]
      guard existing.track == track else { return .rejected }
      guard !existing.isComplete else { return .duplicate }
      guard let existingMetadata = existing.resumeMetadata else { return .rejected }
      guard existingMetadata.entityTag == metadata.entityTag,
        existingMetadata.lastModified == metadata.lastModified
      else { return .rejected }
      guard metadata.receivedByteCount >= existingMetadata.receivedByteCount else {
        return .rejected
      }
      if existingMetadata == metadata { return .duplicate }
      receipts[receiptIndex] = WatchShareTrackReceipt(
        track: track,
        state: .partial,
        resumeMetadata: metadata,
        replacementGeneration: replacementGeneration
      )
      state = .downloading
      return .accepted
    }

    receipts.append(
      WatchShareTrackReceipt(
        track: track,
        state: .partial,
        resumeMetadata: metadata,
        replacementGeneration: replacementGeneration
      )
    )
    receipts.sort { $0.trackIndex < $1.trackIndex }
    state = .downloading
    return .accepted
  }

  @discardableResult
  public mutating func recordValidatedTrack(
    index: Int,
    data: Data
  ) -> WatchShareReceiptResult {
    guard let activeOffer, !state.isTerminal,
      let track = activeOffer.tracks.first(where: { $0.index == index }),
      track.validate(data: data) == nil
    else { return .rejected }

    if let receiptIndex = receipts.firstIndex(where: { $0.trackIndex == index }) {
      let existing = receipts[receiptIndex]
      guard existing.track == track else { return .rejected }
      if existing.isComplete { return .duplicate }
      receipts[receiptIndex] = WatchShareTrackReceipt(
        track: track,
        state: .completed,
        resumeMetadata: nil,
        replacementGeneration: replacementGeneration
      )
    } else {
      receipts.append(
        WatchShareTrackReceipt(
          track: track,
          state: .completed,
          resumeMetadata: nil,
          replacementGeneration: replacementGeneration
        )
      )
      receipts.sort { $0.trackIndex < $1.trackIndex }
    }
    state = .downloading
    return .accepted
  }

  @discardableResult
  public mutating func markCompleted() -> Bool {
    guard isComplete, !state.isTerminal else { return false }
    state = .completed
    activeOffer = nil
    return true
  }

  @discardableResult
  public mutating func markExpired(at date: Date = Date()) -> Bool {
    guard let activeOffer, activeOffer.isExpired(at: date), !state.isTerminal else {
      return false
    }
    state = .expired
    self.activeOffer = nil
    receipts.removeAll { !$0.isComplete }
    return true
  }

  @discardableResult
  public mutating func replace(
    with offer: WatchShareOffer,
    at date: Date = Date()
  ) -> Bool {
    guard state == .expired || state == .failed,
      offer.transferID == transferID,
      offer.bookID == bookID,
      offer.replacementGeneration == replacementGeneration + 1,
      offer.isValid(at: date)
    else { return false }

    activeOffer = offer
    lastShareID = offer.shareID
    replacementGeneration = offer.replacementGeneration
    receipts.removeAll { !$0.isComplete }
    state = .offered
    return true
  }

  public mutating func fail() {
    guard !state.isTerminal else { return }
    state = .failed
    activeOffer = nil
    receipts.removeAll { !$0.isComplete }
  }

  @discardableResult
  public mutating func cancel() -> WatchShareCleanup {
    if state != .completed {
      state = .cancelled
      activeOffer = nil
      receipts.removeAll()
    }
    return cleanupPlan!
  }
}

// Names with the transfer prefix keep the new contracts discoverable beside the
// existing relay contracts without changing those relay types.
public typealias WatchTransferShareOffer = WatchShareOffer
public typealias WatchTransferShareTrackDescriptor = WatchShareTrackDescriptor
public typealias WatchTransferShareLifecycle = WatchShareLifecycle

/// Pure planning for segmented ranged downloads of one public-share track.
///
/// Hardware evidence showed a single monolithic background download task is
/// deferred when the Watch display sleeps. Splitting a track into bounded
/// HTTP-range segments keeps each unit small enough for watchOS to complete,
/// makes progress observable per segment, and lets completed segments be
/// reused across relaunches.
public enum WatchShareSegmentPlanner {
  public static let defaultSegmentByteCount: Int64 = 16 * 1024 * 1024

  public struct Segment: Equatable, Sendable {
    public let index: Int
    public let startOffset: Int64
    public let byteCount: Int64

    public init(index: Int, startOffset: Int64, byteCount: Int64) {
      self.index = index
      self.startOffset = startOffset
      self.byteCount = byteCount
    }

    /// Inclusive HTTP range header value for this segment.
    public var rangeHeaderValue: String {
      "bytes=\(startOffset)-\(startOffset + byteCount - 1)"
    }
  }

  /// Splits a track into ordered segments. Returns an empty array for invalid
  /// input; callers must treat a zero-byte track specially.
  public static func plan(
    totalByteCount: Int64,
    segmentByteCount: Int64 = defaultSegmentByteCount
  ) -> [Segment] {
    guard totalByteCount > 0, segmentByteCount > 0 else { return [] }

    var segments: [Segment] = []
    var offset: Int64 = 0
    var index = 0
    while offset < totalByteCount {
      let length = min(segmentByteCount, totalByteCount - offset)
      segments.append(Segment(index: index, startOffset: offset, byteCount: length))
      offset += length
      index += 1
    }
    return segments
  }

  /// Selects segments that still need downloading given on-disk segment sizes.
  /// A stored segment counts as complete only when its size matches exactly;
  /// oversized/partial/corrupt segments are re-downloaded.
  public static func missingSegments(
    from plan: [Segment],
    storedSegmentByteCounts: [Int: Int64]
  ) -> [Segment] {
    plan.filter { segment in
      storedSegmentByteCounts[segment.index] != segment.byteCount
    }
  }

  /// Sum of stored segment bytes that exactly match their planned size.
  public static func completedByteCount(
    for plan: [Segment],
    storedSegmentByteCounts: [Int: Int64]
  ) -> Int64 {
    plan.reduce(0) { result, segment in
      storedSegmentByteCounts[segment.index] == segment.byteCount ? result + segment.byteCount : result
    }
  }
}
