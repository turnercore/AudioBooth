import API
import Combine
import SwiftUI

@available(iOS 26.0, *)
struct SearchPage: View {
  @StateObject var model: SearchView.Model

  var body: some View {
    NavigationStack {
      SearchView(model: model)
        .navigationDestinations()
    }
    .searchable(text: $model.searchText)
  }
}

struct SearchView: View {
  @ObservedObject var model: Model
  @Environment(\.appTheme) var theme

  var body: some View {
    ScrollView {
      content
    }
    .frame(maxWidth: .infinity)
    .background(theme.colors.background.page.ignoresSafeArea())
    .scrollDismissesKeyboard(.interactively)
    .onAppear {
      model.onSearchChanged(model.searchText)
    }
    .onChange(of: model.searchText) { _, newValue in
      model.onSearchChanged(newValue)
    }
  }

  @ViewBuilder
  var content: some View {
    if !model.hasSearchQuery {
      emptyState
        .containerRelativeFrame(.vertical)
    } else if model.isLoading {
      loadingState
        .containerRelativeFrame(.vertical)
    } else if model.books.isEmpty, model.podcasts.isEmpty, model.episodes.isEmpty,
      model.series.isEmpty, model.authors.isEmpty,
      model.narrators.isEmpty, model.tags.isEmpty, model.genres.isEmpty, model.failedResults.isEmpty
    {
      noResultsState
        .containerRelativeFrame(.vertical)
    } else {
      resultsContent
    }
  }

  var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 48))
        .foregroundColor(.secondary)

      Text(
        model.mediaType == .podcast
          ? "Search for podcasts or episodes"
          : "Search for books, series, authors, narrators, tags, or genres"
      )
      .font(.headline)
      .foregroundColor(.secondary)
      .multilineTextAlignment(.center)
    }
    .padding()
  }

  var loadingState: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.2)

      Text("Searching...")
        .font(.headline)
        .foregroundColor(.secondary)
    }
  }

  var noResultsState: some View {
    VStack(spacing: 16) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 48))
        .foregroundColor(.primary)

      Text("No results found")
        .font(.headline)
        .foregroundColor(.primary)

      Text("Check the spelling or try fewer words")
        .font(.subheadline)
        .foregroundColor(.secondary)
    }
  }

  var resultsContent: some View {
    LazyVStack(spacing: 24) {
      if !model.failedResults.isEmpty {
        failedResultsSection
      }

      if !model.books.isEmpty {
        booksSection
      }

      if !model.podcasts.isEmpty {
        podcastsSection
      }

      if !model.episodes.isEmpty {
        episodesSection
      }

      if !model.series.isEmpty {
        seriesSection
      }

      if !model.authors.isEmpty {
        authorsSection
      }

      if !model.narrators.isEmpty {
        narratorsSection
      }

      if !model.tags.isEmpty {
        tagsSection
      }

      if !model.genres.isEmpty {
        genresSection
      }
    }
    .padding()
    .padding(.bottom, 50)
  }

  var booksSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Books")
          .font(.title2)
          .fontWeight(.bold)

        Spacer()

        Text("\(model.books.count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      LibraryView(items: model.books.map { .book($0) }, displayMode: .grid)
    }
  }

  var podcastsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Podcasts")
          .font(.title2)
          .fontWeight(.bold)

        Spacer()

        Text("\(model.podcasts.count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      LibraryView(items: model.podcasts.map { .book($0) }, displayMode: .grid)
    }
  }

  var episodesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Episodes")
          .font(.title2)
          .fontWeight(.bold)

        Spacer()

        Text("\(model.episodes.count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      LibraryView(items: model.episodes.map { .book($0) }, displayMode: .grid)
    }
  }

  var seriesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Series")
          .font(.title2)
          .fontWeight(.bold)

        Spacer()

        Text("\(model.series.count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      SeriesView(series: model.series)
        .environment(\.itemDisplayMode, .card)
    }
  }

  var authorsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(model.authorsAreSuggestions ? "Suggested Authors" : "Authors")
          .font(.title2)
          .fontWeight(.bold)

        Spacer()

        Text("\(model.authors.count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if model.authorsAreSuggestions {
        Label("Close matches", systemImage: "sparkles")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      AuthorsView(authors: model.authors)
    }
  }

  var narratorsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(model.narratorsAreSuggestions ? "Suggested Narrators" : "Narrators")
          .font(.title2)
          .fontWeight(.bold)

        Spacer()

        Text("\(model.narrators.count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      if model.narratorsAreSuggestions {
        Label("Close matches", systemImage: "sparkles")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      FlowLayout(spacing: 8) {
        ForEach(model.narrators, id: \.self) { narrator in
          NavigationLink(value: NavigationDestination.narrator(name: narrator)) {
            Chip(
              title: narrator,
              icon: "person.wave.2.fill",
              color: .blue,
              mode: .large
            )
          }
        }
      }
    }
  }

  var failedResultsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        model.failedResults.count == 1
          ? "Couldn't show 1 result" : "Couldn't show \(model.failedResults.count) results",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.headline)
      .foregroundStyle(.orange)

      Text("Something unexpected came back from the server. Please report it so it can be fixed.")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      ForEach(Array(model.failedResults.enumerated()), id: \.offset) { _, failure in
        HStack(alignment: .firstTextBaseline) {
          Text(failure.title ?? "Unknown item")
            .font(.subheadline)
            .lineLimit(1)
          Text(failure.section)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 16) {
        Button("Copy Details", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = failedResultsReport
          Toast(message: "Copied").show()
        }

        Link(destination: URL(string: "https://github.com/AudioBooth/AudioBooth/issues")!) {
          Label("Report", systemImage: "questionmark.bubble")
        }
      }
      .font(.subheadline)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.orange.opacity(0.1))
    .clipShape(.rect(cornerRadius: 8))
  }

  private var failedResultsReport: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let lines = model.failedResults.map { "- \($0.section): \($0.title ?? "unknown") (\($0.reason))" }
    return (["AudioBooth \(version): search results that failed to decode"] + lines).joined(separator: "\n")
  }

  var tagsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Tags")
          .font(.title2)
          .fontWeight(.bold)

        Spacer()

        Text("\(model.tags.count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      FlowLayout(spacing: 8) {
        ForEach(model.tags, id: \.self) { tag in
          NavigationLink(value: NavigationDestination.tag(name: tag)) {
            Chip(
              title: tag,
              icon: "tag.fill",
              color: .gray,
              mode: .large
            )
          }
        }
      }
    }
  }

  var genresSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Genres")
          .font(.title2)
          .fontWeight(.bold)

        Spacer()

        Text("\(model.genres.count)")
          .font(.caption)
          .foregroundColor(.secondary)
      }

      FlowLayout(spacing: 8) {
        ForEach(model.genres, id: \.self) { genre in
          NavigationLink(value: NavigationDestination.genre(name: genre)) {
            Chip(
              title: genre,
              icon: "theatermasks.fill",
              color: .gray,
              mode: .large
            )
          }
        }
      }
    }
  }
}

