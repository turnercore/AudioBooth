import Foundation
import Models
import XCTest

@testable import AudioBooth

@MainActor
final class WatchTransferContractsTests: XCTestCase {
  func testManifestRejectsTracksWithMissingOrMismatchedSources() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let validFile = directory.appendingPathComponent("0.m4a")
    try Data(repeating: 1, count: 4).write(to: validFile)

    let valid = WatchTransferManifest.Track(
      index: 0,
      duration: 12,
      byteCount: 4,
      fileExtension: "m4a"
    )
    let missing = WatchTransferManifest.Track(
      index: 1,
      duration: 13,
      byteCount: 5,
      fileExtension: "m4a"
    )
    let manifest = WatchTransferManifest(
      transferID: "transfer",
      bookID: "book",
      title: "Title",
      authorName: "Author",
      duration: 25,
      tracks: [valid, missing]
    )

    XCTAssertEqual(
      WatchTransferSourceValidator.validate(
        manifest: manifest,
        sources: [
          .init(trackIndex: 0, fileURL: validFile),
          .init(trackIndex: 1, fileURL: directory.appendingPathComponent("missing.m4a")),
        ]
      ),
      .missingSource(trackIndex: 1)
    )

    XCTAssertEqual(
      WatchTransferSourceValidator.validate(
        manifest: manifest,
        sources: [
          .init(trackIndex: 0, fileURL: validFile),
          .init(trackIndex: 1, fileURL: validFile),
        ]
      ),
      .sizeMismatch(trackIndex: 1, expected: 5, actual: 4)
    )
  }

  func testTransferMetadataContainsNoNetworkCredentialsOrURLs() throws {
    let metadata = WatchTransferFileMetadata.trackChunk(
      transferID: "transfer",
      bookID: "book",
      track: .init(index: 2, duration: 20, byteCount: 40, fileExtension: "m4a"),
      chunkIndex: 0,
      byteCount: 40
    )

    let encoded = try JSONEncoder().encode(metadata)
    let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

    XCTAssertFalse(json.localizedCaseInsensitiveContains("authorization"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("token"))
    XCTAssertFalse(json.localizedCaseInsensitiveContains("http"))
    XCTAssertEqual(metadata.kind, .track)
    XCTAssertEqual(metadata.trackIndex, 2)
    XCTAssertEqual(metadata.chunkIndex, 0)
    XCTAssertEqual(metadata.chunkCount, 1)
  }

  func testCatalogThumbnailMetadataContainsNoNetworkLocation() {
    let metadata = WatchTransferFileMetadata.thumbnail(bookID: "book", byteCount: 123)
    let propertyList = WatchFileTransferCoordinator.propertyList(from: metadata)

    XCTAssertEqual(WatchFileTransferCoordinator.metadata(from: propertyList), metadata)
    XCTAssertEqual(metadata.kind, .thumbnail)
    XCTAssertFalse(propertyList.values.contains { "\($0)".localizedCaseInsensitiveContains("http") })
    XCTAssertNil(propertyList["Authorization"])
  }

  func testWatchConnectivityMetadataRoundTripsWithoutCredentialsOrURLs() {
    let metadata = WatchTransferFileMetadata.trackChunk(
      transferID: "transfer",
      bookID: "book",
      track: .init(index: 2, duration: 20, byteCount: 40, fileExtension: "m4a"),
      chunkIndex: 0,
      byteCount: 40
    )

    let propertyList = WatchFileTransferCoordinator.propertyList(from: metadata)

    XCTAssertEqual(WatchFileTransferCoordinator.metadata(from: propertyList), metadata)
    XCTAssertNil(propertyList["Authorization"])
    XCTAssertNil(propertyList["url"])
    XCTAssertFalse(propertyList.values.contains { "\($0)".localizedCaseInsensitiveContains("http") })
  }

  func testManifestPreservesPhonePlaybackPosition() throws {
    let manifest = WatchTransferManifest(
      transferID: "transfer",
      bookID: "book",
      title: "Title",
      authorName: "Author",
      duration: 100,
      currentTime: 42.5,
      tracks: [.init(index: 0, duration: 100, byteCount: 4, fileExtension: ".m4a")]
    )

    let decoded = try JSONDecoder().decode(
      WatchTransferManifest.self,
      from: JSONEncoder().encode(manifest)
    )
    XCTAssertEqual(decoded.currentTime, 42.5)
  }

  func testReceiptIsIdempotentAndCompletesWithOutOfOrderTracks() {
    let manifest = WatchTransferManifest(
      transferID: "transfer",
      bookID: "book",
      title: "Title",
      authorName: "Author",
      duration: 25,
      tracks: [
        .init(index: 0, duration: 12, byteCount: 4, fileExtension: "m4a"),
        .init(index: 1, duration: 13, byteCount: 5, fileExtension: "m4a"),
      ]
    )
    var receipt = WatchTransferReceipt(manifest: manifest)

    receipt.recordReceivedTrack(index: 1)
    receipt.recordReceivedTrack(index: 1)
    XCTAssertEqual(receipt.receivedTrackIndexes, [1])
    XCTAssertFalse(receipt.isComplete)

    receipt.recordReceivedTrack(index: 0)
    XCTAssertEqual(receipt.receivedTrackIndexes, [0, 1])
    XCTAssertTrue(receipt.isComplete)
  }

  func testReceiptDoesNotRequireOptionalCoverForCompletion() {
    let manifest = WatchTransferManifest(
      transferID: "transfer",
      bookID: "book",
      title: "Title",
      authorName: "Author",
      duration: 12,
      tracks: [.init(index: 0, duration: 12, byteCount: 4, fileExtension: "m4a")],
      expectsCover: true
    )
    var receipt = WatchTransferReceipt(manifest: manifest)

    receipt.recordReceivedTrack(index: 0)
    XCTAssertTrue(receipt.isComplete)

    receipt.recordReceivedCover()
    XCTAssertTrue(receipt.isComplete)
  }

  func testWatchRemovalPlanNeverIncludesPhoneSourceFiles() {
    let plan = WatchTransferRemovalPlan(
      bookID: "book",
      watchRelativePaths: ["audiobooks/book/0.m4a", "audiobooks/book/1.m4a"]
    )

    XCTAssertEqual(plan.bookID, "book")
    XCTAssertEqual(plan.watchRelativePaths, ["audiobooks/book/0.m4a", "audiobooks/book/1.m4a"])
    XCTAssertFalse(plan.watchRelativePaths.contains { $0.contains("group.com.turnercore.audioBS") })
  }

  func testMostRecentProgressWinsWithoutReplacingAnEqualTimestamp() {
    let phone = WatchProgressSnapshot(
      bookID: "book",
      currentTime: 10,
      duration: 100,
      updatedAt: Date(timeIntervalSince1970: 100)
    )
    let newerWatch = WatchProgressSnapshot(
      bookID: "book",
      currentTime: 20,
      duration: 100,
      updatedAt: Date(timeIntervalSince1970: 101)
    )
    let equalTimestampWatch = WatchProgressSnapshot(
      bookID: "book",
      currentTime: 30,
      duration: 100,
      updatedAt: Date(timeIntervalSince1970: 100)
    )

    XCTAssertEqual(WatchProgressReconciler.resolve(local: phone, incoming: newerWatch), newerWatch)
    XCTAssertEqual(WatchProgressReconciler.resolve(local: phone, incoming: equalTimestampWatch), phone)
  }

  func testOfferAndManifestIdentityRoundTripWithoutCredentials() throws {
    let manifest = WatchTransferManifest(
      transferID: "transfer",
      bookID: "book",
      title: "Title",
      authorName: nil,
      duration: 12,
      tracks: [.init(index: 0, duration: 12, byteCount: 6, fileExtension: "m4a", chunkCount: 2)],
      expectsCover: true,
      expectedCoverByteCount: 2
    )
    let offer = WatchTransferOffer(manifest: manifest)
    let decoded = try JSONDecoder().decode(
      WatchTransferOffer.self,
      from: JSONEncoder().encode(offer)
    )
    let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(decoded), encoding: .utf8))

    XCTAssertEqual(decoded, offer)
    XCTAssertEqual(manifest.manifestIdentity, offer.identity)
    XCTAssertEqual(offer.fileCount, 2)
    XCTAssertEqual(offer.totalByteCount, 8)
    XCTAssertFalse(encoded.localizedCaseInsensitiveContains("authorization"))
    XCTAssertFalse(encoded.localizedCaseInsensitiveContains("token"))
    XCTAssertFalse(encoded.localizedCaseInsensitiveContains("http"))
  }

  func testChunkEnvelopeValidatesSizeAndIdentity() throws {
    let file = WatchTransferFileIdentity.track(
      transferID: "transfer",
      bookID: "book",
      trackIndex: 0
    )
    let data = Data("abcd".utf8)
    let descriptor = WatchTransferFileDescriptor(
      identity: file,
      byteCount: 4,
      chunkCount: 2,
      chunkByteCounts: [2, 2],
      integrity: WatchTransferIntegrity(data: data)
    )
    let response = WatchTransferChunkResponse(
      file: file,
      chunkIndex: 1,
      byteOffset: 2,
      data: Data("cd".utf8)
    )
    let decoded = try JSONDecoder().decode(
      WatchTransferChunkEnvelope.self,
      from: JSONEncoder().encode(response)
    )

    XCTAssertEqual(decoded, response)
    XCTAssertNil(response.validate(against: descriptor))
    XCTAssertEqual(
      WatchTransferChunkResponse(
        file: file,
        chunkIndex: 1,
        byteOffset: 0,
        data: Data("cd".utf8)
      ).validate(against: descriptor),
      .chunkOffsetMismatch(expected: 2, actual: 0)
    )
    XCTAssertFalse(
      WatchTransferChunkResponse(
        file: .track(transferID: "transfer", bookID: "other", trackIndex: 0),
        chunkIndex: 1,
        byteOffset: 2,
        data: Data("cd".utf8)
      ).validate(against: descriptor) == nil
    )
  }

  func testIntegrityAndSizeValidationRejectsCorruptPayloads() {
    let expected = Data("audio".utf8)
    let integrity = WatchTransferIntegrity(data: expected)

    XCTAssertTrue(integrity.matches(expected))
    XCTAssertEqual(
      integrity.validate(data: Data("aud".utf8)),
      .sizeMismatch(expected: 5, actual: 3)
    )
    XCTAssertEqual(
      integrity.validate(data: Data("other".utf8)),
      .digestMismatch(expected: integrity.digest, actual: WatchTransferIntegrity.digest(for: Data("other".utf8)))
    )
  }

  func testReceiveStatePersistsBytesAndSelectsMissingChunks() throws {
    let file = WatchTransferFileIdentity.track(
      transferID: "transfer",
      bookID: "book",
      trackIndex: 0
    )
    let descriptor = WatchTransferFileDescriptor(
      identity: file,
      byteCount: 6,
      chunkCount: 3,
      chunkByteCounts: [2, 2, 2]
    )
    let first = WatchTransferChunkResponse(
      file: file,
      chunkIndex: 0,
      byteOffset: 0,
      data: Data("ab".utf8)
    )
    let second = WatchTransferChunkResponse(
      file: file,
      chunkIndex: 1,
      byteOffset: 2,
      data: Data("cd".utf8)
    )
    var state = WatchTransferFileReceiveState(
      file: file,
      expectedByteCount: 6,
      expectedChunkCount: 3
    )

    XCTAssertNil(state.record(first, descriptor: descriptor))
    XCTAssertNil(state.record(second, descriptor: descriptor))
    XCTAssertNil(state.record(first, descriptor: descriptor))
    XCTAssertFalse(state.recordChunk(index: 0, byteCount: 3))
    XCTAssertEqual(state.receivedByteCount, 4)
    XCTAssertEqual(state.receivedChunkIndexes, [0, 1])
    XCTAssertEqual(state.missingChunkIndexes, [2])
    XCTAssertEqual(state.progress, 4.0 / 6.0, accuracy: 0.0001)

    let restored = try JSONDecoder().decode(
      WatchTransferFileReceiveState.self,
      from: JSONEncoder().encode(state)
    )
    XCTAssertEqual(restored, state)

    let transferState = WatchTransferReceiveState(
      identity: WatchTransferManifestIdentity(transferID: "transfer", bookID: "book"),
      files: [state]
    )
    XCTAssertEqual(transferState.receivedByteCount, 4)
    XCTAssertEqual(transferState.totalByteCount, 6)
    XCTAssertEqual(transferState.missingChunkRequests().map(\.chunkIndex), [2])
    XCTAssertEqual(transferState.byteProgress.fraction, 4.0 / 6.0, accuracy: 0.0001)
  }

  func testResumeSelectorLimitsRequestsToMissingChunks() {
    let file = WatchTransferFileIdentity.track(
      transferID: "transfer",
      bookID: "book",
      trackIndex: 1
    )

    XCTAssertEqual(
      WatchTransferResumeSelector.missingChunkIndexes(
        expectedChunkCount: 5,
        receivedChunkIndexes: [0, 2, 2, 8]
      ),
      [1, 3, 4]
    )
    XCTAssertEqual(
      WatchTransferResumeSelector.requests(
        for: file,
        expectedChunkCount: 5,
        receivedChunkIndexes: [0, 2],
        limit: 2
      ).map(\.chunkIndex),
      [1, 3]
    )
  }

  func testRelayWindowCanSelectEightMissingChunks() {
    let file = WatchTransferFileIdentity.track(
      transferID: "transfer",
      bookID: "book",
      trackIndex: 0
    )
    let state = WatchTransferFileReceiveState(
      file: file,
      expectedByteCount: 10,
      expectedChunkCount: 10
    )
    let requests = WatchTransferReceiveState(
      identity: WatchTransferManifestIdentity(transferID: "transfer", bookID: "book"),
      files: [state]
    ).missingChunkRequests(limit: 8)

    XCTAssertEqual(requests.count, 8)
    XCTAssertEqual(requests.map(\.chunkIndex), Array(0..<8))
  }

  func testShareOfferRequiresHTTPSPublicHostAndBoundedExpiry() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let valid = makeShareOffer(now: now)
    XCTAssertTrue(valid.isValid(at: now))

    for url in [
      URL(string: "http://share.example.test/public/share/slug")!,
      URL(string: "https://192.168.1.10/audiobookshelf/public/share/slug")!,
      URL(string: "https://100.92.133.126/audiobookshelf/public/share/slug")!,
    ] {
      XCTAssertFalse(makeShareOffer(now: now, publicBootstrapURL: url).isValid(at: now))
    }

    let expired = makeShareOffer(now: now, expiresAt: now)
    XCTAssertEqual(expired.validationError(at: now), .expired)

    let unbounded = makeShareOffer(
      now: now,
      expiresAt: now.addingTimeInterval(WatchShareOffer.maximumLifetime + 1)
    )
    XCTAssertEqual(unbounded.validationError(at: now), .unboundedExpiry)
  }

  func testSharePayloadContainsNoAuthorizationTokenOrCustomHeaders() throws {
    let payload = Data("audio".utf8)
    let track = WatchShareTrackDescriptor(
      index: 0,
      byteCount: Int64(payload.count),
      fileExtension: "m4a",
      integrity: WatchTransferIntegrity(data: payload)
    )
    let offer = makeShareOffer(tracks: [track])
    var lifecycle = WatchShareLifecycle(offer: offer)
    XCTAssertEqual(
      lifecycle.recordPartialRange(
        index: 0,
        metadata: WatchShareResumeMetadata(
          receivedByteCount: 2,
          totalByteCount: Int64(payload.count),
          entityTag: "v1"
        )
      ),
      .accepted
    )

    let offerText = try XCTUnwrap(
      String(data: JSONEncoder().encode(offer), encoding: .utf8)
    ).lowercased()
    let lifecycleText = try XCTUnwrap(
      String(data: JSONEncoder().encode(lifecycle), encoding: .utf8)
    ).lowercased()
    let encoded = offerText + lifecycleText

    XCTAssertFalse(encoded.contains("authorization"))
    XCTAssertFalse(encoded.contains("token"))
    XCTAssertFalse(encoded.contains("customheaders"))
  }

  func testShareExpiryAndReplacementAdvanceGeneration() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let offer = makeShareOffer(now: now, expiresAt: now.addingTimeInterval(60))
    var lifecycle = WatchShareLifecycle(offer: offer)

    XCTAssertEqual(lifecycle.replacementGeneration, 0)
    XCTAssertTrue(lifecycle.markExpired(at: now.addingTimeInterval(61)))
    XCTAssertNil(lifecycle.activeURL)

    let replacement = offer.replacing(
      shareID: "share-2",
      publicBootstrapURL: URL(string: "https://share.example.test/audiobookshelf/public/share/new")!,
      expiresAt: now.addingTimeInterval(600)
    )
    XCTAssertEqual(replacement.replacementGeneration, 1)
    XCTAssertTrue(lifecycle.replace(with: replacement, at: now))
    XCTAssertEqual(lifecycle.lastShareID, "share-2")
    XCTAssertEqual(lifecycle.activeURL, replacement.publicBootstrapURL)
    XCTAssertFalse(lifecycle.replace(with: replacement, at: now))
  }

  func testValidatedCompletedTrackIsReusableAfterShareReplacement() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = Data("audio".utf8)
    let track = WatchShareTrackDescriptor(
      index: 0,
      byteCount: Int64(data.count),
      fileExtension: "m4a",
      integrity: WatchTransferIntegrity(data: data)
    )
    let offer = makeShareOffer(
      now: now,
      expiresAt: now.addingTimeInterval(60),
      tracks: [track]
    )
    var lifecycle = WatchShareLifecycle(offer: offer)

    XCTAssertEqual(lifecycle.recordValidatedTrack(index: 0, data: data), .accepted)
    XCTAssertTrue(lifecycle.isComplete)
    XCTAssertTrue(lifecycle.markExpired(at: now.addingTimeInterval(61)))

    let replacement = offer.replacing(
      shareID: "share-2",
      publicBootstrapURL: URL(string: "https://share.example.test/audiobookshelf/public/share/new")!,
      expiresAt: now.addingTimeInterval(600)
    )
    XCTAssertTrue(lifecycle.replace(with: replacement, at: now))
    XCTAssertEqual(lifecycle.reusableCompletedTrackIndexes, [0])
    XCTAssertEqual(lifecycle.missingTrackIndexes, [])
  }

  func testPartialRangeResumeMetadataTracksPrefixAndValidators() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let track = WatchShareTrackDescriptor(index: 0, byteCount: 100, fileExtension: "m4a")
    let offer = makeShareOffer(now: now, tracks: [track])
    var lifecycle = WatchShareLifecycle(offer: offer)
    let metadata = WatchShareResumeMetadata(
      receivedByteCount: 40,
      totalByteCount: 100,
      entityTag: "etag-1",
      lastModified: Date(timeIntervalSince1970: 1_799_999_900)
    )

    XCTAssertTrue(metadata.isPartial)
    XCTAssertEqual(metadata.rangeHeader, "bytes=40-")
    XCTAssertNil(metadata.validationError(against: track))
    XCTAssertEqual(lifecycle.recordPartialRange(index: 0, metadata: metadata), .accepted)
    XCTAssertEqual(lifecycle.recordPartialRange(index: 0, metadata: metadata), .duplicate)
    XCTAssertEqual(lifecycle.receipts.first?.resumeMetadata, metadata)
    XCTAssertEqual(lifecycle.missingTrackIndexes, [0])
  }

  func testAllTracksMustBeValidatedBeforeCompletion() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let tracks = [
      WatchShareTrackDescriptor(index: 0, byteCount: 2, fileExtension: "m4a"),
      WatchShareTrackDescriptor(index: 1, byteCount: 3, fileExtension: "m4a"),
    ]
    var lifecycle = WatchShareLifecycle(
      offer: makeShareOffer(now: now, tracks: tracks)
    )

    XCTAssertEqual(lifecycle.recordValidatedTrack(index: 1, data: Data("one".utf8)), .accepted)
    XCTAssertEqual(lifecycle.missingTrackIndexes, [0])
    XCTAssertFalse(lifecycle.isComplete)
    XCTAssertEqual(lifecycle.recordValidatedTrack(index: 0, data: Data("0!".utf8)), .accepted)
    XCTAssertTrue(lifecycle.isComplete)
    XCTAssertEqual(lifecycle.completedTrackIndexes, [0, 1])
    XCTAssertTrue(lifecycle.markCompleted())
    XCTAssertEqual(lifecycle.state, .completed)
    XCTAssertNil(lifecycle.activeURL)
    XCTAssertEqual(lifecycle.cleanupPlan?.removePartialTrackFiles, false)
  }

  func testIntegrityMismatchIsRejectedAndCancellationCleansUpIdempotently() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expected = Data("audio".utf8)
    let track = WatchShareTrackDescriptor(
      index: 0,
      byteCount: Int64(expected.count),
      fileExtension: "m4a",
      integrity: WatchTransferIntegrity(data: expected)
    )
    var lifecycle = WatchShareLifecycle(
      offer: makeShareOffer(now: now, tracks: [track])
    )

    XCTAssertEqual(
      lifecycle.recordValidatedTrack(index: 0, data: Data("other".utf8)),
      .rejected
    )
    XCTAssertEqual(lifecycle.recordValidatedTrack(index: 0, data: expected), .accepted)
    XCTAssertEqual(lifecycle.recordValidatedTrack(index: 0, data: expected), .duplicate)

    let cleanup = lifecycle.cancel()
    XCTAssertEqual(lifecycle.state, .cancelled)
    XCTAssertNil(lifecycle.activeURL)
    XCTAssertEqual(cleanup.shareID, "share-1")
    XCTAssertTrue(cleanup.removeActiveURL)
    XCTAssertTrue(cleanup.revokeShare)
    XCTAssertTrue(cleanup.removePartialTrackFiles)
    XCTAssertFalse(cleanup.retainValidatedTrackFiles)
    XCTAssertEqual(lifecycle.cancel(), cleanup)
  }

  private func makeShareOffer(
    now: Date = Date(timeIntervalSince1970: 1_800_000_000),
    shareID: String = "share-1",
    publicBootstrapURL: URL = URL(
      string: "https://share.example.test/audiobookshelf/public/share/slug"
    )!,
    expiresAt: Date? = nil,
    tracks: [WatchShareTrackDescriptor] = [
      WatchShareTrackDescriptor(index: 0, byteCount: 5, fileExtension: "m4a")
    ]
  ) -> WatchShareOffer {
    WatchShareOffer(
      transferID: "transfer-1",
      bookID: "book-1",
      shareID: shareID,
      publicBootstrapURL: publicBootstrapURL,
      expiresAt: expiresAt ?? now.addingTimeInterval(3_600),
      tracks: tracks
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

extension WatchTransferContractsTests {
  func testSegmentPlannerSplitsCoversAndFiltersStoredSegments() {
    let plan = WatchShareSegmentPlanner.plan(totalByteCount: 100, segmentByteCount: 30)
    XCTAssertEqual(plan.map(\.byteCount), [30, 30, 30, 10])
    XCTAssertEqual(plan.map(\.startOffset), [0, 30, 60, 90])
    XCTAssertEqual(plan.last?.rangeHeaderValue, "bytes=90-99")
    XCTAssertEqual(plan.reduce(0) { $0 + $1.byteCount }, 100)

    XCTAssertTrue(WatchShareSegmentPlanner.plan(totalByteCount: 0).isEmpty)
    XCTAssertTrue(WatchShareSegmentPlanner.plan(totalByteCount: -5, segmentByteCount: 10).isEmpty)
    XCTAssertTrue(WatchShareSegmentPlanner.plan(totalByteCount: 100, segmentByteCount: 0).isEmpty)

    let stored: [Int: Int64] = [0: 30, 1: 12, 2: 40]
    let missing = WatchShareSegmentPlanner.missingSegments(from: plan, storedSegmentByteCounts: stored)
    // Partial (12/30) and oversized (40/30) segments must both be re-downloaded.
    XCTAssertEqual(missing.map(\.index), [1, 2, 3])
    XCTAssertEqual(
      WatchShareSegmentPlanner.completedByteCount(for: plan, storedSegmentByteCounts: stored),
      30
    )
    XCTAssertEqual(
      WatchShareSegmentPlanner.completedByteCount(
        for: plan,
        storedSegmentByteCounts: [0: 30, 1: 30, 2: 30, 3: 10]
      ),
      100
    )
  }
}
