import XCTest

/// Campaign preview mode (design/preview-mode.md) on the demo bus stop campaign served as a draft:
/// `-demoPreview` opens it as `mrchoice://challenge/3?preview=1` would. With SCREENSHOT_DIR set,
/// also writes preview-*.png.
final class PreviewUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor func testBannerWelcomeAndExit() throws {
    let app = launch()
    let start = app.buttons["Let's go"]
    XCTAssert(start.waitForExistence(timeout: 10))
    XCTAssert(text(app, "You're previewing as rosa_slc.").exists, "the welcome card names the OSM account")
    XCTAssert(text(app, "In preview, nothing you answer is saved.").exists, "no OpenStreetMap line in preview")
    XCTAssertFalse(text(app, "Your answers are saved").exists)
    shot(app, "preview-welcome")
    start.tap()
    allowLocationIfAsked(app)

    XCTAssert(banner(app).waitForExistence(timeout: 10))
    XCTAssertFalse(text(app, "The tally:").exists, "no tally in preview")
    shot(app, "preview-campaign")
    app.buttons["Exit"].tap()
    XCTAssert(app.navigationBars["Street Tally"].waitForExistence(timeout: 5), "back at the picker")
  }

  @MainActor func testAnswerEveryQuestionWithoutSaving() throws {
    let app = launch("-demoTask", "185")
    XCTAssert(app.staticTexts["Is there a shelter with a roof?"].waitForExistence(timeout: 20))
    XCTAssert(banner(app).exists)

    answer(app, "Yes")
    XCTAssert(app.staticTexts["Is there a bench or seat?"].waitForExistence(timeout: 5))
    answer(app, "Yes")
    XCTAssert(app.staticTexts["Is the waiting area lit at night?"].waitForExistence(timeout: 5))
    answer(app, "I'm not sure")

    XCTAssert(app.staticTexts["Check your answers"].waitForExistence(timeout: 5))
    let done = app.buttons["Done (preview)"]
    for _ in 0..<4 where !done.isHittable { app.swipeUp() }
    XCTAssert(done.exists)
    shot(app, "preview-review")
    done.tap()

    // A slow CI simulator can drop the first tap mid-scroll; tap again if the button is still there.
    let saved = app.staticTexts["Preview: not saved."]
    if !saved.waitForExistence(timeout: 10), done.exists, done.isHittable { done.tap() }
    XCTAssert(saved.waitForExistence(timeout: 10))
    XCTAssert(text(app, "In the real campaign this would say: “Saved, thanks!").exists)
    XCTAssert(banner(app).exists)
    shot(app, "preview-saved")
  }

  // MARK: Helpers

  @MainActor private func launch(_ arguments: String...) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-demo", "-demoStops", "-demoDraft", "-demoPreview"] + arguments
    app.launch()
    return app
  }

  @MainActor private func banner(_ app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label == %@", "Preview. Answers aren't saved.")).firstMatch
  }

  @MainActor private func text(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
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
