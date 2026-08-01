import Combine
import Foundation
import Logging
import Nuke

@MainActor
public final class LibrariesService: ObservableObject {
  private let audiobookshelf: Audiobookshelf

  enum Keys {
    static let library = "selected_library"
    static func personalized(libraryID: String) -> String {
      "personalized_\(libraryID)"
    }
    static func filterData(libraryID: String) -> String {
      "filterdata_\(libraryID)"
    }
    static let libraries = "libraries"
  }

  init(audiobookshelf: Audiobookshelf) {
    self.audiobookshelf = audiobookshelf
  }

  func migrateToConnectionStorage() {
    guard let storage = audiobookshelf.authentication.server?.storage else { return }

    let standard = UserDefaults.standard

    if let data = standard.data(forKey: "audiobookshelf_selected_library") {
      storage.set(data, forKey: Keys.library)
      standard.removeObject(forKey: "audiobookshelf_selected_library")
    }

    if let data = standard.data(forKey: "selected_library") {
      storage.set(data, forKey: Keys.library)
      standard.removeObject(forKey: "selected_library")
    }

    if let data = standard.data(forKey: "libraries") {
      storage.set(data, forKey: Keys.libraries)
      standard.removeObject(forKey: "libraries")
    }

    let allKeys = standard.dictionaryRepresentation().keys
    for key in allKeys {
      if key.hasPrefix("personalized_") || key.hasPrefix("filterdata_") {
        storage.set(standard.data(forKey: key), forKey: key)
        standard.removeObject(forKey: key)
      }
    }
  }

  public var current: Library? {
    get {
      guard let server = audiobookshelf.authentication.server,
        let data = server.storage.data(forKey: Keys.library),
        var library = try? JSONDecoder().decode(Library.self, from: data)
      else { return nil }

      if library.serverID.isEmpty {
        library.serverID = server.id
      }

      return library
    }
    set {
      objectWillChange.send()
      if let newValue {
        guard let data = try? JSONEncoder().encode(newValue) else { return }
        audiobookshelf.authentication.server?.storage.set(data, forKey: Keys.library)
      } else {
        audiobookshelf.authentication.server?.storage.removeObject(forKey: Keys.library)
      }
      ImagePipeline.shared.cache.removeAll()
    }
  }

  public var libraries: [Library] {
    get {
      guard let data = audiobookshelf.authentication.server?.storage.data(forKey: Keys.libraries) else { return [] }
      return (try? JSONDecoder().decode([Library].self, from: data)) ?? []
    }
    set {
      objectWillChange.send()
      guard let data = try? JSONEncoder().encode(newValue) else { return }
      audiobookshelf.authentication.server?.storage.set(data, forKey: Keys.libraries)
    }
  }

  public func clearAllCaches() {
    guard let storage = audiobookshelf.authentication.server?.storage else { return }
    let keys = storage.dictionaryRepresentation().keys
    for key in keys where key.hasPrefix("personalized_") || key.hasPrefix("filterdata_") {
      storage.removeObject(forKey: key)
    }
  }

