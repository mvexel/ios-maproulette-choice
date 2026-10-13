import CoreLocation

/// The live line under the task map (design/which-one-spec.md §C): where the place is from here,
/// using the phone's facing when the compass is good enough.
enum DirectionLine {
  /// Worse than this, the line says the location is rough.
  static let roughAccuracy: CLLocationAccuracy = 25
  /// Closer than this (or inside the accuracy radius), "You're at it".
  static let atItDistance: CLLocationDistance = 5

  /// Where the place is relative to the phone's facing, in the spec's sectors.
  enum Side: String, Sendable, CaseIterable {
    case ahead, slightlyLeft, slightlyRight, left, right, behindLeft, behindRight, behind

    var words: String {
      switch self {
      case .ahead: "ahead"
      case .slightlyLeft: "ahead, slightly left"
      case .slightlyRight: "ahead, slightly right"
      case .left: "to your left"
      case .right: "to your right"
      case .behindLeft: "behind you, to the left"
      case .behindRight: "behind you, to the right"
      case .behind: "behind you"
      }
    }

    /// The sector for a signed angle in degrees (negative is left): ±25° ahead, 25–60° slightly,
    /// 60–120° to the side, 120–155° behind to the side, beyond that behind.
    init(_ angle: Double) {
      let a = DirectionLine.signed(angle)
      let left = a < 0
      switch abs(a) {
      case ...25: self = .ahead
      case ...60: self = left ? .slightlyLeft : .slightlyRight
      case ...120: self = left ? .left : .right
      case ...155: self = left ? .behindLeft : .behindRight
      default: self = .behind
      }
    }
  }

  /// A side changes only once the angle is this far past the boundary, so a swinging compass
  /// doesn't flip the line (design/which-one-spec.md §C).
  static let hysteresis: Double = 10

  /// The side for `angle`, keeping `held` while the angle is within the hysteresis of it.
  static func side(_ angle: Double, held: Side?) -> Side {
    let raw = Side(angle)
    guard let held, raw != held else { return raw }
    // Every sector is wider than twice the margin, so an angle within the margin of `held` has
    // `held` on one side or the other.
    return Side(angle - hysteresis) == held || Side(angle + hysteresis) == held ? held : raw
  }

  /// The angle from the phone's facing to the place, or nil without a fix or heading.
  static func angle(from you: CLLocationCoordinate2D?, heading: Double?, to place: CLLocationCoordinate2D) -> Double? {
    guard let you, let heading else { return nil }
    return TaskLocation.bearing(from: you, to: place) - heading
  }

  /// The line, or nil while there is no location. `heading` is the facing in degrees (0 = north),
  /// nil without a usable compass reading; `held` is the side shown last, for the hysteresis.
  /// `us` picks feet and miles.
  static func text(
    from you: CLLocationCoordinate2D?, accuracy: CLLocationAccuracy, heading: Double?,
    to place: CLLocationCoordinate2D, noun: Noun, us: Bool, held: Side? = nil
  ) -> String? {
    guard let you, accuracy >= 0 else { return nil }
    if accuracy > roughAccuracy { return "Your location is rough right now. Use the map to find the big pin." }
    let meters = TaskLocation.meters(you, place)
    if meters < atItDistance || meters < accuracy { return "You're at it. It's the \(noun.one) at the big pin." }
    let d = distance(meters, us: us)
    let bearing = TaskLocation.bearing(from: you, to: place)
    guard let heading else { return "\(d) \(TaskLocation.compass(bearing)) of you" }
    return "\(d) \(side(bearing - heading, held: held).words)"
  }

  /// An angle in degrees as -180..<180.
  static func signed(_ angle: Double) -> Double {
    (angle.truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
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

  /// The phone's measurement system: only the US one uses feet; the UK's counts as metric
  /// (design/which-one-spec.md §C).
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
