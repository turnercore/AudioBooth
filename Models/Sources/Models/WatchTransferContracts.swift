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
  public var isComplete: Bool {
    Set(manifest.tracks.map(\.index)).isSubset(of: receivedIndexes)
      && (!manifest.expectsCover || receivedCover)
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