extension SearchView {
  @Observable class Model: ObservableObject {
    var searchText: String = ""
    var isLoading: Bool = false
    var mediaType: Library.MediaType = .book
    var books: [BookCard.Model] = []
    var podcasts: [BookCard.Model] = []
    var episodes: [BookCard.Model] = []
    var series: [SeriesCard.Model] = []
    var authors: [AuthorCard.Model] = []
    var narrators: [String] = []
    var tags: [String] = []
    var genres: [String] = []
    var failedResults: [SearchResponse.FailedResult] = []
    var authorsAreSuggestions = false
    var narratorsAreSuggestions = false

    var hasSearchQuery: Bool {
      !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func onSearchChanged(_ searchText: String) {}
  }
}

extension SearchView.Model {
  static var mock: SearchView.Model {
    let model = SearchView.Model()
    model.books = [
      BookCard.Model(
        title: "The Lord of the Rings",
        details: "J.R.R. Tolkien",
        cover: Cover.Model(url: URL(string: "https://m.media-amazon.com/images/I/51YHc7SK5HL._SL500_.jpg"))
      ),
      BookCard.Model(
        title: "Dune",
        details: "Frank Herbert",
        cover: Cover.Model(url: URL(string: "https://m.media-amazon.com/images/I/41rrXYM-wHL._SL500_.jpg"))
      ),
      BookCard.Model(
        title: "Foundation",
        details: "Isaac Asimov",
        cover: Cover.Model(url: URL(string: "https://m.media-amazon.com/images/I/51I5xPlDi9L._SL500_.jpg"))
      ),
    ]
    model.series = [.mock, .mock]
    model.authors = [.mock, .mock]
    model.searchText = "sample search"
    return model
  }
}

#Preview("SearchView - Empty") {
  SearchView(model: SearchView.Model())
}

#Preview("SearchView - With Results") {
  SearchView(model: .mock)
}
