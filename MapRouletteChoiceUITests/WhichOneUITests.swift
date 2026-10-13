import XCTest

/// "Which one?" (design/which-one-spec.md) on the `-demoTrees` fixture: tree 1092, in the densest
/// cluster, with a fixed reading per test (`-demoFix lat,lng,accuracy[,heading]`). With
/// SCREENSHOT_DIR set, writes which-one-ahead, which-one-compass, which-one-rough, which-one-at-it
/// and which-one-cant-tell.
final class WhichOneUITests: XCTestCase {
  /// Tree 1092.
  private let lat = 40.7517781
  private let lng = -111.9029741

  override func setUp() {
    continueAfterFailure = false
  }

  /// About 12 m south of the tree, facing north: the line, the dots line and the map label.
  @MainActor func testAheadWithNeighbours() throws {
    let app = launch(fix: lat - 0.000108, lng, accuracy: 5, heading: 0)
    XCTAssert(text(app, " ahead").waitForExistence(timeout: 20))
    XCTAssert(text(app, "Grey dots are other trees in this campaign.").waitForExistence(timeout: 10))
    XCTAssert(app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH %@", ", with other trees nearby")).firstMatch.exists)
    sleep(3)  // map tiles
    shot(app, "which-one-ahead")
  }

  @MainActor func testCompassPointsWithoutHeading() throws {
    let app = launch(fix: lat - 0.000108, lng - 0.000142, accuracy: 5, heading: nil)
    XCTAssert(text(app, "northeast of you").waitForExistence(timeout: 20))
    sleep(3)
    shot(app, "which-one-compass")
  }

  @MainActor func testRoughLocation() throws {
    let app = launch(fix: lat - 0.000108, lng, accuracy: 40, heading: 0)
    XCTAssert(text(app, "Your location is rough right now. Use the map to find the big pin.").waitForExistence(timeout: 20))
    sleep(3)
    shot(app, "which-one-rough")
  }

  @MainActor func testAtIt() throws {
    let app = launch(fix: lat - 0.00002, lng, accuracy: 5, heading: 0)
    XCTAssert(text(app, "You're at it. It's the tree at the big pin.").waitForExistence(timeout: 20))
    sleep(3)
    shot(app, "which-one-at-it")
  }

  /// "I can't tell which tree" records "I can't check" and thanks.
  @MainActor func testCantTell() throws {
    let app = launch(fix: lat - 0.000108, lng, accuracy: 5, heading: 0)
    XCTAssert(app.staticTexts["Does this tree have leaves or needles?"].waitForExistence(timeout: 20))
    XCTAssert(text(app, "The tree at the big pin. Palms count as leaves.").exists)
    let cantTell = app.buttons["I can't tell which tree"]
    XCTAssert(cantTell.waitForExistence(timeout: 5))
    shot(app, "which-one-question")
    cantTell.tap()
    XCTAssert(text(app, "Thanks. Someone will take another look at this tree.").waitForExistence(timeout: 10))
    shot(app, "which-one-cant-tell")
  }

  // MARK: Helpers

  @MainActor private func launch(fix lat: Double, _ lng: Double, accuracy: Double, heading: Double?) -> XCUIApplication {
    let app = XCUIApplication()
    let fix = [lat, lng, accuracy] + (heading.map { [$0] } ?? [])
    app.launchArguments = [
      "-demo", "-demoTrees", "-demoGuest", "-demoTask", "1092", "-demoFix", fix.map { String($0) }.joined(separator: ","),
    ]
    app.launch()
    return app
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
