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
    #expect(CampaignLink.challenge(from: URL(string: "https://streettally.osm.lol/challenge/3")!) == 3)
    #expect(CampaignLink.webURL(123, host: "streettally.osm.lol").absoluteString
      == "https://streettally.osm.lol/challenge/123")
    #expect(CampaignLink.challenge(from: CampaignLink.webURL(123)) == 123)
  }
}

@Suite struct NounTests {
  @Test func derivesNounFromIdentityTag() {
    #expect(Noun.from(match: ["highway": "bus_stop"]).one == "stop")
    #expect(Noun.from(match: ["amenity": "bench"]).count(2) == "2 benches")
    #expect(Noun.from(match: ["amenity": "bench"]).count(1) == "1 bench")
    #expect(Noun.from(match: ["shop": "bakery"]) == .place)
    // Woodbine: any entrance value (design/woodbine-campaign.md).
    #expect(Noun.from(match: ["entrance": "main"]).count(2) == "2 entrances")
    #expect(Noun.from(match: ["building": "yes"]).aOne == "a building")
    #expect(Noun.from(match: ["building": "house"]).count(2) == "2 buildings")
    #expect(Noun.from(match: ["highway": "crossing"]).count(2) == "2 crossings")
    #expect(Noun.from(match: ["entrance": "yes"]).one == "entrance")
    #expect(Noun.from(match: ["entrance": "main"]).aOne == "an entrance")
    #expect(Noun.from(match: ["highway": "bus_stop"]).aOne == "a stop")
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

  @Test func directionUsesEightCompassPoints() {
    let here = CLLocationCoordinate2D(latitude: 40.76, longitude: -111.89)
    let northeast = CLLocationCoordinate2D(latitude: 40.761, longitude: -111.8887)
    let west = CLLocationCoordinate2D(latitude: 40.76, longitude: -111.892)
    #expect(TaskLocation.compass(TaskLocation.bearing(from: here, to: northeast)) == "northeast")
    #expect(TaskLocation.compass(TaskLocation.bearing(from: here, to: west)) == "west")
    #expect(TaskLocation.compass(359) == "north" && TaskLocation.compass(-90) == "west")
    #expect(TaskLocation.rowText(here, west)?.hasSuffix(" · west") == true)
    #expect(TaskLocation.fromYouText(here, northeast)?.hasSuffix(" northeast of you") == true)
    #expect(TaskLocation.rowText(nil, west) == nil)
    #expect(TaskLocation.directionText(here, west)?.hasSuffix(" west") == true)
    #expect(Wording.next(.place, distance: TaskLocation.directionText(here, west), hasOrigin: true).hasPrefix("Next nearest place · "))
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
  private func challenge(
    _ id: Int64, type: Int?, tags: [String]? = nil, enabled: Bool? = nil, archived: Bool? = nil
  ) throws -> Challenge {
    Challenge(
      id: try ChallengeID(id), projectID: try ProjectID(1), name: "c\(id)", tags: tags, enabled: enabled,
      archived: archived, cooperativeType: type)
  }

  @Test func onlyTaggedChoiceChallenges() throws {
    let untagged = try challenge(1, type: 3)
    let tagged = try challenge(2, type: 3, tags: ["mobile-survey-v1"])
    let other = try challenge(3, type: 1, tags: ["mobile-survey-v1"])
    let archived = try challenge(4, type: 3, archived: true)
    #expect(ChallengePickerView.published([untagged, other, archived]).isEmpty)
    #expect(ChallengePickerView.published([untagged, tagged, other]).map(\.id.value) == [2])
  }

  /// Until the server filters drafts (backend #13), the list leaves out a disabled campaign itself.
  @Test func draftsAreLeftOut() throws {
    let draft = try challenge(5, type: 3, tags: ["mobile-survey-v1"], enabled: false)
    let live = try challenge(6, type: 3, tags: ["mobile-survey-v1"], enabled: true)
    #expect(ChallengePickerView.published([draft, live]).map(\.id.value) == [6])
  }
}

@Suite struct PlaceNameTests {
  private func task(_ properties: [String: JSONValue]) throws -> MapRouletteTask {
    let geometry: JSONValue = .object([
      "type": .string("FeatureCollection"),
      "features": .array([.object(["type": .string("Feature"), "properties": .object(properties)])]),
    ])
    return MapRouletteTask(id: try TaskID(9), challengeID: try ChallengeID(3), name: "node/123", geometry: geometry)
  }

  @Test func prefersNameThenRefThenNoun() throws {
    let stop = Noun(one: "stop", many: "stops")
    #expect(Wording.placeName(try task(["name": .string("300 S & Main")]), stop) == "300 S & Main")
    #expect(Wording.placeName(try task(["ref": .string("12345")]), stop) == "Stop 12345")
    #expect(Wording.placeName(try task(["@id": .string("node/123")]), stop) == "Stop")
  }
}
