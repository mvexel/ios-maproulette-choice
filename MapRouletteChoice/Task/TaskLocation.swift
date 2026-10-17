import CoreLocation
import MapRoulette

/// A challenge task with where it is.
struct LocatedTask: Identifiable, Hashable {
  let task: MapRouletteTask
  let coordinate: CLLocationCoordinate2D?
  var id: Int64 { task.id.value }
  /// Answerable in place: a valid, open, unbundled choice task.
  let isOpen: Bool
  /// Already checked: fixed, not an issue or already fixed.
  let isDone: Bool

  /// Parses the place once: the campaign screen asks these of every place on every redraw.
  init(_ task: MapRouletteTask) {
    self.task = task
    coordinate = TaskLocation.coordinate(task)
    isOpen = task.mobileSupport() == .inPlace
    isDone = task.status.map { [1, 2, 5].contains($0.code) } ?? false
  }

  static func == (a: Self, b: Self) -> Bool { a.task == b.task }
  func hash(into hasher: inout Hasher) { hasher.combine(task) }
}

enum TaskLocation {
  /// The task's `location` (a GeoJSON Point), else the first Point in its geometry.
  static func coordinate(_ task: MapRouletteTask) -> CLLocationCoordinate2D? {
    if let point = point(task.location) { return point }
    guard case .object(let collection) = task.geometry, case .array(let features)? = collection["features"]
    else { return nil }
    for case .object(let feature) in features {
      if let point = point(feature["geometry"]) { return point }
    }
    return nil
  }

  /// `{"type": "Point", "coordinates": [lng, lat]}` with valid ranges.
  static func point(_ value: JSONValue?) -> CLLocationCoordinate2D? {
    guard case .object(let o)? = value, case .string("Point")? = o["type"],
      case .array(let c)? = o["coordinates"], c.count >= 2,
      let lng = number(c[0]), let lat = number(c[1]),
      (-90...90).contains(lat), (-180...180).contains(lng)
    else { return nil }
    return CLLocationCoordinate2D(latitude: lat, longitude: lng)
  }

  private static func number(_ value: JSONValue) -> Double? {
    switch value {
    case .number(let v): v.isFinite ? v : nil
    case .integer(let v): Double(v)
    default: nil
    }
  }

  /// Nearest first from `origin`; tasks without a location go last. Ties and the no-origin case
  /// keep task id order.
  static func sorted(_ tasks: [LocatedTask], from origin: CLLocationCoordinate2D?) -> [LocatedTask] {
    let byID = tasks.sorted { $0.id < $1.id }
    guard let origin else { return byID }
    let here = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
    let distances = Dictionary(
      uniqueKeysWithValues: byID.map { t in
        (t.id, t.coordinate.map { here.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) })
      })
    return byID.enumerated().sorted { a, b in
      switch (distances[a.element.id]!, distances[b.element.id]!) {
      case (let x?, let y?): x != y ? x < y : a.offset < b.offset
      case (.some, nil): true
      case (nil, .some): false
      case (nil, nil): a.offset < b.offset
      }
    }.map(\.element)
  }

  /// The order map pins are added in, which is the order VoiceOver reads them: nearest first
  /// from `origin`; without one, top to bottom (north to south), then west to east. Tasks
  /// without a location go last; ties keep task id order.
  static func mapOrder(_ tasks: [LocatedTask], from origin: CLLocationCoordinate2D?) -> [LocatedTask] {
    let byID = sorted(tasks, from: origin)
    guard origin == nil else { return byID }
    return byID.enumerated().sorted { a, b in
      switch (a.element.coordinate, b.element.coordinate) {
      case (let x?, let y?):
        x.latitude != y.latitude
          ? x.latitude > y.latitude : x.longitude != y.longitude ? x.longitude < y.longitude : a.offset < b.offset
      case (.some, nil): true
      case (nil, .some): false
      case (nil, nil): a.offset < b.offset
      }
    }.map(\.element)
  }

  /// The nearest open task to `origin` that is not in `excluding`; by id when `origin` is nil.
  static func nearest(from origin: CLLocationCoordinate2D?, in tasks: [LocatedTask], excluding: Set<Int64>)
    -> LocatedTask?
  {
    sorted(tasks.filter { $0.isOpen && !excluding.contains($0.id) }, from: origin).first
  }

  /// A box around `points`, padded by about 50 m, for bounds searches; nil without points.
  static func bounds(_ points: [CLLocationCoordinate2D]) -> Bounds? {
    guard let first = points.first else { return nil }
    var (south, north, west, east) = (first.latitude, first.latitude, first.longitude, first.longitude)
    for p in points.dropFirst() {
      (south, north) = (min(south, p.latitude), max(north, p.latitude))
      (west, east) = (min(west, p.longitude), max(east, p.longitude))
    }
    let pad = 0.0005
    return try? Bounds(
      west: max(west - pad, -180), south: max(south - pad, -90), east: min(east + pad, 180),
      north: min(north + pad, 90))
  }

  static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
    CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
  }

  /// "120 m" between two optional points, or nil.
  static func distanceText(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> String? {
    guard let a, let b else { return nil }
    return distance(meters(a, b))
  }

  /// "130 m · northeast": distance and compass direction from `a` to `b`, for list rows.
  static func rowText(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> String? {
    guard let a, let b else { return nil }
    return "\(distance(meters(a, b))) · \(compass(bearing(from: a, to: b)))"
  }

  /// "180 m northeast": distance and direction from `a` to `b`, for "Next nearest".
  static func directionText(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> String? {
    guard let a, let b else { return nil }
    return "\(distance(meters(a, b))) \(compass(bearing(from: a, to: b)))"
  }

  /// "130 m northeast of you", for the place header.
  static func fromYouText(_ you: CLLocationCoordinate2D?, _ place: CLLocationCoordinate2D?) -> String? {
    guard let you, let place else { return nil }
    return "\(distance(meters(you, place))) \(compass(bearing(from: you, to: place))) of you"
  }

  /// Initial great-circle bearing in degrees, 0 = north, clockwise.
  static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
    let (lat1, lat2) = (a.latitude * .pi / 180, b.latitude * .pi / 180)
    let dLon = (b.longitude - a.longitude) * .pi / 180
    let y = sin(dLon) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
    let degrees = atan2(y, x) * 180 / .pi
    return (degrees + 360).truncatingRemainder(dividingBy: 360)
  }

  /// One of the 8 compass points for a bearing in degrees.
  static func compass(_ degrees: Double) -> String {
    let points = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]
    let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    return points[Int((normalized + 22.5) / 45) % 8]
  }

  /// The one unit rule for every distance line (design/which-one-spec.md §C): feet and miles in
  /// the US only, metres and km everywhere else, the UK included.
  static func distance(_ meters: CLLocationDistance, us: Bool = DirectionLine.usesFeet) -> String {
    DirectionLine.distance(meters, us: us)
  }
}
