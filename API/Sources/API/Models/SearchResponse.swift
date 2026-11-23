import Foundation

public struct SearchResponse: Decodable, Sendable {
  public let book: [SearchBook]
  public let podcast: [SearchPodcast]
  public let episodes: [SearchPodcast]
  public let series: [Series]
  public let authors: [Author]
  public let narrators: [Narrator]
  public let tags: [Tag]
  public let genres: [Genre]
  /// Results the app couldn't decode, kept so the UI can show and report them instead of hiding them.
  public let failedResults: [FailedResult]

  enum CodingKeys: String, CodingKey {
    case book
    case podcast
    case episodes
    case series
    case authors
    case narrators
    case tags
    case genres
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    var failures: [FailedResult] = []
    book = container.decodeSearchResults(SearchBook.self, forKey: .book, failures: &failures)
    podcast = container.decodeSearchResults(SearchPodcast.self, forKey: .podcast, failures: &failures)
    episodes = container.decodeSearchResults(SearchPodcast.self, forKey: .episodes, failures: &failures)
    series = container.decodeSearchResults(Series.self, forKey: .series, failures: &failures)
    authors = container.decodeSearchResults(Author.self, forKey: .authors, failures: &failures)
    narrators = container.decodeSearchResults(Narrator.self, forKey: .narrators, failures: &failures)
    tags = container.decodeSearchResults(Tag.self, forKey: .tags, failures: &failures)
    genres = container.decodeSearchResults(Genre.self, forKey: .genres, failures: &failures)
    failedResults = failures
  }
}

extension SearchResponse {
  public struct FailedResult: Sendable {
    public let section: String
    public let title: String?
    public let reason: String
  }

  public struct SearchBook: Decodable, Sendable {
    public let libraryItem: Book
  }

  public struct SearchPodcast: Decodable, Sendable {
    public let libraryItem: Podcast
  }

  public struct Narrator: Codable, Sendable {
    public let name: String
    public let numBooks: Int

    private enum CodingKeys: String, CodingKey {
      case name
      case numBooks
    }

    public init(from decoder: Decoder) throws {
      if let name = try? decoder.singleValueContainer().decode(String.self) {
        self.name = name
        self.numBooks = 0
        return
      }

      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.name = try container.decode(String.self, forKey: .name)
      self.numBooks = container.decodeFlexibleInt(forKey: .numBooks)
    }
  }

  public struct Tag: Codable, Sendable {
    public let name: String
    public let numItems: Int

    private enum CodingKeys: String, CodingKey {
      case name
      case numItems
    }

    public init(from decoder: Decoder) throws {
      if let name = try? decoder.singleValueContainer().decode(String.self) {
        self.name = name
        self.numItems = 0
        return
      }

      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.name = try container.decode(String.self, forKey: .name)
      self.numItems = container.decodeFlexibleInt(forKey: .numItems)
    }
  }

  public struct Genre: Codable, Sendable {
    public let name: String
    public let numItems: Int

    private enum CodingKeys: String, CodingKey {
      case name
      case numItems
    }

    public init(from decoder: Decoder) throws {
      if let name = try? decoder.singleValueContainer().decode(String.self) {
        self.name = name
        self.numItems = 0
        return
      }

      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.name = try container.decode(String.self, forKey: .name)
      self.numItems = container.decodeFlexibleInt(forKey: .numItems)
    }
  }
}

private extension KeyedDecodingContainer {
  func decodeSearchResults<T: Decodable>(
    _ type: T.Type,
    forKey key: Key,
    failures: inout [SearchResponse.FailedResult]
  ) -> [T] {
    guard contains(key), (try? decodeNil(forKey: key)) != true else { return [] }
    guard var results = try? nestedUnkeyedContainer(forKey: key) else {
      failures.append(.init(section: key.stringValue, title: nil, reason: "Section is not a list"))
      return []
    }

    var decoded: [T] = []
    while !results.isAtEnd {
      // superDecoder() moves past the element even when decoding it fails.
      guard let elementDecoder = try? results.superDecoder() else { break }
      do {
        decoded.append(try T(from: elementDecoder))
      } catch {
        let failure = SearchResponse.FailedResult(
          section: key.stringValue,
          title: (try? SearchResultTitle(from: elementDecoder))?.title,
          reason: error.searchFailureReason
        )
        AppLogger.network.warning(
          "Failed to decode search result in \(failure.section): \(failure.reason)"
        )
        failures.append(failure)
      }
    }
    return decoded
  }

  func decodeFlexibleInt(forKey key: Key) -> Int {
    if let value = try? decode(Int.self, forKey: key) {
      return value
    }
    if let value = try? decode(String.self, forKey: key) {
      return Int(value) ?? 0
    }
    return 0
  }
}

/// Best-effort title for a result that failed to decode, so the user can see which item it was.
private struct SearchResultTitle: Decodable {
  let title: String?

  private struct Item: Decodable {
    struct Media: Decodable {
      struct Metadata: Decodable { let title: String? }
      let metadata: Metadata?
    }
    let media: Media?
  }

  private enum CodingKeys: String, CodingKey {
    case libraryItem, name, title
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title =
      (try? container.decodeIfPresent(Item.self, forKey: .libraryItem))?.media?.metadata?.title
      ?? (try? container.decodeIfPresent(String.self, forKey: .name))
      ?? (try? container.decodeIfPresent(String.self, forKey: .title))
  }
}

extension Error {
  /// Field path and kind of mismatch only; never includes response values.
  fileprivate var searchFailureReason: String {
    guard let error = self as? DecodingError else { return String(describing: type(of: self)) }

    func path(_ codingPath: [CodingKey]) -> String {
      let path = codingPath.dropFirst(2).map { $0.intValue.map(String.init) ?? $0.stringValue }
      return path.isEmpty ? "result" : path.joined(separator: ".")
    }

    switch error {
    case .keyNotFound(let key, let context):
      return "Missing \(path(context.codingPath + [key]))"
    case .typeMismatch(let type, let context):
      return "Expected \(type) at \(path(context.codingPath))"
    case .valueNotFound(let type, let context):
      return "Null \(type) at \(path(context.codingPath))"
    case .dataCorrupted(let context):
      return "Invalid value at \(path(context.codingPath))"
    @unknown default:
      return "Unknown decoding error"
    }
  }
}
