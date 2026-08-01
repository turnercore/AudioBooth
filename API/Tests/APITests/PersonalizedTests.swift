import Foundation
import XCTest

@testable import API

final class PersonalizedTests: XCTestCase {
  func testExpandedRecentSeriesUsesTwentyUniqueResults() throws {
    let existingSeries = try makeSeries(ids: (0..<5).map { "series-\($0)" })
    let expandedSeries = try makeSeries(ids: (0..<22).map { "series-\($0)" })
    let sections = [
      Personalized.Section(id: "recently-added", label: "Recently Added", entities: .books([])),
      Personalized.Section(
        id: "recent-series",
        label: "Server Recent Series",
        entities: .series(existingSeries)
      ),
    ]

    let merged = LibrariesService.mergingRecentSeries(
      expandedSeries,
      into: sections,
      limit: 20
    )

    XCTAssertEqual(merged.map(\.id), ["recently-added", "recent-series"])
    XCTAssertEqual(merged[1].label, "Server Recent Series")
    guard case .series(let series) = merged[1].entities else {
      return XCTFail("Expected an expanded series shelf")
    }
    XCTAssertEqual(series.map(\.id), (0..<20).map { "series-\($0)" })
  }

  func testExpandedRecentSeriesPreservesSixtyDayWindow() throws {
    let cutoff = Date(timeIntervalSince1970: 10_000_000)
    let series = try makeSeries(
      ids: ["recent", "boundary", "old", "unknown"],
      addedAt: [
        cutoff.addingTimeInterval(1),
        cutoff,
        cutoff.addingTimeInterval(-1),
        nil,
      ]
    )

    let recent = LibrariesService.recentSeries(from: series, since: cutoff)

    XCTAssertEqual(recent.map(\.id), ["recent", "boundary"])
  }

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

  private func makeSeries(ids: [String], addedAt: [Date?]? = nil) throws -> [Series] {
    let objects: [[String: Any]] = ids.enumerated().map { index, id in
      var object: [String: Any] = [
        "id": id,
        "name": "Series \(index)",
        "books": [],
      ]
      if let date = addedAt?[index] {
        object["addedAt"] = Int(date.timeIntervalSince1970 * 1000)
      }
      return object
    }

    let data = try JSONSerialization.data(withJSONObject: objects)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return try decoder.decode([Series].self, from: data)
  }
}
