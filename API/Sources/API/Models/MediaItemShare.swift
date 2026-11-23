import Foundation

/// An Audiobookshelf 2.36 media-item share created by an authenticated administrator.
public struct MediaItemShare: Codable, Equatable, Sendable {
  public let id: String
  public let slug: String
  public let mediaItemID: String?
  public let mediaItemType: String?
  public let expiresAt: Date
  public let isDownloadable: Bool

  enum CodingKeys: String, CodingKey {
    case id, slug, expiresAt, isDownloadable
    case mediaItemID = "mediaItemId"
    case mediaItemType
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    slug = try container.decode(String.self, forKey: .slug)
    mediaItemID = try container.decodeIfPresent(String.self, forKey: .mediaItemID)
    mediaItemType = try container.decodeIfPresent(String.self, forKey: .mediaItemType)
    isDownloadable = try container.decode(Bool.self, forKey: .isDownloadable)

    if let milliseconds = try? container.decode(Int64.self, forKey: .expiresAt) {
      expiresAt = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    } else if let milliseconds = try? container.decode(Double.self, forKey: .expiresAt) {
      expiresAt = Date(timeIntervalSince1970: milliseconds / 1_000)
    } else {
      let value = try container.decode(String.self, forKey: .expiresAt)
      guard let date = Self.iso8601Date(from: value) else {
        throw DecodingError.dataCorruptedError(
          forKey: .expiresAt,
          in: container,
          debugDescription: "Expected an ISO-8601 date or Unix milliseconds."
        )
      }
      expiresAt = date
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(slug, forKey: .slug)
    try container.encodeIfPresent(mediaItemID, forKey: .mediaItemID)
    try container.encodeIfPresent(mediaItemType, forKey: .mediaItemType)
    try container.encode(Int64(expiresAt.timeIntervalSince1970 * 1_000), forKey: .expiresAt)
    try container.encode(isDownloadable, forKey: .isDownloadable)
  }

  private static func iso8601Date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }
}
