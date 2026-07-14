import Foundation
import Testing

@testable import Models

@Suite("Playback session URLs")
struct PlaybackSessionTests {
  @Test("uses a same-origin HLS reference returned by the server")
  func hlsReference() {
    let session = makeSession()
    let track = makeTrack(contentURLPath: "/hls/session/master.m3u8?token=signed")

    #expect(session.url(for: track)?.absoluteString == "https://example.com:8443/hls/session/master.m3u8?token=signed")
  }

  @Test("rejects a cross-origin absolute HLS URL")
  func crossOriginAbsoluteHLSURL() {
    let session = makeSession()
    let track = makeTrack(contentURLPath: "https://other.example/hls/session/master.m3u8")

    #expect(session.url(for: track)?.absoluteString == "https://example.com:8443/public/session/session-id/track/2")
  }

  @Test("rejects a same-origin absolute HLS URL")
  func sameOriginAbsoluteHLSURL() {
    let session = makeSession()
    let track = makeTrack(contentURLPath: "https://example.com:8443/hls/session/master.m3u8")

    #expect(session.url(for: track)?.absoluteString == "https://example.com:8443/public/session/session-id/track/2")
  }

  @Test("rejects a scheme-relative HLS URL")
  func schemeRelativeHLSURL() {
    let session = makeSession()
    let track = makeTrack(contentURLPath: "//other.example/hls/session/master.m3u8")

    #expect(session.url(for: track)?.absoluteString == "https://example.com:8443/public/session/session-id/track/2")
  }

  @Test("ignores a non-HLS content URL")
  func nonHLSReference() {
    let session = makeSession()
    let track = makeTrack(contentURLPath: "/media/file.mp3")

    #expect(session.url(for: track)?.absoluteString == "https://example.com:8443/public/session/session-id/track/2")
  }

  private func makeSession() -> PlaybackSession {
    PlaybackSession(
      libraryItemID: "book-id",
      startTime: 0,
      currentTime: 0,
      duration: 60,
      baseURL: URL(string: "https://example.com:8443/public/session/session-id")
    )
  }

  private func makeTrack(contentURLPath: String?) -> Track {
    Track(
      index: 2,
      startOffset: 0,
      duration: 60,
      contentURLPath: contentURLPath
    )
  }
}
