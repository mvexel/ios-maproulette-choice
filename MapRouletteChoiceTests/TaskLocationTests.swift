import CoreLocation
import MapRoulette
import Testing

@testable import MapRouletteChoice

@Suite struct TaskLocationTests {
  private func task(_ id: Int64, lng: Double?, lat: Double?) throws -> LocatedTask {
    let location: JSONValue? = lng.flatMap { lng in
      lat.map { .object(["type": .string("Point"), "coordinates": .array([.number(lng), .number($0)])]) }
    }
    return LocatedTask(
      MapRouletteTask(id: try TaskID(id), challengeID: try ChallengeID(3), name: "t\(id)", location: location))
  }

  @Test func readsLocationPoint() throws {
    let t = try task(1, lng: -111.89, lat: 40.76)
    #expect(t.coordinate?.latitude == 40.76)
    #expect(t.coordinate?.longitude == -111.89)
  }

  @Test func fallsBackToGeometryPoint() throws {
    let geometry: JSONValue = .object([
      "type": .string("FeatureCollection"),
      "features": .array([
        .object(["geometry": .object(["type": .string("Point"), "coordinates": .array([.integer(5), .integer(52)])])])
      ]),
    ])
    let t = LocatedTask(MapRouletteTask(id: try TaskID(1), challengeID: try ChallengeID(3), name: "t", geometry: geometry))
    #expect(t.coordinate?.latitude == 52)
    #expect(TaskLocation.point(.object(["type": .string("Point"), "coordinates": .array([.number(0), .number(91)])])) == nil)
  }

  @Test func sortsNearestFirstWithUnlocatedLast() throws {
    let here = CLLocationCoordinate2D(latitude: 40.76, longitude: -111.89)
    let far = try task(1, lng: -111.70, lat: 40.76)
    let near = try task(2, lng: -111.891, lat: 40.76)
    let nowhere = try task(3, lng: nil, lat: nil)
    let mid = try task(4, lng: -111.80, lat: 40.76)
    #expect(TaskLocation.sorted([nowhere, far, near, mid], from: here).map(\.id) == [2, 4, 1, 3])
    #expect(TaskLocation.sorted([nowhere, far, near, mid], from: nil).map(\.id) == [1, 2, 3, 4])
  }

  @Test func mapOrderIsNearestFirstWithALocation() throws {
    let here = CLLocationCoordinate2D(latitude: 40.76, longitude: -111.89)
    let far = try task(1, lng: -111.70, lat: 40.76)
    let near = try task(2, lng: -111.891, lat: 40.76)
    let mid = try task(4, lng: -111.80, lat: 40.76)
    #expect(TaskLocation.mapOrder([far, mid, near], from: here).map(\.id) == [2, 4, 1])
  }

  @Test func mapOrderIsTopToBottomWithoutALocation() throws {
    let south = try task(1, lng: -111.89, lat: 40.70)
    let north = try task(2, lng: -111.89, lat: 40.80)
    let middleEast = try task(3, lng: -111.80, lat: 40.75)
    let middleWest = try task(4, lng: -111.95, lat: 40.75)
    let nowhere = try task(5, lng: nil, lat: nil)
    #expect(TaskLocation.mapOrder([nowhere, south, middleEast, north, middleWest], from: nil).map(\.id) == [2, 4, 3, 1, 5])
  }

  @MainActor @Test func pinStatesReadTheirState() {
    typealias Pin = TaskMapView.Pin
    #expect(Pin(done: false, pending: false) == .toCheck)
    #expect(Pin(done: false, pending: true) == .toCheck)
    #expect(Pin(done: true, pending: false) == .done)
    #expect(Pin(done: true, pending: true) == .pending)
    #expect(Pin.toCheck.accessibilityValue == "To check")
    #expect(Pin.toCheck.accessibilityHint == "Opens the questions")
    #expect(Pin.done.accessibilityValue == "Already checked")
    #expect(Pin.done.accessibilityHint == nil)
    #expect(Pin.pending.accessibilityValue == "Saved, not on the map yet")
    #expect(Pin.pending.accessibilityHint == nil)
    // The callout keeps its instruction for sighted users.
    #expect(Pin.toCheck.calloutSubtitle == "Tap to answer")
    #expect([Pin.toCheck, .done, .pending].map(\.imageName) == ["PinTodo", "PinDone", "PinPending"])
  }
}
