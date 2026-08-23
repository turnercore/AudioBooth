import Foundation
import Testing

@testable import API

struct SharesTests {
  @Test func createRequestUsesAudiobookshelf236FieldNamesAndMilliseconds() throws {
    let request = CreateMediaItemShareRequest(
      slug: "unguessable",
      mediaItemType: "book",
      mediaItemID: "media-id",
      expiresAt: 1_800_000_000_000,
      isDownloadable: true
    )
    let object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )

    #expect(object["mediaItemId"] as? String == "media-id")
    #expect(object["mediaItemType"] as? String == "book")
    #expect(object["expiresAt"] as? Int64 == 1_800_000_000_000)
    #expect(object["isDownloadable"] as? Bool == true)
  }

  @Test func decodesAudiobookshelf236ShareFixture() throws {
    let json = Data(
      #"{"id":"share-id","slug":"unguessable","mediaItemId":"media-id","mediaItemType":"book","expiresAt":"2026-03-09T18:42:31.123Z","isDownloadable":true}"#
        .utf8
    )

    let share = try JSONDecoder().decode(MediaItemShare.self, from: json)

    #expect(share.id == "share-id")
    #expect(share.mediaItemID == "media-id")
    #expect(share.expiresAt.timeIntervalSince1970 == 1_773_081_751.123)
  }

  @Test func decodesNumericShareExpiryInMilliseconds() throws {
    let json = Data(
      #"{"id":"share-id","slug":"unguessable","expiresAt":1800000000123,"isDownloadable":true}"#.utf8
    )

    let share = try JSONDecoder().decode(MediaItemShare.self, from: json)
    #expect(share.expiresAt.timeIntervalSince1970 == 1_800_000_000.123)
  }

  @Test func expandedBookExposesServerMediaID() throws {
    let json = Data(
      #"{"id":"library-item","libraryId":"library","addedAt":1,"updatedAt":1,"media":{"id":"media-id","metadata":{"title":"Book"}}}"#
        .utf8
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970

    let book = try decoder.decode(Book.self, from: json)
    #expect(book.id == "library-item")
    #expect(book.media.id == "media-id")
  }
}
