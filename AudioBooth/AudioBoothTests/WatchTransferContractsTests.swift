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

  func testReceiptRequiresExpectedCoverBeforeCompletion() {
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
    XCTAssertFalse(receipt.isComplete)

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

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
