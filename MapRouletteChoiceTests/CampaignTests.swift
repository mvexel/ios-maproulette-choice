import CoreLocation
import Foundation
import MapRoulette
import Testing

@testable import MapRouletteChoice

@Suite struct CampaignLinkTests {
  @Test func parsesSchemeAndHTTPSLinks() {
    #expect(CampaignLink.challenge(from: URL(string: "mrchoice://challenge/42")!) == 42)
    #expect(CampaignLink.challenge(from: URL(string: "MRCHOICE://challenge/42/")!) == 42)
    #expect(CampaignLink.challenge(from: URL(string: "https://example.org/challenge/7")!) == 7)
    #expect(CampaignLink.challenge(from: URL(string: "mrchoice://challenge/0")!) == nil)
    #expect(CampaignLink.challenge(from: URL(string: "mrchoice://task/42")!) == nil)
    #expect(CampaignLink.challenge(from: URL(string: "http://example.org/challenge/7")!) == nil)
    #expect(CampaignLink.challenge(from: CampaignLink.url(123)) == 123)
  }
}

@Suite struct NounTests {
  @Test func derivesNounFromIdentityTag() {
    #expect(Noun.from(match: ["highway": "bus_stop"]).one == "stop")
    #expect(Noun.from(match: ["amenity": "bench"]).count(2) == "2 benches")
    #expect(Noun.from(match: ["amenity": "bench"]).count(1) == "1 bench")
    #expect(Noun.from(match: ["shop": "bakery"]) == .place)
    #expect(Noun.from(match: [:]).One == "Place")
  }
}

@MainActor @Suite struct CampaignStoreTests {
  private func store(day: Int = 10) -> (CampaignStore, UserDefaults) {
    let defaults = UserDefaults(suiteName: "CampaignStoreTests.\(UUID())")!
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Denver")!
    let date = c.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 20))!
    return (CampaignStore(defaults: defaults, now: { date }, calendar: c), defaults)
  }

  @Test func countsEachTaskOncePerDay() {
    let (s, defaults) = store()
    s.recordChecked(3, task: 100)
    s.recordChecked(3, task: 100)
    s.recordChecked(3, task: 101)
    s.recordChecked(4, task: 200)
    #expect(s.checkedToday(3) == 2)
    #expect(s.checkedToday(4) == 1)
    #expect(s.justDone == [100, 101, 200])
    let tomorrow = CampaignStore(defaults: defaults, now: { Date().addingTimeInterval(86_400 * 400) })
    #expect(tomorrow.checkedToday(3) == 0)
  }

  @Test func remembersCampaignAndWelcome() {
    let (s, defaults) = store()
    #expect(s.lastCampaign == nil)
    s.lastCampaign = 3
    #expect(CampaignStore(defaults: defaults).lastCampaign == 3)
    #expect(!s.hasSeenWelcome(3))
    s.markWelcomeSeen(3)
    s.markWelcomeSeen(3)
    #expect(s.hasSeenWelcome(3))
    #expect(!s.hasSeenWelcome(4))
  }
}

@Suite struct NearestTests {
  private func task(_ id: Int64, lng: Double, status: Int = 0) throws -> LocatedTask {
    LocatedTask(
      MapRouletteTask(
        id: try TaskID(id), challengeID: try ChallengeID(3), name: "t\(id)", status: TaskStatus(code: status),
        location: .object(["type": .string("Point"), "coordinates": .array([.number(lng), .number(40.76)])])))
  }

  @Test func picksNearestNotExcluded() throws {
    // Without a choice payload these tasks are not open; nearest() only offers open tasks.
    let here = CLLocationCoordinate2D(latitude: 40.76, longitude: -111.89)
    let tasks = [try task(1, lng: -111.80), try task(2, lng: -111.891)]
    #expect(TaskLocation.nearest(from: here, in: tasks, excluding: []) == nil)
    #expect(tasks.allSatisfy { !$0.isDone })
    #expect(try task(3, lng: 0, status: 1).isDone)
    #expect(TaskLocation.distanceText(here, nil) == nil)
  }

  @Test func offersOpenChoiceTaskAndNamesIt() async throws {
    let t = LocatedTask(try await makeTask())
    #expect(t.isOpen)
    #expect(TaskLocation.nearest(from: nil, in: [t], excluding: []) == t)
    #expect(TaskLocation.nearest(from: nil, in: [t], excluding: [42]) == nil)
    #expect(Noun.from([t.task]).one == "bench")
  }
}

@Suite struct PublishedTests {
  private func challenge(_ id: Int64, type: Int?, tags: [String]? = nil, archived: Bool? = nil) throws -> Challenge {
    Challenge(
      id: try ChallengeID(id), projectID: try ProjectID(1), name: "c\(id)", tags: tags, archived: archived,
      cooperativeType: type)
  }

  @Test func prefersTaggedChoiceChallenges() throws {
    let untagged = try challenge(1, type: 3)
    let tagged = try challenge(2, type: 3, tags: ["mobile-survey-v1"])
    let other = try challenge(3, type: 1, tags: ["mobile-survey-v1"])
    let archived = try challenge(4, type: 3, archived: true)
    #expect(ChallengePickerView.published([untagged, other, archived]).map(\.id.value) == [1])
    #expect(ChallengePickerView.published([untagged, tagged, other]).map(\.id.value) == [2])
  }
}