  public func fetch(serverID: String? = nil) async throws -> [Library] {
    let networkService: NetworkService

    if let serverID {
      guard let server = audiobookshelf.authentication.servers[serverID] else {
        throw Audiobookshelf.AudiobookshelfError.networkError("Server not found")
      }
      networkService = NetworkService(baseURL: server.baseURL, server: server) {
        let freshToken = try? await server.freshToken
        guard let credentials = freshToken else {
          return [:]
        }

        var headers = await server.customHeaders
        headers["Authorization"] = credentials.bearer
        return headers
      }
    } else {
      guard let service = audiobookshelf.networkService else {
        throw Audiobookshelf.AudiobookshelfError.networkError(
          "Network service not configured. Please login first."
        )
      }
      networkService = service
    }

    struct Response: Codable {
      let libraries: [Library]
    }

    let request = NetworkRequest<Response>(
      path: "/api/libraries",
      method: .get
    )

    do {
      let response = try await networkService.send(request)
      let activeServerID = audiobookshelf.authentication.server?.id
      let targetServerID = serverID ?? activeServerID ?? ""
      let fetched = response.value.libraries.map { library in
        var stamped = library
        stamped.serverID = targetServerID
        return stamped
      }
      if serverID == nil || serverID == activeServerID {
        libraries = fetched
      }
      return fetched
    } catch {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Failed to fetch libraries: \(error.localizedDescription)"
      )
    }
  }

  public func getCachedPersonalized() -> Personalized? {
    guard let library = audiobookshelf.libraries.current else { return nil }
    let key = Keys.personalized(libraryID: library.id)
    guard let data = audiobookshelf.authentication.server?.storage.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(Personalized.self, from: data)
  }

  public func fetchPersonalized(
    limitPerShelf: Int? = nil,
    recentSeriesLimit: Int? = nil,
    bypassingCache: Bool = false
  ) async throws -> Personalized {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    guard let library = audiobookshelf.libraries.current else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "No library selected. Please select a library first."
      )
    }

    var query: [String: String] = [:]
    if let limitPerShelf, limitPerShelf > 0 {
      query["limit"] = String(limitPerShelf)
    }
    if bypassingCache {
      query["refresh"] = String(Int(Date().timeIntervalSince1970 * 1000))
    }

    let request = NetworkRequest<[Personalized.Section]>(
      path: "/api/libraries/\(library.id)/personalized",
      method: .get,
      query: query.isEmpty ? nil : query
    )

    async let expandedRecentSeries = fetchExpandedRecentSeries(
      limit: recentSeriesLimit,
      libraryID: library.id,
      networkService: networkService
    )

    do {
      let response = try await networkService.send(request)
      var sections = response.value

      if let series = await expandedRecentSeries, !series.isEmpty {
        sections = Self.mergingRecentSeries(
          series,
          into: sections,
          limit: recentSeriesLimit ?? series.count
        )
      }

      let personalized = Personalized(libraryID: library.id, sections: sections)

      let encoder = JSONEncoder()
      if let data = try? encoder.encode(personalized) {
        let key = Keys.personalized(libraryID: personalized.libraryID)
        audiobookshelf.authentication.server?.storage.set(data, forKey: key)
      }

      return personalized
    } catch {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Failed to fetch personalized sections: \(error.localizedDescription)"
      )
    }
  }

  private func fetchExpandedRecentSeries(
    limit: Int?,
    libraryID: String,
    networkService: NetworkService
  ) async -> [Series]? {
    guard let limit, limit > 5 else { return nil }

    let request = NetworkRequest<Page<Series>>(
      path: "/api/libraries/\(libraryID)/series",
      method: .get,
      query: [
        "limit": String(limit),
        "page": "0",
        "sort": SeriesService.SortBy.addedAt.rawValue,
        "desc": "1",
      ]
    )

    guard let page = try? await networkService.send(request).value else { return nil }

    let cutoff = Date().addingTimeInterval(-60 * 24 * 60 * 60)
    return Self.recentSeries(from: page.results, since: cutoff)
  }

  nonisolated static func recentSeries(from series: [Series], since cutoff: Date) -> [Series] {
    series.filter { series in
      guard let addedAt = series.addedAt else { return false }
      return addedAt >= cutoff
    }
  }

  nonisolated static func mergingRecentSeries(
    _ expandedSeries: [Series],
    into sections: [Personalized.Section],
    limit: Int
  ) -> [Personalized.Section] {
    guard !expandedSeries.isEmpty, limit > 0 else { return sections }

    var sections = sections
    let existingIndex = sections.firstIndex(where: { $0.id == "recent-series" })
    let label = existingIndex.map { sections[$0].label } ?? "Recent Series"
    var mergedSeries = expandedSeries
    var mergedIDs = Set(expandedSeries.map(\.id))

    if let existingIndex, case .series(let existingSeries) = sections[existingIndex].entities {
      for existing in existingSeries where mergedIDs.insert(existing.id).inserted {
        mergedSeries.append(existing)
      }
    }

    let replacement = Personalized.Section(
      id: "recent-series",
      label: label,
      entities: .series(Array(mergedSeries.prefix(limit)))
    )

    if let existingIndex {
      sections[existingIndex] = replacement
    } else if let recentlyAddedIndex = sections.firstIndex(where: { $0.id == "recently-added" }) {
      sections.insert(replacement, at: recentlyAddedIndex + 1)
    } else {
      sections.append(replacement)
    }

    return sections
  }

  public func markAsFinished(bookID: String) async throws {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    struct UpdateFinishedStatusRequest: Codable {
      let isFinished: Bool
    }

    let request = NetworkRequest<Data>(
      path: "/api/me/progress/\(bookID)",
      method: .patch,
      body: UpdateFinishedStatusRequest(isFinished: true)
    )

    do {
      _ = try await networkService.send(request)
    } catch {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Failed to update book finished status: \(error.localizedDescription)"
      )
    }
  }

  public func fetchMediaProgress(bookID: String) async throws -> User.MediaProgress {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    let request = NetworkRequest<User.MediaProgress>(
      path: "/api/me/progress/\(bookID)",
      method: .get
    )

    do {
      let response = try await networkService.send(request)
      return response.value
    } catch {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Failed to fetch media progress: \(error.localizedDescription)"
      )
    }
  }

  public func fetchRecentEpisodes(
    libraryID: String? = nil,
    limit: Int = 50,
    page: Int = 0
  ) async throws -> [RecentEpisode] {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    guard let libraryID = libraryID ?? audiobookshelf.libraries.current?.id else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "No library selected. Please select a library first."
      )
    }

    struct Response: Decodable {
      let episodes: [RecentEpisode]
    }

    let request = NetworkRequest<Response>(
      path: "/api/libraries/\(libraryID)/recent-episodes",
      method: .get,
      query: [
        "limit": "\(limit)",
        "page": "\(page)",
      ]
    )

    do {
      let response = try await networkService.send(request)
      return response.value.episodes
    } catch {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Failed to fetch recent episodes: \(error.localizedDescription)"
      )
    }
  }

  public func resetBookProgress(progressID: String) async throws {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    let request = NetworkRequest<Data>(
      path: "/api/me/progress/\(progressID)",
      method: .delete
    )

    do {
      _ = try await networkService.send(request)
    } catch {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Failed to reset book progress: \(error.localizedDescription)"
      )
    }
  }

  public func getCachedFilterData() -> FilterData? {
    guard let library = audiobookshelf.libraries.current else { return nil }
    let key = Keys.filterData(libraryID: library.id)
    guard let data = audiobookshelf.authentication.server?.storage.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(FilterData.self, from: data)
  }

  public func fetchFilterData() async throws -> FilterData {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    guard let library = audiobookshelf.libraries.current else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "No library selected. Please select a library first."
      )
    }

    struct Response: Codable {
      let filterdata: FilterData
    }

    let request = NetworkRequest<Response>(
      path: "/api/libraries/\(library.id)",
      method: .get,
      query: ["include": "filterdata"]
    )

    do {
      let response = try await networkService.send(request)

      let encoder = JSONEncoder()
      if let data = try? encoder.encode(response.value.filterdata) {
        let key = Keys.filterData(libraryID: library.id)
        audiobookshelf.authentication.server?.storage.set(data, forKey: key)
      }

      return response.value.filterdata
    } catch {
      AppLogger.libraries.error("FilterData decoding error: \(error)")
      if let decodingError = error as? DecodingError {
        switch decodingError {
        case .keyNotFound(let key, let context):
          AppLogger.libraries.error("Missing key: \(key.stringValue) at path: \(context.codingPath)")
        case .typeMismatch(let type, let context):
          AppLogger.libraries.error("Type mismatch for type: \(type) at path: \(context.codingPath)")
        case .valueNotFound(let type, let context):
          AppLogger.libraries.error("Value not found for type: \(type) at path: \(context.codingPath)")
        case .dataCorrupted(let context):
          AppLogger.libraries.error("Data corrupted at path: \(context.codingPath)")
        @unknown default:
          AppLogger.libraries.error("Unknown decoding error")
        }
      }
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Failed to fetch filter data: \(error.localizedDescription)"
      )
    }
  }
}
