import API
import Foundation
import Logging
import Pulse
import PulseLogHandler
import UIKit

enum AppLogger {
  static let session = Logger(label: "session")
  static let watchConnectivity = Logger(label: "watch-connectivity")
  static let player = Logger(label: "player")
  static let download = Logger(label: "download")
  static let viewModel = Logger(label: "viewModel")
  static let general = Logger(label: "general")
  static let authentication = Logger(label: "authentication")
  static let crash = Logger(label: "crash")

  static func bootstrap() {
    configureNetworkLogger()

    LoggingSystem.bootstrap { label in
      var stream = StreamLogHandler.standardOutput(label: label)
      var persistent = PersistentLogHandler(label: label)

      stream.logLevel = .debug
      persistent.logLevel = .debug

      return MultiplexLogHandler([
        RedactingLogHandler(wrapped: stream),
        RedactingLogHandler(wrapped: persistent),
      ])
    }

    general.info("Version \(UIApplication.appVersion)")
  }

  private static func configureNetworkLogger() {
    NetworkLogger.shared = NetworkLogger { config in
      config.sensitiveHeaders = ["Authorization", "x-refresh-token", "Cookie", "Set-Cookie"]
      config.sensitiveQueryItems = ["token", "code", "code_verifier"]
      config.sensitiveDataFields = [
        "accessToken",
        "authOpenIDAuthorizationURL",
        "authOpenIDIssuerURL",
        "authOpenIDJwksURL",
        "authOpenIDLogoutURL",
        "authOpenIDTokenURL",
        "authOpenIDUserInfoURL",
        "email",
        "password",
        "refreshToken",
        "token",
        "username",
      ]
      config.willHandleEvent = { $0.redacted }
    }
  }
}

extension LoggerStore.Event {
  nonisolated var redacted: Self {
    switch self {
    case .messageStored, .networkTaskProgressUpdated:
      return self
    case .networkTaskCreated(let event):
      var event = event
      event.originalRequest = event.originalRequest.redacted
      event.currentRequest = event.currentRequest?.redacted
      return .networkTaskCreated(event)
    case .networkTaskCompleted(let event):
      var event = event
      event.originalRequest = event.originalRequest.redacted
      event.currentRequest = event.currentRequest?.redacted
      return .networkTaskCompleted(event)
    }
  }
}

struct RedactingLogHandler<Wrapped: LogHandler>: LogHandler {
  var wrapped: Wrapped

  var metadata: Logger.Metadata {
    get { wrapped.metadata }
    set { wrapped.metadata = newValue }
  }

  var logLevel: Logger.Level {
    get { wrapped.logLevel }
    set { wrapped.logLevel = newValue }
  }

  subscript(metadataKey key: String) -> Logger.Metadata.Value? {
    get { wrapped[metadataKey: key] }
    set { wrapped[metadataKey: key] = newValue }
  }

  func log(event: LogEvent) {
    var event = event
    event.message = Logger.Message(stringLiteral: event.message.description.redactingLogSecrets)
    wrapped.log(event: event)
  }
}

private extension String {
  var redactingLogSecrets: String {
    var value = redactingURLs
    let patterns = [
      #"(?i)(authorization|cookie|x-refresh-token|token|accessToken|refreshToken|code|code_verifier|code_challenge|state)=([^&\s,]+)"#,
      #"(?i)(authorization|cookie|x-refresh-token|token|accessToken|refreshToken|code|code_verifier|code_challenge|state):\s*([^,\s]+)"#,
    ]

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(value.startIndex..<value.endIndex, in: value)
      value = regex.stringByReplacingMatches(
        in: value,
        range: range,
        withTemplate: "$1=<redacted>"
      )
    }
    return value
  }
}

extension NetworkLogger.Request {
  nonisolated var redacted: Self {
    var copy = self
    copy.url = url?.redacted
    return copy
  }
}
