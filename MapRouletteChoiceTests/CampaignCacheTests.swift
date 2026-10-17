import Foundation
import MapRoulette
import Testing

@testable import MapRouletteChoice

/// The last campaign kept on the phone for dead spots (BACKLOG O2, design/offline-copy.md).
@MainActor @Suite struct CampaignCacheTests {
  private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("campaign-cache-\(UUID().uuidString).json")
  }

  private func snapshot(_ tasks: [MapRouletteTask]) async throws -> CampaignCache.Snapshot {
    CampaignCache.Snapshot(
      challenge: try await makeChallenge(), tasks: tasks, held: [43], heldReports: [44], offered: [42, 43, 44],
      truncated: false, savedAt: Date(timeIntervalSince1970: 1_000))
  }

  @Test func keepsOneCampaignAcrossLaunches() async throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let kept = try await snapshot([
      try await makeTask(id: 42), try await makeTask(id: 43, instruction: "Look up"), try await makeTask(id: 44, status: 1),
    ])
    CampaignCache(file: file).save(kept)

    let reopened = CampaignCache(file: file)
    let read = try #require(reopened.get(1))
    #expect(read == kept)
    #expect(read.tasks.map { ChoiceWork($0.work()) != nil } == [true, true, true])
    #expect(reopened.get(2) == nil)
    #expect(reopened.task(43)?.0 == kept.tasks[1])
    #expect(reopened.task(43)?.1.id.value == 1)
    #expect(reopened.task(99) == nil)
  }

  @Test func openingAnotherCampaignDropsTheCopy() async throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let cache = CampaignCache(file: file)
    cache.save(try await snapshot([try await makeTask()]))
    cache.keepOnly(1)
    #expect(cache.get(1) != nil)
    cache.keepOnly(2)
    #expect(cache.get(1) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func onlyNoConnectionShowsTheCopy() {
    #expect(CampaignCache.isOffline(MapRouletteError(.network)))
    #expect(CampaignCache.isOffline(URLError(.notConnectedToInternet)))
    #expect(!CampaignCache.isOffline(MapRouletteError(.server, status: 503)))
    #expect(!CampaignCache.isOffline(MapRouletteError(.notFound, status: 404)))
  }

  @Test func keptCopyCopy() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "America/Denver"))
    let locale = Locale(identifier: "en_US")
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 18, minute: 30)))
    func time(_ minutesAgo: Double) -> String {
      Wording.keptTime(now.addingTimeInterval(-minutesAgo * 60), now: now, calendar: calendar, locale: locale)
    }
    #expect(time(0.2) == "1 min ago")
    #expect(time(12) == "12 min ago")
    #expect(time(59) == "59 min ago")
    #expect(time(168).replacingOccurrences(of: "\u{202F}", with: " ") == "3:42 PM")
    #expect(time(60 * 20) == "yesterday")
    #expect(time(60 * 24 * 2) == "Oct 14")
    #expect(Wording.keptCopy("12 min ago") == "No signal. Showing the list from 12 min ago. Some may be done already.")
    #expect(Wording.notKeptNoSignal
      == "No signal, and this campaign isn't on your phone yet. Try again when you have signal.")
  }
}
