import XCTest

/// With no map style (offline with none cached, or the tile server down) the campaign map falls
/// back to a plain background and still shows its places (Android #59 parity). `-demoNoStyle`
/// points the map at a style that can't load, `-demoHangingStyle` at one that never answers.
final class MapFallbackUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor func testPinsShowWithoutAStyle() throws {
    let app = launch("-demoStops", "-demoGuest")
    let pin = app.descendants(matching: .any)["TaskMap"].descendants(matching: .any)
      .matching(NSPredicate(format: "value == 'To check'")).firstMatch
    XCTAssert(pin.waitForExistence(timeout: 30), "a pin to check is on the map: \(app.debugDescription)")
  }

  @MainActor func testClustersShowWithoutAStyle() throws {
    let app = launch("-demoLoad", "1200")
    let cluster = app.descendants(matching: .any)["TaskMap"].descendants(matching: .any)
      .matching(NSPredicate(format: "label MATCHES %@", "^[0-9].* (left to check here|here, all checked)\\.$")).firstMatch
    XCTAssert(cluster.waitForExistence(timeout: 60), "a cluster is on the map: \(app.debugDescription)")
  }

  /// A style request that never answers (MapLibre holds it while offline): the plain background
  /// goes in after the 20 s online wait.
  @MainActor func testClustersShowWhenTheStyleHangs() throws {
    let app = launch("-demoLoad", "1200", style: "-demoHangingStyle")
    let cluster = app.descendants(matching: .any)["TaskMap"].descendants(matching: .any)
      .matching(NSPredicate(format: "label MATCHES %@", "^[0-9].* (left to check here|here, all checked)\\.$")).firstMatch
    XCTAssert(cluster.waitForExistence(timeout: 60), "a cluster is on the map: \(app.debugDescription)")
  }

  @MainActor private func launch(_ arguments: String..., style: String = "-demoNoStyle") -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-demo", "-demoMap", style] + arguments
    app.launch()
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
    XCTAssert(app.descendants(matching: .any)["TaskMap"].waitForExistence(timeout: 30))
    return app
  }
}
