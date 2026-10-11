import XCTest

/// The first pilot's campaign, "Woodbine entrance doors" (design/woodbine-campaign.md), on the
/// `-demoWoodbine` fixture: the noun, both questions with their four options, the one-question
/// task (`liveMissingQuestions`) and the "There's no door" outcome. With SCREENSHOT_DIR set,
/// writes woodbine-campaign, woodbine-list, woodbine-door, woodbine-automatic, woodbine-review,
/// woodbine-one-question and woodbine-no-door.
/// First looks at a new screen wait 20 s: under a full-suite run, map styles, tiles and the
/// first location fix can hold the first frame past 10 s.
final class WoodbineUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor func testCampaignSaysEntrances() throws {
    let app = launch()
    XCTAssert(app.staticTexts["Woodbine entrance doors"].waitForExistence(timeout: 20))
    app.staticTexts["Woodbine entrance doors"].tap()
    let start = app.buttons["Let's go"]
    XCTAssert(start.waitForExistence(timeout: 10))
    start.tap()
    allowLocationIfAsked(app)
    XCTAssert(text(app, "3 of 8 entrances checked").waitForExistence(timeout: 20))
    sleep(3)  // map tiles
    shot(app, "woodbine-campaign")
    app.buttons["List"].tap()
    // A lazy list may not have built the section below the fold yet.
    let checked = app.staticTexts["Already checked"]
    if !checked.waitForExistence(timeout: 10) { app.swipeUp() }
    XCTAssert(checked.waitForExistence(timeout: 10))
    shot(app, "woodbine-list")
  }

  @MainActor func testBothQuestionsAndSave() throws {
    let app = launch("-demoTask", "185")
    XCTAssert(app.staticTexts["How does this door open?"].waitForExistence(timeout: 20))
    XCTAssert(text(app, "Look only at the door at this entrance.").exists)
    for label in ["Swings open", "Slides sideways", "Revolves", "Folds", "I'm not sure"] {
      XCTAssert(option(app, label).exists, "no option \(label)")
    }
    shot(app, "woodbine-door")

    option(app, "Swings open").tap()
    XCTAssert(app.staticTexts["Does it open by itself?"].waitForExistence(timeout: 5))
    XCTAssert(text(app, "A door that's propped open doesn't count.").exists)
    for label in ["No, you push or pull it", "Yes, with a button", "Yes, when you walk up", "Yes, not sure how", "I'm not sure"] {
      XCTAssert(option(app, label).exists, "no option \(label)")
    }
    shot(app, "woodbine-automatic")

    option(app, "Yes, with a button").tap()
    XCTAssert(app.staticTexts["Check your answers"].waitForExistence(timeout: 5))
    shot(app, "woodbine-review")
    app.buttons["Done"].tap()
    XCTAssert(text(app, "Saved, thanks").waitForExistence(timeout: 10))
  }

  /// 188 already has `door`, so only the automatic-opening question is asked.
  @MainActor func testOnlyTheMissingQuestion() throws {
    let app = launch("-demoTask", "188")
    XCTAssert(app.staticTexts["Does it open by itself?"].waitForExistence(timeout: 20))
    XCTAssertFalse(app.staticTexts["How does this door open?"].exists)
    shot(app, "woodbine-one-question")
  }

  @MainActor func testNoDoorOutcome() throws {
    let app = launch("-demoTask", "185")
    let wrong = app.buttons["Something's wrong here"]
    XCTAssert(wrong.waitForExistence(timeout: 20))
    wrong.tap()
    XCTAssert(option(app, "There's no door").waitForExistence(timeout: 5))
    XCTAssert(option(app, "There's no door").label.contains("It's an open doorway or a gate."))
    shot(app, "woodbine-no-door")
  }

  // MARK: Helpers

  @MainActor private func launch(_ arguments: String...) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-demo", "-demoWoodbine"] + arguments
    app.launch()
    return app
  }

  /// Answer and sheet buttons read "<label>, <description>", so match the start of the label.
  @MainActor private func option(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
  }

  @MainActor private func allowLocationIfAsked(_ app: XCUIApplication) {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let allow = springboard.buttons["Allow While Using App"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
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
