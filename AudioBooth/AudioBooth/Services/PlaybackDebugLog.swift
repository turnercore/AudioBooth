import Foundation

enum PlaybackDebugLog {
  private static let queue = DispatchQueue(label: "playback-debug-log")

  static var url: URL? {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("playback-debug.log")
  }

  static func reset() {
    guard let url else { return }
    try? FileManager.default.removeItem(at: url)
    write("reset")
  }

  static func write(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    queue.async {
      guard let url, let data = line.data(using: .utf8) else { return }
      if FileManager.default.fileExists(atPath: url.path),
        let handle = try? FileHandle(forWritingTo: url)
      {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
      } else {
        try? data.write(to: url, options: .atomic)
      }
    }
  }
}
