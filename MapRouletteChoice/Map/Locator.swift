import CoreLocation

/// One-shot location on request, with a 20 s timeout.
@MainActor final class Locator: NSObject, CLLocationManagerDelegate {
  enum Result { case found(CLLocationCoordinate2D), denied, unavailable, timedOut }

  private let manager = CLLocationManager()
  private var completion: ((Result) -> Void)?
  private var timeout: Task<Void, Never>?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  func locate(_ completion: @escaping (Result) -> Void) {
    stop()
    self.completion = completion
    timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(20))
      if !Task.isCancelled { self?.finish(.timedOut) }
    }
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .denied, .restricted: finish(.denied)
    default: manager.requestLocation()
    }
  }

  func stop() {
    timeout?.cancel()
    timeout = nil
    completion = nil
  }

  private func finish(_ result: Result) {
    let completion = self.completion
    stop()
    completion?(result)
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      guard completion != nil else { return }
      switch status {
      case .notDetermined: break
      case .denied, .restricted: finish(.denied)
      default: self.manager.requestLocation()
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let coordinate = locations.last?.coordinate else { return }
    Task { @MainActor in finish(.found(coordinate)) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
    let denied = (error as? CLError)?.code == .denied
    Task { @MainActor in finish(denied ? .denied : .unavailable) }
  }
}
