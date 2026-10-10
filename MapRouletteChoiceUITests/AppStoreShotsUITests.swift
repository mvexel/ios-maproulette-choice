import XCTest

/// App Store raw captures (brand/appstore README, slots 1–6): the "SLC Bus Stops" demo campaign
/// answered as a guest. With SCREENSHOT_DIR set, writes welcome, map, question, notsure, saved and
/// progress PNGs there, plus putonmap and wrong for design review.
final class AppStoreShotsUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor func testWelcomeAndMap() throws {
    let app = launch()
    XCTAssert(app.staticTexts["SLC Bus Stops"].waitForExistence(timeout: 10))
    app.staticTexts["SLC Bus Stops"].tap()
    let start = app.buttons["Let's go"]
    XCTAssert(start.waitForExistence(timeout: 10))
    sleep(4)  // map tiles behind the sheet
    shot(app, "welcome")
    // On a 6.9" phone the whole card fits, guest lines included (Iris B-6).
    start.tap()
    allowLocationIfAsked(app)
    XCTAssert(text(app, "3 of 8 stops checked").waitForExistence(timeout: 10))
    waitForLocation(app)
    sleep(3)  // map tiles
    shot(app, "map")
  }

  @MainActor func testAnswerNotSureAndSave() throws {
    let app = launch("-demoTask", "185")
    XCTAssert(app.staticTexts["Is there a shelter with a roof?"].waitForExistence(timeout: 10))
    sleep(2)  // header map tiles
    shot(app, "question")

    answer(app, "Yes")
    XCTAssert(app.staticTexts["Is there a bench or seat?"].waitForExistence(timeout: 5))
    answer(app, "Yes")
    XCTAssert(app.staticTexts["Is the waiting area lit at night?"].waitForExistence(timeout: 5))
    answer(app, "I'm not sure")
    XCTAssert(app.staticTexts["Check your answers"].waitForExistence(timeout: 5))
    // Back to the last question: "I'm not sure" shows as the selected answer.
    app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Is the waiting area lit'")).firstMatch.tap()
    XCTAssert(app.staticTexts["Is the waiting area lit at night?"].waitForExistence(timeout: 5))
    shot(app, "notsure")
    answer(app, "I'm not sure")

    XCTAssert(app.buttons["Done"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssert(text(app, "Saved.").waitForExistence(timeout: 10))
    // The "put them on the map" card opens once after the first saved answer.
    let later = app.buttons["Later"]
    if later.waitForExistence(timeout: 3) {
      shot(app, "putonmap")
      later.tap()
    }
    sleep(1)
    shot(app, "saved")

    let back = app.buttons["Back to all stops"]
    XCTAssert(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssert(text(app, "of 8 stops checked").waitForExistence(timeout: 10))
    waitForLocation(app)
    sleep(3)
    shot(app, "progress")
  }

  @MainActor func testSomethingsWrongSheet() throws {
    let app = launch("-demoTask", "187")
    let wrong = app.buttons["Something's wrong here"]
    XCTAssert(wrong.waitForExistence(timeout: 10))
    wrong.tap()
    sleep(1)
    shot(app, "wrong")
  }

  // MARK: Helpers

  @MainActor private func launch(_ arguments: String...) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-demo", "-demoStops", "-demoGuest"] + arguments
    app.launch()
    return app
  }

  /// The first location fix is slow in the simulator: wait until "Nearest stop · 120 m" shows a
  /// distance (and the map its dot). Shots go ahead without it after 30 s.
  @MainActor private func waitForLocation(_ app: XCUIApplication) {
    let withDistance = app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Nearest stop ·'")).firstMatch
    _ = withDistance.waitForExistence(timeout: 30)
  }

  private func text(_ app: XCUIApplication, _ fragment: String) -> XCUIElement {
    app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", fragment)).firstMatch
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
