import XCTest

/// Walks a participant through the `-demo` campaign, from the picker to "Saved", and attaches a
/// screenshot of each screen. With TEST_RUNNER_SCREENSHOT_DIR set for xcodebuild, also writes them
/// there as PNGs (see README).
final class ParticipantFlowUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor func testAnswerABenchFromThePicker() throws {
    let app = launch()
    XCTAssert(app.staticTexts["Downtown bench check"].waitForExistence(timeout: 10))
    shot(app, "picker")

    app.staticTexts["Downtown bench check"].tap()
    let start = app.buttons["Let's go"]
    XCTAssert(start.waitForExistence(timeout: 10))
    shot(app, "welcome")
    start.tap()
    allowLocationIfAsked(app)
    XCTAssert(app.staticTexts["3 of 8 benches checked"].waitForExistence(timeout: 10))
    shot(app, "campaign-map")

    app.buttons["List"].tap()
    XCTAssert(app.staticTexts["Already checked"].waitForExistence(timeout: 5))
    shot(app, "campaign-list")
  }

  @MainActor func testAnswerAllQuestionsAndSave() throws {
    let app = launch("-demoTask", "185")
    XCTAssert(app.staticTexts["Does the bench have a backrest?"].waitForExistence(timeout: 10))
    shot(app, "question")

    answer(app, "Yes")
    XCTAssert(app.staticTexts["What is the seat mainly made of?"].waitForExistence(timeout: 5))
    answer(app, "Wood")
    XCTAssert(app.staticTexts["How many adults can sit on it?"].waitForExistence(timeout: 5))
    answer(app, "3")

    XCTAssert(app.staticTexts["Check your answers"].waitForExistence(timeout: 5))
    shot(app, "review")
    app.buttons["Done"].tap()

    let saved = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Saved, thanks'")).firstMatch
    XCTAssert(saved.waitForExistence(timeout: 10))
    shot(app, "saved")
  }

  @MainActor func testPlaceThatNoLongerNeedsChecking() throws {
    let app = launch("-demoTask", "191")
    XCTAssert(app.buttons["Back to all benches"].waitForExistence(timeout: 10))
    shot(app, "stale")
  }

  // MARK: Helpers

  @MainActor private func launch(_ arguments: String...) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-demo"] + arguments
    app.launch()
    return app
  }

  /// Answer buttons read "<label>, <description>", so match the start of the label.
  @MainActor private func answer(_ app: XCUIApplication, _ label: String) {
    let button = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
    XCTAssert(button.waitForExistence(timeout: 5), "no answer \(label)")
    button.tap()
  }

  @MainActor private func allowLocationIfAsked(_ app: XCUIApplication) {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow While Using App"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
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
