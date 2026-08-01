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
    book = container.decodeSearchResults(SearchBook.self, forKey: .book)
    podcast = container.decodeSearchResults(SearchPodcast.self, forKey: .podcast)
    episodes = container.decodeSearchResults(SearchPodcast.self, forKey: .episodes)
    series = container.decodeSearchResults(Series.self, forKey: .series)
    authors = container.decodeSearchResults(Author.self, forKey: .authors)
    narrators = container.decodeSearchResults(Narrator.self, forKey: .narrators)
    tags = container.decodeSearchResults(Tag.self, forKey: .tags)
    genres = container.decodeSearchResults(Genre.self, forKey: .genres)
  }
}

extension SearchResponse {
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
  func decodeSearchResults<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
    guard var results = try? nestedUnkeyedContainer(forKey: key) else { return [] }

    var decoded: [T] = []
    while !results.isAtEnd {
      guard let elementDecoder = try? results.superDecoder() else { break }
      if let element = try? T(from: elementDecoder) {
        decoded.append(element)
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
