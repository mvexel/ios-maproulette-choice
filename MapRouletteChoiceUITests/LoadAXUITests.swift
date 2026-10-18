import XCTest

/// How long XCTest takes to read the accessibility tree of a 5,200-place campaign's map (Tess
/// AB12: before clustering, queries timed out even with VoiceOver capped at 200 pins). Prints an
/// `AXSNAPSHOT:` line, which CI copies to the run summary, and fails past 30 s.
final class LoadAXUITests: XCTestCase {
  static let places = 5200
  static let limit: TimeInterval = 30

  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor func testMapSnapshotAt5200Places() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-demo", "-demoLoad", String(Self.places), "-demoMap"]
    app.launch()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow While Using App"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
    let map = app.descendants(matching: .any)["TaskMap"]
    XCTAssert(map.waitForExistence(timeout: 30))
    // The open-time job has the full tally at 6–12 s; wait without querying, so the snapshots
    // below are the first reads of the loaded map.
    sleep(30)

    let (mapSeconds, mapElements) = try timedSnapshot(map)
    let (appSeconds, appElements) = try timedSnapshot(app)
    let line = String(
      format: "AXSNAPSHOT: %ld places: map %.1f s (%ld elements), whole app %.1f s (%ld elements)", Self.places,
      mapSeconds, mapElements, appSeconds, appElements)
    print(line)
    XCTContext.runActivity(named: line) { _ in }
    XCTAssertLessThan(mapSeconds, Self.limit, line)
    XCTAssertLessThan(appSeconds, Self.limit, line)
  }

  /// Seconds to snapshot `element`'s accessibility tree, and how many elements it holds.
  @MainActor private func timedSnapshot(_ element: XCUIElement) throws -> (TimeInterval, Int) {
    let start = Date()
    let snapshot: any XCUIElementSnapshot
    do {
      snapshot = try element.snapshot()
    } catch {
      let seconds = Date().timeIntervalSince(start)
      print(String(format: "AXSNAPSHOT: %ld places: snapshot failed after %.1f s: ", Self.places, seconds) + "\(error)")
      throw error
    }
    let seconds = Date().timeIntervalSince(start)
    func count(_ s: any XCUIElementSnapshot) -> Int { 1 + s.children.reduce(0) { $0 + count($1) } }
    return (seconds, count(snapshot))
  }
}
