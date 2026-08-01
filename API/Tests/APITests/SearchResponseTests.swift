import Foundation
import XCTest

@testable import API

final class SearchResponseTests: XCTestCase {
  func testDecodingPreservesValidCategoriesWhenOtherResultsAreInvalid() throws {
    let data = Data(
      #"""
      {
        "book": [{"libraryItem": {"unexpected": true}}],
        "podcast": [{"libraryItem": {"unexpected": true}}],
        "series": [{"unexpected": true}],
        "authors": [{"id": "author-1", "name": "Ursula K. Le Guin"}],
        "narrators": [
          "Rob Inglis",
          {"name": "George Guidall", "numBooks": "12"},
          {"numBooks": 4}
        ],
        "tags": ["Favorite", {"name": "Owned", "numItems": 3}],
        "genres": ["Fantasy", {"name": "Science Fiction", "numItems": "8"}]
      }
      """#.utf8
    )

    let response = try JSONDecoder().decode(SearchResponse.self, from: data)

    XCTAssertTrue(response.book.isEmpty)
    XCTAssertTrue(response.podcast.isEmpty)
    XCTAssertTrue(response.series.isEmpty)
    XCTAssertEqual(response.authors.map(\.name), ["Ursula K. Le Guin"])
    XCTAssertEqual(response.narrators.map(\.name), ["Rob Inglis", "George Guidall"])
    XCTAssertEqual(response.narrators.map(\.numBooks), [0, 12])
    XCTAssertEqual(response.tags.map(\.name), ["Favorite", "Owned"])
    XCTAssertEqual(response.tags.map(\.numItems), [0, 3])
    XCTAssertEqual(response.genres.map(\.name), ["Fantasy", "Science Fiction"])
    XCTAssertEqual(response.genres.map(\.numItems), [0, 8])
  }

  func testDecodingDefaultsMissingSearchSectionsToEmptyArrays() throws {
    let response = try JSONDecoder().decode(SearchResponse.self, from: Data("{}".utf8))

    XCTAssertTrue(response.book.isEmpty)
    XCTAssertTrue(response.podcast.isEmpty)
    XCTAssertTrue(response.episodes.isEmpty)
    XCTAssertTrue(response.series.isEmpty)
    XCTAssertTrue(response.authors.isEmpty)
    XCTAssertTrue(response.narrators.isEmpty)
    XCTAssertTrue(response.tags.isEmpty)
    XCTAssertTrue(response.genres.isEmpty)
  }
}
