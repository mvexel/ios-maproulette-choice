import CoreLocation
import Observation

/// Location and compass while a place is on screen, for the direction line
/// (design/which-one-spec.md §C). Readings are published at most once a second.
@MainActor @Observable final class LiveLocation: NSObject, CLLocationManagerDelegate {
  /// The latest fix.
  private(set) var coordinate: CLLocationCoordinate2D?
  /// Its horizontal accuracy in metres; negative when unknown.
  private(set) var accuracy: CLLocationAccuracy = -1
  /// Facing in degrees (0 = north), nil without a usable compass reading.
  private(set) var heading: Double?

  /// A compass reading worse than this is not used: the line falls back to compass points.
  nonisolated static let usableHeadingAccuracy: CLLocationDirection = 45

  @ObservationIgnored private let manager = CLLocationManager()
  @ObservationIgnored private var latestFix: (coordinate: CLLocationCoordinate2D, accuracy: CLLocationAccuracy)?
  @ObservationIgnored private var latestFacing: Double?
  @ObservationIgnored private var ticker: Task<Void, Never>?
  /// `start()` was called: updates begin as soon as location is allowed.
  @ObservationIgnored private var wanted = false
  /// `-demoFix` readings: no manager, no updates.
  @ObservationIgnored private let fixed: Bool
  /// A `-demoFix` reading: the map draws it itself.
  var isFixed: Bool { fixed }

  override init() {
    fixed = false
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.headingFilter = 5
  }

  /// A fixed reading, for demo screenshots of each line.
  init(fixed coordinate: CLLocationCoordinate2D, accuracy: CLLocationAccuracy, heading: Double?) {
    fixed = true
    super.init()
    self.coordinate = coordinate
    self.accuracy = accuracy
    self.heading = heading
  }

  /// Starts updates once location is allowed; asks nothing (the campaign screen asked already).
  /// A new manager can report its status late, so the authorization callback starts them too.
  func start() {
    guard !fixed else { return }
    wanted = true
    begin()
  }

  private func begin() {
    guard wanted, ticker == nil else { return }
    switch manager.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: break
    default: return
    }
    manager.startUpdatingLocation()
    if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        self?.publish()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  func stop() {
    guard !fixed else { return }
    wanted = false
    ticker?.cancel()
    ticker = nil
    manager.stopUpdatingLocation()
    manager.stopUpdatingHeading()
  }

  private func publish() {
    if let fix = latestFix {
      if coordinate?.latitude != fix.coordinate.latitude || coordinate?.longitude != fix.coordinate.longitude {
        coordinate = fix.coordinate
      }
      if accuracy != fix.accuracy { accuracy = fix.accuracy }
    }
    if heading != latestFacing { heading = latestFacing }
  }

  /// True north once there is a fix (trueHeading is negative before), else magnetic; nil when the
  /// reading is invalid or too uncertain.
  nonisolated private static func facing(_ h: CLHeading) -> Double? {
    guard h.headingAccuracy >= 0, h.headingAccuracy <= usableHeadingAccuracy else { return nil }
    return h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let last = locations.last else { return }
    let (coordinate, accuracy) = (last.coordinate, last.horizontalAccuracy)
    Task { @MainActor in latestFix = (coordinate, accuracy) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
    let facing = Self.facing(newHeading)
    Task { @MainActor in latestFacing = facing }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    Task { @MainActor in begin() }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
