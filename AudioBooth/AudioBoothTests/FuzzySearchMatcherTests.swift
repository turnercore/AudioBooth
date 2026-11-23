import XCTest

@testable import AudioBooth

final class FuzzySearchMatcherTests: XCTestCase {
  func testMatchesTransposedSurname() {
    let matches = FuzzySearchMatcher.matches(
      query: "Tolkein",
      candidates: ["Brandon Sanderson", "J.R.R. Tolkien", "Terry Pratchett"],
      name: { $0 }
    )

    XCTAssertEqual(matches, ["J.R.R. Tolkien"])
  }

  func testMatchesMisspelledFullName() {
    let matches = FuzzySearchMatcher.matches(
      query: "Branden Sanderson",
      candidates: ["Brandon Sanderson", "Brian Sanderson", "George Saunders"],
      name: { $0 }
    )

    XCTAssertEqual(matches.first, "Brandon Sanderson")
  }

  func testMatchesNarratorNameWithTypo() {
    let matches = FuzzySearchMatcher.matches(
      query: "Rob Ingils",
      candidates: ["Rob Inglis", "Simon Vance", "George Guidall"],
      name: { $0 }
    )

    XCTAssertEqual(matches, ["Rob Inglis"])
  }

  func testFoldsDiacriticsAndCase() {
    let matches = FuzzySearchMatcher.matches(
      query: "garcia marquez",
      candidates: ["Gabriel García Márquez", "Ursula K. Le Guin"],
      name: { $0 }
    )

    XCTAssertEqual(matches, ["Gabriel García Márquez"])
  }

  func testRejectsUnrelatedAndVeryShortQueries() {
    let candidates = ["Brandon Sanderson", "J.R.R. Tolkien"]

    XCTAssertTrue(
      FuzzySearchMatcher.matches(query: "Octavia Butler", candidates: candidates, name: { $0 }).isEmpty
    )
    XCTAssertTrue(
      FuzzySearchMatcher.matches(query: "Jo", candidates: candidates, name: { $0 }).isEmpty
    )
  }
}
