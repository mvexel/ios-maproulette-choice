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
}
