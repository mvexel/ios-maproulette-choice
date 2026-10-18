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

  /// VoiceOver on the clustered map (A11y1, Android parity with Kai's ClusterAccessTest): clusters
  /// are reachable and say how many places they hold, a cluster zooms in down to single places,
  /// which read their name and state with a 44 pt target, and an opened place is still listed,
  /// as the same element, when its questions close. Where VoiceOver's focus lands can't be read
  /// in the simulator; ClusterFocusTests covers what the app asks it to focus.
  @MainActor func testClustersAndPlacesReachable() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-demo", "-demoLoad", String(Self.places), "-demoMap"]
    app.launch()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow While Using App"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
    let map = app.descendants(matching: .any)["TaskMap"]
    XCTAssert(map.waitForExistence(timeout: 30))

    let clusters = map.descendants(matching: .any).matching(
      NSPredicate(format: "label MATCHES %@", "^[0-9].* left to check here\\.$"))
    XCTAssert(clusters.firstMatch.waitForExistence(timeout: 60), "clusters read how many are left: \(Self.labels(map))")
    let cluster = clusters.element(boundBy: 0)
    XCTAssert(cluster.label.contains(where: \.isNumber), cluster.label)
    XCTAssertGreaterThanOrEqual(cluster.frame.width, 43.5)
    let listed = clusters.allElementsBoundByIndex
    let spots = Set(listed.map { "\($0.label) \(Int($0.frame.midX)),\(Int($0.frame.midY))" })
    XCTAssertEqual(spots.count, listed.count, "each cluster is listed once: \(Self.labels(map))")

    // Zoom in through clusters until single places show (clusters stop above zoom 15).
    let places = map.descendants(matching: .any).matching(NSPredicate(format: "value == 'To check'"))
    for _ in 0..<8 where !places.firstMatch.exists {
      guard clusters.firstMatch.exists else { break }
      clusters.element(boundBy: 0).tap()
      _ = places.firstMatch.waitForExistence(timeout: 4)
    }
    XCTAssert(places.firstMatch.waitForExistence(timeout: 10), "single places reachable: \(Self.labels(map))")
    let place = places.element(boundBy: 0)
    let name = place.label
    XCTAssertFalse(name.isEmpty)
    XCTAssertGreaterThanOrEqual(place.frame.width, 43.5)
    XCTAssertGreaterThanOrEqual(place.frame.height, 43.5)

    // Open it from its callout and come back: the same place is listed again.
    place.tap()
    let callout = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Tap to answer'")).firstMatch
    XCTAssert(callout.waitForExistence(timeout: 5), "callout: \(app.debugDescription)")
    callout.tap()
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    XCTAssert(back.waitForExistence(timeout: 10), "questions opened")
    back.tap()
    XCTAssert(map.waitForExistence(timeout: 10))
    let again = map.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).firstMatch
    XCTAssert(again.waitForExistence(timeout: 10), "\(name) listed after Back: \(Self.labels(map))")
  }

  /// The map's spoken labels, for a failure message.
  @MainActor private static func labels(_ map: XCUIElement) -> String {
    guard let snapshot = try? map.snapshot() else { return "(no snapshot)" }
    return snapshot.children.prefix(20).map { "\($0.label) [\($0.value ?? "")]" }.joined(separator: "; ")
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
