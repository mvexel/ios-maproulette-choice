import CoreLocation

/// The live line under the task map (design/which-one-spec.md §C): where the place is from here,
/// using the phone's facing when the compass is good enough.
enum DirectionLine {
  /// Worse than this, the line says the location is rough.
  static let roughAccuracy: CLLocationAccuracy = 25
  /// Closer than this (or inside the accuracy radius), "You're at it".
  static let atItDistance: CLLocationDistance = 5

  /// The line, or nil while there is no location. `heading` is the facing in degrees (0 = north),
  /// nil without a usable compass reading. `us` picks feet and miles.
  static func text(
    from you: CLLocationCoordinate2D?, accuracy: CLLocationAccuracy, heading: Double?,
    to place: CLLocationCoordinate2D, noun: Noun, us: Bool
  ) -> String? {
    guard let you, accuracy >= 0 else { return nil }
    if accuracy > roughAccuracy { return "Your location is rough right now. Use the map to find the big pin." }
    let meters = TaskLocation.meters(you, place)
    if meters < atItDistance || meters < accuracy { return "You're at it. It's the \(noun.one) at the big pin." }
    let d = distance(meters, us: us)
    let bearing = TaskLocation.bearing(from: you, to: place)
    guard let heading else { return "\(d) \(TaskLocation.compass(bearing)) of you" }
    return "\(d) \(relative(bearing - heading))"
  }

  /// The words for a target at `angle` degrees from where the phone faces (negative is left).
  static func relative(_ angle: Double) -> String {
    let a = (angle.truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
    let side = a < 0 ? "left" : "right"
    switch abs(a) {
    case ...25: return "ahead"
    case ...60: return "ahead, slightly \(side)"
    case ...120: return "to your \(side)"
    case ...155: return "behind you, to the \(side)"
    default: return "behind you"
    }
  }

  /// US: feet under 1000 ft (to 5 ft under 100, else to 10), then miles to one decimal. Metric:
  /// metres (to 1 m under 10, 5 m under 100, else 10 m), then km to one decimal.
  static func distance(_ meters: CLLocationDistance, us: Bool) -> String {
    if us {
      let feet = meters * 3.28084
      if feet < 1000 {
        let step = feet < 100 ? 5.0 : 10.0
        return "\(Int((feet / step).rounded() * step)) ft"
      }
      return "\(oneDecimal(meters / 1609.344)) mi"
    }
    if meters < 1000 {
      let step = meters < 10 ? 1.0 : meters < 100 ? 5.0 : 10.0
      return "\(Int((meters / step).rounded() * step)) m"
    }
    return "\(oneDecimal(meters / 1000)) km"
  }

  /// The phone's measurement system: only the US one uses feet here (design/which-one-spec.md §C).
  static var usesFeet: Bool { Locale.current.measurementSystem == .us }

  /// What VoiceOver announces when the line changes: its kind, not every distance change, so a
  /// walk doesn't talk over everything else.
  static func announcementKind(_ line: String?) -> String? {
    guard let line else { return nil }
    if line.hasPrefix("You're at it") || line.hasPrefix("Your location is rough") { return line }
    // "25 ft northeast of you" → "northeast of you"; "8 m ahead, slightly left" → "ahead, slightly left".
    return line.split(separator: " ", maxSplits: 2).dropFirst(2).first.map(String.init)
  }

  private static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }
}
