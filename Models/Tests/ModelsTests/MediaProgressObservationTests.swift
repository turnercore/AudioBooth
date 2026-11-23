import Foundation
import SwiftData
import Testing

@testable import Models

@MainActor
@Suite("Media progress observation")
struct MediaProgressObservationTests {
  @Test("book observation starts with only the requested progress")
  func startsWithRequestedBook() async throws {
    let serverID = "progress-observation-\(UUID().uuidString)"
    try ModelContextProvider.shared.useInMemoryContainer(for: serverID)

    let context = ModelContextProvider.shared.context
    context.insert(MediaProgress(bookID: "other-book", progress: 0.25))
    context.insert(MediaProgress(bookID: "requested-book", progress: 0.75))
    try context.save()

    let stream = MediaProgress.observe(bookID: "requested-book")
    var iterator = stream.makeAsyncIterator()
    let observed = await iterator.next()

    #expect(observed?.bookID == "requested-book")
    #expect(observed?.progress == 0.75)
  }
}
