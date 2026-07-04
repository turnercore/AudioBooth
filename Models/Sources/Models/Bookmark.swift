import CoreData
@preconcurrency import Foundation
import SwiftData

@Model
public final class Bookmark {
  public enum Status: String, Codable {
    case pending
    case synced
    case failed
  }

  public enum Error: Swift.Error {
    case notFound
  }

  public var bookID: String
  public var time: Int
  public var title: String
  public var createdAt: Date
  public var status: Status = Status.synced

  public init(
    bookID: String,
    time: Int,
    title: String,
    createdAt: Date = Date(),
    status: Status = .pending
  ) {
    self.bookID = bookID
    self.time = time
    self.title = title
    self.createdAt = createdAt
    self.status = status
  }

}

@MainActor
extension Bookmark {
  public static func fetchAll() throws -> [Bookmark] {
    let context = ModelContextProvider.shared.context
    let descriptor = FetchDescriptor<Bookmark>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    let results = try context.fetch(descriptor)
    return results
  }

  public static func fetch(bookID: String) throws -> [Bookmark] {
    let context = ModelContextProvider.shared.context
    let predicate = #Predicate<Bookmark> { bookmark in
      bookmark.bookID == bookID
    }
    let descriptor = FetchDescriptor<Bookmark>(
      predicate: predicate,
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    let results = try context.fetch(descriptor)
    return results
  }

  public static func fetch(bookID: String, time: Int) throws -> Bookmark? {
    let context = ModelContextProvider.shared.context
    let predicate = #Predicate<Bookmark> { bookmark in
      bookmark.bookID == bookID && bookmark.time == time
    }
    let descriptor = FetchDescriptor<Bookmark>(predicate: predicate)
    let results = try context.fetch(descriptor)
    return results.first
  }

  public func save() throws {
    let context = ModelContextProvider.shared.context

    if let existingBookmark = try Bookmark.fetch(bookID: self.bookID, time: self.time) {
      existingBookmark.title = self.title
      existingBookmark.createdAt = self.createdAt
    } else {
      context.insert(self)
    }

    try context.save()
  }

  public func delete() throws {
    let context = ModelContextProvider.shared.context
    context.delete(self)
    try context.save()
  }

}
