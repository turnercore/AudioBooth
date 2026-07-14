import Foundation
import SwiftData

@Model
public final class Chapter {
  public var id: Int
  public var start: TimeInterval
  public var end: TimeInterval
  public var title: String

  public init(id: Int, start: TimeInterval, end: TimeInterval, title: String) {
    self.id = id
    self.start = start
    self.end = end
    self.title = title
  }
}
