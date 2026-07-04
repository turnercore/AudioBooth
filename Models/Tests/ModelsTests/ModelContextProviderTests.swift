import Foundation
import SwiftData
import Testing

@testable import Models

@MainActor
@Suite("Model context provider")
struct ModelContextProviderTests {
  @Test("can inject an in-memory context for tests")
  func inMemoryContext() throws {
    let serverID = "test-\(UUID().uuidString)"
    try ModelContextProvider.shared.useInMemoryContainer(for: serverID)

    let context = try ModelContextProvider.shared.context(for: serverID)
    context.insert(
      PlaybackStateBackedBook.make(bookID: "book-1")
    )
    try context.save()

    let books = try context.fetch(FetchDescriptor<LocalBook>())
    #expect(books.contains { $0.bookID == "book-1" })
  }
}

private enum PlaybackStateBackedBook {
  static func make(bookID: String) -> LocalBook {
    LocalBook(
      bookID: bookID,
      title: "Title",
      authors: [],
      narrators: [],
      series: [],
      coverURL: nil,
      duration: 1,
      tracks: [],
      chapters: []
    )
  }
}
