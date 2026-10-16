import XCTest

/// "It's not here" and "It's moved" (design/not-here-moved.md) on the bus stop demo, signed in.
/// With SCREENSHOT_DIR set, writes the shots Iris checks: nhm-sheet, nhm-moved-tap,
/// nhm-moved-here, nhm-review-nothere, nhm-review-moved, nhm-saved-moved and nhm-banner.
final class NotHereMovedUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor func testSheetAndNotHere() throws {
    let app = launch("-demoTask", "185")
    openSheet(app)
    XCTAssert(text(app, "Nothing here changes OpenStreetMap.").exists)
    XCTAssert(row(app, "It's moved").exists)
    shot(app, "nhm-sheet")

    row(app, "It's not here").tap()
    XCTAssert(text(app, "The stop isn't here.").waitForExistence(timeout: 5))
    XCTAssert(app.staticTexts["Check your report"].exists)
    shot(app, "nhm-review-nothere")
    app.buttons["Done"].tap()
    XCTAssert(text(app, "Thanks, reported. The organizer will check it.").waitForExistence(timeout: 10))
  }

  @MainActor func testMovedByTapping() throws {
    let app = launch("-demoTask", "185")
    openSheet(app)
    row(app, "It's moved").tap()
    allowLocationIfAsked(app)
    XCTAssert(app.staticTexts["Where is the stop now?"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Save this spot"].isEnabled)
    sleep(3)  // map tiles
    // Right of the middle of the map: a few tens of meters east at street zoom.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
    XCTAssert(text(app, "from where the map has it.").waitForExistence(timeout: 5))
    XCTAssert(text(app, "Only the spot you pick is saved").exists)
    sleep(1)
    shot(app, "nhm-moved-tap")

    app.buttons["Save this spot"].tap()
    XCTAssert(text(app, "The stop has moved, about").waitForExistence(timeout: 5))
    XCTAssert(app.staticTexts["Check your report"].exists)
    sleep(2)
    shot(app, "nhm-review-moved")
    app.buttons["Done"].tap()
    XCTAssert(text(app, "Thanks, reported. The organizer will move it on the map.").waitForExistence(timeout: 10))
    // The "Someone reported" banner is for the next person, not the reporter.
    XCTAssertFalse(text(app, "Someone reported").exists)
    shot(app, "nhm-saved-moved")
  }

  @MainActor func testMovedByStandingAtIt() throws {
    let app = launch("-demoTask", "185", "-demoHere")
    openSheet(app)
    row(app, "It's moved").tap()
    let here = app.buttons["I'm standing at it"]
    XCTAssert(here.waitForExistence(timeout: 5))
    here.tap()
    XCTAssert(text(app, "About 30 m from where the map has it.").waitForExistence(timeout: 5))
    XCTAssert(text(app, "Your current location is saved").exists)
    XCTAssert(app.buttons["Save this spot"].isEnabled)
    sleep(3)
    shot(app, "nhm-moved-here")
  }

  @MainActor func testBannerForTheNextPerson() throws {
    let app = launch("-demoReported", "-demoTask", "187")
    XCTAssert(text(app, "Someone reported this stop moved, about").waitForExistence(timeout: 10))
    sleep(3)  // header map tiles and the dot
    shot(app, "nhm-banner")
  }

  /// Another guest's saved report (T-002) needs another look; their saved answer reads checked.
  @MainActor func testHeldReportNeedsAnotherLook() throws {
    let app = launch("-demoHeldReport", "-demoMap")
    let map = app.descendants(matching: .any)["TaskMap"]
    XCTAssert(map.waitForExistence(timeout: 10))
    let report = map.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '900 E & Bryan Ave'")).firstMatch
    XCTAssert(report.waitForExistence(timeout: 10))
    XCTAssertEqual(report.value as? String, "Needs another look")
    let answer = map.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '900 E & 1300 S'")).firstMatch
    XCTAssert(answer.exists)
    XCTAssertNotEqual(answer.value as? String, "To check")
    XCTAssertNotEqual(answer.value as? String, "Needs another look")
  }

  // MARK: Helpers

  @MainActor private func launch(_ arguments: String...) -> XCUIApplication {
    let app = XCUIApplication()
    // Metric copy whatever the simulator region; the UK counts as metric.
    app.launchArguments = ["-demo", "-demoStops", "-AppleLocale", "en_GB"] + arguments
    app.launch()
    return app
  }

  @MainActor private func openSheet(_ app: XCUIApplication) {
    let wrong = app.buttons["Something's wrong here"]
    XCTAssert(wrong.waitForExistence(timeout: 10))
    wrong.tap()
    XCTAssert(row(app, "It's not here").waitForExistence(timeout: 5))
  }

  @MainActor private func allowLocationIfAsked(_ app: XCUIApplication) {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow While Using App"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
  }

  /// Sheet rows read "<label>, <explanation>".
  @MainActor private func row(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
  }

  private func text(_ app: XCUIApplication, _ fragment: String) -> XCUIElement {
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
  }

  @MainActor private func shot(_ app: XCUIApplication, _ name: String) {
    let screenshot = app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty else { return }
    let url = URL(fileURLWithPath: dir, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try? screenshot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
  }
}
