import Foundation

public final class SharesService {
  private let audiobookshelf: Audiobookshelf

  init(audiobookshelf: Audiobookshelf) {
    self.audiobookshelf = audiobookshelf
  }

  public func createMediaItemShare(
    mediaItemID: String,
    slug: String,
    expiresAt: Date,
    isDownloadable: Bool = true
  ) async throws -> MediaItemShare {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    let body = CreateMediaItemShareRequest(
      slug: slug,
      mediaItemType: "book",
      mediaItemID: mediaItemID,
      expiresAt: Int64(expiresAt.timeIntervalSince1970 * 1_000),
      isDownloadable: isDownloadable
    )
    let request = NetworkRequest<MediaItemShare>(
      path: "/api/share/mediaitem",
      method: .post,
      body: body
    )
    return try await networkService.send(request).value
  }

  public func deleteMediaItemShare(id: String) async throws {
    guard let networkService = audiobookshelf.networkService else {
      throw Audiobookshelf.AudiobookshelfError.networkError(
        "Network service not configured. Please login first."
      )
    }

    let request = NetworkRequest<Data>(
      path: "/api/share/mediaitem/\(id)",
      method: .delete
    )
    _ = try await networkService.send(request)
  }
}

struct CreateMediaItemShareRequest: Codable, Equatable {
  let slug: String
  let mediaItemType: String
  let mediaItemID: String
  let expiresAt: Int64
  let isDownloadable: Bool

  enum CodingKeys: String, CodingKey {
    case slug, mediaItemType, expiresAt, isDownloadable
    case mediaItemID = "mediaItemId"
  }
}
