import Foundation
import XCTest

@testable import API

final class PersonalizedTests: XCTestCase {
  func testDecodesRecentlyAddedBooksAndSeriesShelves() throws {
    let data = Data(
      #"""
      [
        {
          "id": "recently-added",
          "label": "Recently Added",
          "type": "book",
          "entities": [
            {
              "id": "book-1",
              "libraryId": "library-1",
              "addedAt": 1000,
              "updatedAt": 1000,
              "media": {"metadata": {"title": "A New Book"}}
            }
          ]
        },
        {
          "id": "recent-series",
          "label": "Recent Series",
          "type": "series",
          "entities": [
            {
              "id": "series-1",
              "name": "A New Series",
              "addedAt": 1000,
              "books": [
                {
                  "id": "book-1",
                  "libraryId": "library-1",
                  "addedAt": 1000,
                  "updatedAt": 1000,
                  "media": {"metadata": {"title": "A New Book"}}
                }
              ]
            }
          ]
        }
      ]
      """#.utf8
    )

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let sections = try decoder.decode([Personalized.Section].self, from: data)

    guard case .books(let books) = sections[0].entities else {
      return XCTFail("Expected a recently added books shelf")
    }
    XCTAssertEqual(books.map(\.title), ["A New Book"])

    guard case .series(let series) = sections[1].entities else {
      return XCTFail("Expected a recently added series shelf")
    }
    XCTAssertEqual(series.map(\.name), ["A New Series"])
    XCTAssertEqual(series.first?.books.map(\.title), ["A New Book"])
  }
}
