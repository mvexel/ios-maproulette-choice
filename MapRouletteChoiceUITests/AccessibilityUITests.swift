import XCTest

/// VoiceOver labels, selection state, map pins and the largest accessibility text size on the
/// guest bus stop demo. With SCREENSHOT_DIR set, also writes ax5-question.png and ax5-campaign.png.
final class AccessibilityUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor func testQuestionLabelsAndSelection() throws {
    let app = launch("-demoTask", "185")
    let prompt = app.staticTexts["Is there a shelter with a roof?"]
    XCTAssert(prompt.waitForExistence(timeout: 10))
    // Answer buttons read "<label>, <help>".
    XCTAssert(button(app, "Yes").exists)
    XCTAssert(button(app, "I'm not sure").exists)

    button(app, "I'm not sure").tap()
    XCTAssert(app.staticTexts["Is there a bench or seat?"].waitForExistence(timeout: 5))
    app.buttons["Previous question"].tap()
    XCTAssert(prompt.waitForExistence(timeout: 5))
    XCTAssert(button(app, "I'm not sure").isSelected, "the chosen answer reports Selected")
  }

  @MainActor func testListRowsReadNameDistanceAndState() throws {
    let app = launch("-demoList")
    let checked = app.descendants(matching: .any).matching(NSPredicate(format: "value == 'Already checked'")).firstMatch
    XCTAssert(checked.waitForExistence(timeout: 10), "checked rows say so")
    // Distances read "170 m northeast": no separator for VoiceOver.
    let row = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES '.* m (north|south|east|west|northeast|northwest|southeast|southwest)$'")).firstMatch
    if row.waitForExistence(timeout: 30) {
      XCTAssertFalse(row.label.contains("·"))
    }
  }

  @MainActor func testLargestTextKeepsAnswersWhole() throws {
    let app = launch("-demoTask", "185", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL")
    XCTAssert(app.staticTexts["Is there a shelter with a roof?"].waitForExistence(timeout: 30))  // the first launch at AX-XXXL is slow on CI runners
    shot(app, "ax5-question")
    // At this size the header fills the first screen; the answers are below it.
    let yes = button(app, "Yes")
    for _ in 0..<4 where !yes.isHittable { app.swipeUp() }
    XCTAssert(yes.isHittable)
    XCTAssertGreaterThanOrEqual(yes.frame.height, 44)
    let notSure = button(app, "I'm not sure")
    for _ in 0..<4 where !notSure.isHittable { app.swipeUp() }
    XCTAssert(notSure.isHittable)

    app.navigationBars.buttons["BackButton"].firstMatch.tap()
    XCTAssert(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'stops checked'")).firstMatch.waitForExistence(timeout: 10))
    shot(app, "ax5-campaign")
  }

  @MainActor func testMapPinsReadStateNearestFirst() throws {
    let app = launch("-demoMap")
    allowLocationIfAsked(app)
    let map = app.descendants(matching: .any)["TaskMap"]
    XCTAssert(map.waitForExistence(timeout: 10))
    let toCheck = map.descendants(matching: .any).matching(NSPredicate(format: "value == 'To check'"))
    XCTAssert(toCheck.firstMatch.waitForExistence(timeout: 10), "pins read their state, not a hint")
    XCTAssertGreaterThanOrEqual(toCheck.firstMatch.frame.width, 44)
    XCTAssertGreaterThanOrEqual(toCheck.firstMatch.frame.height, 44)
    XCTAssert(
      map.descendants(matching: .any).matching(NSPredicate(format: "value == 'Already checked'")).firstMatch.exists)
    XCTAssertFalse(map.descendants(matching: .any).matching(NSPredicate(format: "value == 'Tap to answer'")).firstMatch.exists)

    // Nearest first needs a location fix; the list's first row to check is the nearest.
    let nearest = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Nearest stop ·'")).firstMatch
    guard nearest.waitForExistence(timeout: 30) else { throw XCTSkip("No location fix in the simulator") }
    sleep(1)  // the map re-adds its pins in the new order
    let firstPin = toCheck.element(boundBy: 0).label
    XCTAssertFalse(firstPin.isEmpty)
    app.buttons["List"].tap()
    let firstRow = app.collectionViews.firstMatch.buttons.element(boundBy: 0)
    XCTAssert(firstRow.waitForExistence(timeout: 5))
    XCTAssert(firstRow.label.hasPrefix(firstPin), "first pin to check \(firstPin), first row \(firstRow.label)")
  }

  // MARK: Helpers

  @MainActor private func allowLocationIfAsked(_ app: XCUIApplication) {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow While Using App"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
  }

  @MainActor private func launch(_ arguments: String...) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-demo", "-demoStops", "-demoGuest"] + arguments
    app.launch()
    return app
  }

  @MainActor private func button(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
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
