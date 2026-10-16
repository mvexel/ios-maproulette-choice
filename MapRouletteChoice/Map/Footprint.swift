import CoreLocation
import MapRoulette

/// Footprints, not dots (design/which-one-sprint.md §3 E): a building draws its outline and a
/// crossing a bar across its street. The tasks carry only a point (a building's centroid, a
/// crossing's node), so the shapes come from the map's own vector tiles.
enum Footprint {
  enum Kind: Sendable { case point, building, crossing }

  /// What the close-up map draws for a campaign's places, from the task's identity tags.
  static func kind(_ task: MapRouletteTask) -> Kind {
    guard case .choice(let element, let match, _, _) = task.work() else { return .point }
    let properties = task.templateProperties()
    if (match["highway"] ?? properties["highway"]) == "crossing" { return .crossing }
    if element.type != .node, (match["building"] ?? properties["building"]) != nil { return .building }
    return .point
  }

  /// A building outline counts when it holds the point, or else passes within this of it (a
  /// centroid can fall outside an L-shaped building).
  static let buildingReach: CLLocationDistance = 8
  /// A crossing's street must pass within this of its node.
  static let streetReach: CLLocationDistance = 6
  /// The drawn bar's length: about a two-lane street.
  static let barLength: CLLocationDistance = 12

  /// The outline for `point`: the ring holding it, else the nearest within `buildingReach`.
  static func outline(for point: CLLocationCoordinate2D, in rings: [[CLLocationCoordinate2D]]) -> [CLLocationCoordinate2D]? {
    if let ring = rings.first(where: { contains($0, point) }) { return ring }
    return
      rings
      .compactMap { ring in nearest(ring, to: point).map { (ring, $0.distance) } }
      .filter { $0.1 <= buildingReach }
      .min { $0.1 < $1.1 }?.0
  }

  /// The bar for a crossing at `point`: across the nearest street line within `streetReach`.
  static func bar(for point: CLLocationCoordinate2D, streets: [[CLLocationCoordinate2D]]) -> [CLLocationCoordinate2D]? {
    guard
      let street = streets.compactMap({ nearest($0, to: point) }).filter({ $0.distance <= streetReach })
        .min(by: { $0.distance < $1.distance })
    else { return nil }
    return bar(through: point, across: street.bearing)
  }

  /// A `length` metre line centred on `point`, at right angles to a street running at `bearing`.
  static func bar(through point: CLLocationCoordinate2D, across bearing: Double, length: CLLocationDistance = barLength)
    -> [CLLocationCoordinate2D]
  {
    let side = (bearing + 90) * .pi / 180
    let half = length / 2
    let (east, north) = (sin(side) * half, cos(side) * half)
    return [offset(point, east: -east, north: -north), offset(point, east: east, north: north)]
  }

  /// Ray casting; a ring may or may not repeat its first point.
  static func contains(_ ring: [CLLocationCoordinate2D], _ p: CLLocationCoordinate2D) -> Bool {
    guard ring.count >= 3 else { return false }
    var inside = false
    var j = ring.count - 1
    for i in ring.indices {
      let (a, b) = (ring[i], ring[j])
      if (a.latitude > p.latitude) != (b.latitude > p.latitude),
        p.longitude < (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
      {
        inside.toggle()
      }
      j = i
    }
    return inside
  }

  /// The closest segment of `line` to `p`: its distance in metres and its bearing in degrees.
  static func nearest(_ line: [CLLocationCoordinate2D], to p: CLLocationCoordinate2D) -> (distance: Double, bearing: Double)? {
    guard line.count >= 2 else { return nil }
    // A local plane in metres around p: fine at street scale.
    let k = cos(p.latitude * .pi / 180)
    func xy(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
      ((c.longitude - p.longitude) * k * metersPerDegree, (c.latitude - p.latitude) * metersPerDegree)
    }
    var best: (distance: Double, bearing: Double)?
    for (a, b) in zip(line, line.dropFirst()) {
      let (pa, pb) = (xy(a), xy(b))
      let (dx, dy) = (pb.x - pa.x, pb.y - pa.y)
      let length2 = dx * dx + dy * dy
      guard length2 > 0 else { continue }
      let t = min(max(-(pa.x * dx + pa.y * dy) / length2, 0), 1)
      let distance = hypot(pa.x + t * dx, pa.y + t * dy)
      if distance < best?.distance ?? .infinity {
        best = (distance, (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360))
      }
    }
    return best
  }

  private static let metersPerDegree = 111_320.0

  private static func offset(_ c: CLLocationCoordinate2D, east: Double, north: Double) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
      latitude: c.latitude + north / metersPerDegree,
      longitude: c.longitude + east / (metersPerDegree * cos(c.latitude * .pi / 180)))
  }
}
