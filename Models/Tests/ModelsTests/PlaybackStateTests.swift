import Testing

@testable import Models

@Suite("Playback state")
struct PlaybackStateTests {
  @Test("progress is zero when duration is not positive")
  func progressWithoutDuration() {
    let state = PlaybackState(
      bookID: "book-1",
      title: "Title",
      author: "Author",
      coverURL: nil,
      currentTime: 42,
      duration: 0,
      isPlaying: true
    )

    #expect(state.progress == 0)
  }

  @Test("progress divides current time by duration")
  func progressWithDuration() {
    let state = PlaybackState(
      bookID: "book-1",
      title: "Title",
      author: "Author",
      coverURL: nil,
      currentTime: 30,
      duration: 120,
      isPlaying: false
    )

    #expect(state.progress == 0.25)
  }
}
