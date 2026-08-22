import API
import Foundation

final class EbooksContentModel: EbooksContent.Model {
  private let bookID: String

  init(
    ebooks: [EbooksContent.SupplementaryEbook],
    bookID: String
  ) {
    self.bookID = bookID
    super.init(ebooks: ebooks)
  }

  override func onEbookTapped(_ ebook: EbooksContent.SupplementaryEbook) {
    guard let url = ebook.url(for: bookID) else {
      Toast(error: "Unable to open ebook").show()
      return
    }

    ebookReader = EbookReaderViewModel(source: .temporary(url, headers: ebook.authorizationHeaders))
  }
}

extension EbooksContent.SupplementaryEbook {
  func url(for bookID: String) -> URL? {
    guard let serverURL = Audiobookshelf.shared.serverURL else {
      return nil
    }

    return serverURL.appendingPathComponent("api/items/\(bookID)/file/\(ino)")
  }

  var authorizationHeaders: [String: String] {
    guard let server = Audiobookshelf.shared.authentication.server else {
      return [:]
    }

    var headers = server.customHeaders
    headers["Authorization"] = server.token.bearer
    return headers
  }
}
