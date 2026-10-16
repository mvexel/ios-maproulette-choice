import CoreLocation
import Testing

@testable import MapRouletteChoice

/// Footprints from the map's tiles (design/which-one-sprint.md §3 E).
@Suite struct FootprintTests {
  let here = CLLocationCoordinate2D(latitude: 40.75, longitude: -111.9)

  /// A point `east` and `north` metres from `here`.
  func at(_ east: Double, _ north: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
      latitude: here.latitude + north / 111_320,
      longitude: here.longitude + east / (111_320 * cos(here.latitude * .pi / 180)))
  }

  /// A square `size` metres across with its south-west corner `east`, `north` from `here`.
  func square(_ east: Double, _ north: Double, _ size: Double = 10) -> [CLLocationCoordinate2D] {
    [at(east, north), at(east + size, north), at(east + size, north + size), at(east, north + size), at(east, north)]
  }

  func flat(_ ring: [CLLocationCoordinate2D]?) -> [Double]? { ring?.flatMap { [$0.latitude, $0.longitude] } }

  @Test func outlineHoldingThePointWins() {
    let holding = square(-5, -5)
    let next = square(6, -5)
    #expect(flat(Footprint.outline(for: here, in: [next, holding])) == flat(holding))
  }

  /// A centroid outside an L-shaped building still finds it, within 8 m.
  @Test func nearestOutlineWithinReach() {
    let near = square(3, -5)
    let far = square(-30, -5)
    #expect(flat(Footprint.outline(for: here, in: [far, near])) == flat(near))
    #expect(Footprint.outline(for: here, in: [square(9, -5)]) == nil)
  }

  /// The bar crosses the street at right angles, centred on the node, 12 m long.
  @Test func barAcrossTheStreet() throws {
    let eastWest = [at(-50, 1), at(50, 1)]
    let northSouth = [at(20, -50), at(20, 50)]
    let bar = try #require(Footprint.bar(for: here, streets: [northSouth, eastWest]))
    #expect(bar.count == 2)
    #expect(abs(TaskLocation.meters(bar[0], bar[1]) - 12) < 0.1)
    // North-south bar across an east-west street.
    #expect(abs(bar[0].longitude - bar[1].longitude) < 1e-7)
    #expect(abs((bar[0].latitude + bar[1].latitude) / 2 - here.latitude) < 1e-7)
    #expect(Footprint.bar(for: here, streets: [northSouth]) == nil)
  }

  @Test func nearestSegmentBearing() throws {
    let r = try #require(Footprint.nearest([at(0, -10), at(0, 10)], to: at(3, 0)))
    #expect(abs(r.distance - 3) < 0.01)
    #expect(abs(r.bearing - 0) < 0.01)
    #expect(Footprint.nearest([here], to: here) == nil)
  }

  @Test func containsUnclosedRing() {
    let ring = Array(square(-5, -5).dropLast())
    #expect(Footprint.contains(ring, here))
    #expect(!Footprint.contains(ring, at(6, 0)))
  }
}

