import PlayerIntents
import SwiftUI

extension Color {
  static var widgetAccent: Color {
    guard let raw = UserDefaults(suiteName: "group.com.turnercore.audioBS")?.string(forKey: "accentColor"),
      let color = Color(rawValue: raw)
    else {
      return .accentColor
    }
    return color
  }
}
