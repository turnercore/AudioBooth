import Combine
import Models
import NukeUI
import SwiftUI

struct PhoneDownloadsView: View {
  @StateObject var model: Model
  @ObservedObject private var playerManager = PlayerManager.shared
  @ObservedObject private var connectivityManager = WatchConnectivityManager.shared

  init(model: Model = Model()) {
    _model = StateObject(wrappedValue: model)
  }

  var body: some View {
    List {
      if playerManager.isPlayingOnWatch, let current = playerManager.current {
        Section("Now Playing") {
          Button {
            playerManager.isShowingFullPlayer = true
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "waveform")
                .foregroundStyle(.orange)
              VStack(alignment: .leading, spacing: 2) {
                Text(current.title)
                  .font(.caption2).fontWeight(.medium).lineLimit(1)
                Text("On Watch — tap to open")
                  .font(.caption2).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "play.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
        }
      } else if connectivityManager.hasCurrentBook {
        Section("Now Playing on iPhone") {
          HStack(spacing: 8) {
            Image(systemName: "iphone")
              .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
              Text("Playing on iPhone")
                .font(.caption2).fontWeight(.medium).lineLimit(1)
              Text("Use iPhone controls or open remote")
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
          }
        }
      }
      if model.isEmpty {
        ContentUnavailableView(
          "No Downloads",
          systemImage: "applewatch.slash",
          description: Text("Download an audiobook on your iPhone, then keep both devices nearby.")
        )
      } else {
        localSection("On Watch · In Progress", books: model.localInProgress)
        localSection("On Watch · Finished", books: model.localFinished)
        phoneSection("On iPhone · In Progress", books: model.phoneInProgress)
        phoneSection("On iPhone · Not Started", books: model.phoneNotStarted)
        phoneSection("On iPhone · Finished", books: model.phoneFinished)
      }
    }
    .navigationTitle("Downloads")
    .refreshable { model.refresh() }
    .onAppear { model.refresh() }
  }

  @ViewBuilder
  private func localSection(_ title: String, books: [WatchBook]) -> some View {
    if !books.isEmpty {
      Section(title) {
        ForEach(books) { book in
          localRow(book)
        }
      }
    }
  }

  @ViewBuilder
  private func phoneSection(_ title: String, books: [WatchPhoneLibraryBook]) -> some View {
    if !books.isEmpty {
      Section(title) {
        ForEach(books) { book in
          phoneRow(book)
        }
      }
    }
  }

  private func localRow(_ book: WatchBook) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Button {
        model.play(book)
      } label: {
        bookIdentity(
          title: book.title,
          author: book.authorName,
          coverURL: book.preferredCoverURL,
          isDownloaded: true,
          progress: book.progress
        )
      }
      .buttonStyle(.plain)
      progress(value: book.progress, label: model.progressText(current: book.currentTime, duration: book.duration))
      Button("Remove from Watch", role: .destructive) {
        model.remove(book)
      }
      .buttonStyle(.bordered)
    }
    .padding(.vertical, 3)
  }

  private func phoneRow(_ book: WatchPhoneLibraryBook) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      bookIdentity(
        title: book.title,
        author: book.authorName,
        coverURL: model.catalogArtworkURL(for: book.bookID),
        isDownloaded: false,
        progress: book.progress
      )
      if let byteProgress = model.transferProgress(for: book) {
        transferProgress(
          value: byteProgress,
          label: model.transferProgressText(byteProgress)
        )
      } else {
        progress(value: book.progress, label: model.progressText(current: book.currentTime, duration: book.duration))
      }
      HStack {
        Text(model.stateText(for: book))
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
        Button(model.actionTitle(for: book)) {
          model.performAction(for: book)
        }
        .buttonStyle(.bordered)
        .disabled(!model.actionEnabled(for: book))
      }
    }
    .padding(.vertical, 3)
  }

  private func bookIdentity(
    title: String,
    author: String?,
    coverURL: URL?,
    isDownloaded: Bool,
    progress: Double = 0
  ) -> some View {
    HStack(spacing: 8) {
      ZStack {
        LazyImage(url: coverURL) { state in
          if let image = state.image {
            image.resizable().aspectRatio(contentMode: .fill)
          } else {
            Image(systemName: "book.closed.fill")
              .resizable()
              .scaledToFit()
              .padding(8)
              .foregroundStyle(.secondary)
              .background(.quaternary)
          }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        Circle()
          .trim(from: 0, to: min(1, max(0, progress)))
          .stroke(progress >= 1 ? Color.green : Color.orange, lineWidth: 2)
          .frame(width: 48, height: 48)
          .rotationEffect(.degrees(-90))
          .opacity(progress > 0.01 ? 1 : 0)
      }
      .frame(width: 48, height: 48)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(title)
            .font(.caption2)
            .fontWeight(.medium)
            .lineLimit(2)
          if isDownloaded {
            Image(systemName: "applewatch.and.arrow.forward")
              .font(.footnote)
              .foregroundStyle(.green)
          }
        }
        if let author {
          Text(author)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func progress(value: Double, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ProgressView(value: min(1, max(0, value)))
        .tint(value >= 1 ? .green : .orange)
      Text(label)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private func transferProgress(
    value: WatchTransferByteProgress,
    label: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ProgressView(value: value.fraction)
        .tint(value.isComplete ? .green : .blue)
      Text(label)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

extension WatchPhoneLibraryBook {
  var progress: Double {
    guard duration > 0 else { return 0 }
    return min(1, max(0, currentTime / duration))
  }
}

extension PhoneDownloadsView {
  final class Model: ObservableObject {
    @Published private(set) var books: [WatchPhoneLibraryBook] = []
    @Published private var localBooks: [WatchBook] = []
    @Published private var jobs: [WatchTransferJob] = []
    @Published private var transferByteProgress: [String: WatchTransferByteProgress] = [:]
    @Published private var pendingTransferBookIDs: Set<String> = []

    private let connectivityManager = WatchConnectivityManager.shared
    private let localStorage = LocalBookStorage.shared
    private var cancellables = Set<AnyCancellable>()

    var localInProgress: [WatchBook] { sortedLocal(localBooks.filter { $0.progress < 1 }) }
    var localFinished: [WatchBook] { sortedLocal(localBooks.filter { $0.progress >= 1 }) }
    var phoneInProgress: [WatchPhoneLibraryBook] {
      sortedPhone(phoneOnly.filter { $0.progress > 0 && $0.progress < 1 })
    }
    var phoneNotStarted: [WatchPhoneLibraryBook] { sortedPhone(phoneOnly.filter { $0.progress <= 0 }) }
    var phoneFinished: [WatchPhoneLibraryBook] { sortedPhone(phoneOnly.filter { $0.progress >= 1 }) }
    var isEmpty: Bool { localBooks.isEmpty && books.isEmpty }

    private var phoneOnly: [WatchPhoneLibraryBook] {
      books.filter { !isOnWatch(bookID: $0.bookID) }
    }

    init() {
      connectivityManager.$phoneDownloadedBooks
        .receive(on: DispatchQueue.main)
        .assign(to: &$books)
      connectivityManager.$watchTransferJobs
        .receive(on: DispatchQueue.main)
        .assign(to: &$jobs)
      connectivityManager.$watchTransferByteProgress
        .receive(on: DispatchQueue.main)
        .assign(to: &$transferByteProgress)
      connectivityManager.$durablyRequestedBookIDs
        .receive(on: DispatchQueue.main)
        .assign(to: &$pendingTransferBookIDs)
      Timer.publish(every: 1, on: .main, in: .common)
        .autoconnect()
        .sink { [weak self] _ in
          guard let self, self.hasActiveTransfer else { return }
          self.objectWillChange.send()
        }
        .store(in: &cancellables)
      localStorage.$books
        .receive(on: DispatchQueue.main)
        .assign(to: &$localBooks)
      NotificationCenter.default.publisher(for: .watchCatalogArtworkUpdated)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &cancellables)
    }

    func refresh() { connectivityManager.requestPhoneDownloads() }

    func play(_ book: WatchBook) {
      PlayerManager.shared.setCurrent(book)
      PlayerManager.shared.isShowingFullPlayer = true
    }

    func remove(_ book: WatchBook) {
      DownloadManager.shared.deleteDownload(for: book.id)
    }

    func actionTitle(for book: WatchPhoneLibraryBook) -> String {
      if job(for: book.bookID) == nil, pendingTransferBookIDs.contains(book.bookID) {
        return "Scheduling…"
      }
      guard let job = job(for: book.bookID) else { return "Transfer" }
      switch job.state {
      case .queued, .transferring: return "Cancel"
      case .failed: return "Retry"
      case .completed: return "Finishing"
      case .cancelled: return "Transfer"
      }
    }

    func actionEnabled(for book: WatchPhoneLibraryBook) -> Bool {
      if pendingTransferBookIDs.contains(book.bookID), job(for: book.bookID) == nil {
        return false
      }
      return job(for: book.bookID)?.state != .completed
    }

    func stateText(for book: WatchPhoneLibraryBook) -> String {
      if job(for: book.bookID) == nil, pendingTransferBookIDs.contains(book.bookID) {
        return "Scheduling on iPhone…"
      }
      guard let job = job(for: book.bookID) else { return "Ready to transfer" }
      switch job.state {
      case .queued:
        return "Queued on iPhone"
      case .transferring:
        if job.sentFileCount == 0 {
          return "Scheduled · \(job.totalFileCount) files pending delivery"
        }
        return "Transferring · \(job.sentFileCount) of \(job.totalFileCount) files"
      case .failed: return "Transfer failed"
      case .completed: return "Finishing on Watch"
      case .cancelled: return "Transfer cancelled"
      }
    }

    func transferProgress(for book: WatchPhoneLibraryBook) -> WatchTransferByteProgress? {
      guard let job = job(for: book.bookID) else { return nil }
      return transferByteProgress[job.transferID]
    }

    func transferProgressText(_ progress: WatchTransferByteProgress) -> String {
      let received = megabytes(progress.receivedByteCount)
      let total = megabytes(progress.totalByteCount)
      let percentage = Int((progress.fraction * 100).rounded())
      return "\(received) / \(total) MB · \(percentage)% transferred"
    }

    func progressText(current: TimeInterval, duration: TimeInterval) -> String {
      guard duration > 0 else { return "Not started" }
      let value = min(1, max(0, current / duration))
      if value >= 1 { return "Finished" }
      if value <= 0 { return "Not started" }
      return "\(Int(value * 100))% listened"
    }

    func catalogArtworkURL(for bookID: String) -> URL? {
      let url = URL.documentsDirectory.appendingPathComponent("catalog-artwork/\(bookID).jpg")
      return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func performAction(for book: WatchPhoneLibraryBook) {
      guard let job = job(for: book.bookID) else {
        connectivityManager.requestWatchTransfer(bookID: book.bookID)
        return
      }

      switch job.state {
      case .queued, .transferring:
        connectivityManager.cancelWatchTransfer(bookID: book.bookID)
      case .failed, .cancelled:
        connectivityManager.requestWatchTransfer(bookID: book.bookID)
      case .completed:
        break
      }
    }

    private var hasActiveTransfer: Bool {
      jobs.contains { job in
        job.state == .queued || job.state == .transferring
      }
    }

    private func megabytes(_ byteCount: Int64) -> String {
      let value = Double(byteCount) / 1_000_000
      if value >= 100 {
        return String(format: "%.0f", value)
      }
      if value >= 10 {
        return String(format: "%.1f", value)
      }
      return String(format: "%.2f", value)
    }

    private func isOnWatch(bookID: String) -> Bool {
      localBooks.first(where: { $0.id == bookID })?.isDownloaded == true
    }

    private func job(for bookID: String) -> WatchTransferJob? {
      jobs.filter { $0.bookID == bookID }.max { $0.updatedAt < $1.updatedAt }
    }

    private func sortedLocal(_ values: [WatchBook]) -> [WatchBook] {
      values.sorted {
        let lhsDate = connectivityManager.progressUpdatedAt[$0.id] ?? 0
        let rhsDate = connectivityManager.progressUpdatedAt[$1.id] ?? 0
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    }

    private func sortedPhone(_ values: [WatchPhoneLibraryBook]) -> [WatchPhoneLibraryBook] {
      values.sorted {
        let lhsDate = $0.lastPlayedAt ?? .distantPast
        let rhsDate = $1.lastPlayedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    }
  }
}
