import Testing

@testable import Models

@Suite("Widget stats")
struct WidgetStatsDataTests {
  @Test("goal progress is capped at one")
  func goalProgressIsCapped() {
    let stats = WidgetStatsData(
      todayTime: 7_200,
      dailyGoalMinutes: 30,
      weekData: [],
      days: [:],
      daysInARow: 0
    )

    #expect(stats.goalProgress == 1)
  }

  @Test("week total sums day entries")
  func weekTotalSumsEntries() {
    let stats = WidgetStatsData(
      todayTime: 0,
      dailyGoalMinutes: 30,
      weekData: [
        .init(date: "2026-07-01", label: "Wed", timeInSeconds: 60),
        .init(date: "2026-07-02", label: "Thu", timeInSeconds: 120),
      ],
      days: [:],
      daysInARow: 0
    )

    #expect(stats.weekTotal == 180)
  }
}
