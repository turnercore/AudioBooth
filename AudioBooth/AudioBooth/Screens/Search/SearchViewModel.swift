import API
import Foundation
import Logging

final class SearchViewModel: SearchView.Model {
  private let audiobookshelf = Audiobookshelf.shared

  private var currentSearchTask: Task<Void, Never>?
  private var lastSearch = ""

  override func onSearchChanged(_ searchText: String) {
    mediaType = audiobookshelf.libraries.current?.mediaType ?? .book

    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard query != lastSearch else { return }
    lastSearch = query

    currentSearchTask?.cancel()
    clearResults()

    guard !query.isEmpty else { return }

    isLoading = true
    currentSearchTask = Task {
      await performSearch(query: query)
    }
  }

  private func clearResults() {
    books = []
    podcasts = []
    episodes = []
    series = []
    authors = []
    narrators = []
    tags = []
    genres = []
    authorsAreSuggestions = false
    narratorsAreSuggestions = false
    isLoading = false
  }

  private func performSearch(query: String) async {
    do {
      try await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }

      let searchResult = try await audiobookshelf.search.search(query: query)
      guard !Task.isCancelled else { return }

      apply(searchResult)
      if searchResult.hasResults {
        isLoading = false
        return
      }

      let fuzzyCandidates = await loadFilterData()
      guard !Task.isCancelled else { return }

      applyFuzzyMatches(for: query, from: fuzzyCandidates)
      isLoading = false
    } catch {
      guard !Task.isCancelled else { return }

      AppLogger.viewModel.error("Failed to perform search: \(error)")
      Toast(error: "Search failed").show()
      clearResults()
    }
  }

  private func loadFilterData() async -> FilterData? {
    guard mediaType == .book else { return nil }
    if let cached = audiobookshelf.libraries.getCachedFilterData() {
      return cached
    }
    return try? await audiobookshelf.libraries.fetchFilterData()
  }

  private func apply(_ searchResult: SearchResponse) {
    books = searchResult.book.map { searchBook in
      BookCardModel(searchBook.libraryItem, sortBy: .title)
    }

    podcasts = searchResult.podcast.map { searchPodcast in
      PodcastCardModel(searchPodcast.libraryItem, sortBy: nil)
    }

    episodes = searchResult.episodes.map { searchEpisode in
      PodcastCardModel(searchEpisode.libraryItem, sortBy: nil)
    }

    series = searchResult.series.map { searchSeries in
      SeriesCardModel(series: searchSeries)
    }

    authors = searchResult.authors.map { author in
      AuthorCardModel(author: author)
    }

    narrators = searchResult.narrators.map(\.name)
    tags = searchResult.tags.map(\.name)
    genres = searchResult.genres.map(\.name)
  }

  private func applyFuzzyMatches(for query: String, from filterData: FilterData?) {
    guard let filterData else { return }

    if authors.isEmpty {
      let matches = FuzzySearchMatcher.matches(
        query: query,
        candidates: filterData.authors,
        name: \.name
      )
      authors = matches.map { author in
        AuthorCard.Model(id: author.id, name: author.name)
      }
      authorsAreSuggestions = !matches.isEmpty
    }

    if narrators.isEmpty {
      narrators = FuzzySearchMatcher.matches(
        query: query,
        candidates: filterData.narrators,
        name: { $0 }
      )
      narratorsAreSuggestions = !narrators.isEmpty
    }
  }
}

private extension SearchResponse {
  var hasResults: Bool {
    !book.isEmpty || !podcast.isEmpty || !episodes.isEmpty || !series.isEmpty || !authors.isEmpty
      || !narrators.isEmpty || !tags.isEmpty || !genres.isEmpty
  }
}
