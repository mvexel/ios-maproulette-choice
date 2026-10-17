import XCTest

/// Walks a participant through the `-demo` campaign, from the picker to "Saved", and attaches a
/// screenshot of each screen. With TEST_RUNNER_SCREENSHOT_DIR set for xcodebuild, also writes them
/// there as PNGs (see README).
final class ParticipantFlowUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// After a phone sign-in claimed saved answers, the status line follows the claim (B5 progress).
  @MainActor func testClaimProgressReachesTheResult() throws {
    let app = launch("-demoClaim", "progress")
    let progress = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Putting your answers on the map'"))
      .firstMatch
    XCTAssert(progress.waitForExistence(timeout: 15), "progress shows k of n")
    let result = app.staticTexts.containing(
      NSPredicate(format: "label BEGINSWITH %@", "\u{2713} 2 answers are on the map. 1 wasn't added")
    ).firstMatch
    XCTAssert(result.waitForExistence(timeout: 20), "the result replaces the progress line")
    shot(app, "claim-result")
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
    let progress = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '3 of 8 benches checked'")).firstMatch
    XCTAssert(progress.waitForExistence(timeout: 10))
    shot(app, "campaign-map")

    app.buttons["List"].tap()
    XCTAssert(app.staticTexts["Already checked"].waitForExistence(timeout: 5))
    shot(app, "campaign-list")
  }

  /// No signal back at the picker: the campaign kept on the phone is still listed and opens (O2).
  @MainActor func testPickerListsTheKeptCampaignWithNoSignal() throws {
    let app = launch()
    let campaign = app.staticTexts["Downtown bench check"]
    XCTAssert(campaign.waitForExistence(timeout: 10))
    campaign.tap()
    let start = app.buttons["Let's go"]
    XCTAssert(start.waitForExistence(timeout: 10))
    start.tap()
    allowLocationIfAsked(app)
    let progress = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'benches checked'")).firstMatch
    XCTAssert(progress.waitForExistence(timeout: 10))
    app.navigationBars.buttons.element(boundBy: 0).tap()

    let noSignal = app.switches["Demo: no signal"]
    for _ in 0..<4 where !noSignal.isHittable { app.swipeUp() }
    noSignal.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    for _ in 0..<4 where !campaign.isHittable { app.swipeDown() }
    // Pull to refresh: the reload fails with no signal.
    let top = app.cells.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    top.press(forDuration: 0.1, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 400)))
    XCTAssert(app.staticTexts["No signal. Showing the campaign kept on this phone."].waitForExistence(timeout: 10))
    XCTAssert(app.buttons["Retry loading campaigns"].exists, "Retry says what it retries for VoiceOver")
    shot(app, "picker-kept")
    campaign.tap()
    if start.waitForExistence(timeout: 3) { start.tap() }
    XCTAssert(progress.waitForExistence(timeout: 15), "the kept campaign opens")
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
