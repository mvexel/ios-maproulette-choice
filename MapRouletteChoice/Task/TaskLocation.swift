import CoreLocation
import MapRoulette

/// A task the app can answer in place, with where it is.
struct LocatedTask: Identifiable, Hashable {
  let task: MapRouletteTask
  let coordinate: CLLocationCoordinate2D?
  var id: Int64 { task.id.value }

  init(_ task: MapRouletteTask) {
    self.task = task
    coordinate = TaskLocation.coordinate(task)
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

  static func distance(_ meters: CLLocationDistance) -> String {
    let style = Measurement(value: meters, unit: UnitLength.meters)
    return style.formatted(.measurement(width: .abbreviated, usage: .road))
  }
}
