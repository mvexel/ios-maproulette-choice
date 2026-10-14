import CoreLocation
import Testing

@testable import MapRouletteChoice

/// The direction line under the close-up map (design/which-one-spec.md §C).
@Suite struct DirectionLineTests {
  let here = CLLocationCoordinate2D(latitude: 40.75, longitude: -111.9)
  let tree = Noun(one: "tree", many: "trees")

  /// A point `meters` from `here` along `bearing` degrees.
  func point(_ meters: Double, _ bearing: Double) -> CLLocationCoordinate2D {
    let r = bearing * .pi / 180
    return CLLocationCoordinate2D(
      latitude: here.latitude + meters * cos(r) / 111_320,
      longitude: here.longitude + meters * sin(r) / (111_320 * cos(here.latitude * .pi / 180)))
  }

  func line(
    _ to: CLLocationCoordinate2D, accuracy: Double = 5, heading: Double? = nil, us: Bool = false,
    held: DirectionLine.Side? = nil
  ) -> String? {
    DirectionLine.text(from: here, accuracy: accuracy, heading: heading, to: to, noun: tree, us: us, held: held)
  }

  @Test func rulesInOrder() {
    #expect(DirectionLine.text(from: nil, accuracy: 5, heading: 0, to: point(8, 0), noun: tree, us: false) == nil)
    #expect(line(point(8, 0), accuracy: 30) == "Your location is rough right now. Use the map to find the big pin.")
    #expect(line(point(4, 0)) == "You're at it. It's the tree at the big pin.")
    // Inside the accuracy radius counts as at it too.
    #expect(line(point(12, 0), accuracy: 15) == "You're at it. It's the tree at the big pin.")
    #expect(line(point(8, 0), heading: 0) == "8 m ahead")
    #expect(line(point(25, 45)) == "25 m northeast of you")
  }

  @Test func facingAngles() {
    #expect(line(point(8, 20), heading: 0) == "8 m ahead")
    #expect(line(point(8, 340), heading: 0) == "8 m ahead")
    #expect(line(point(8, 40), heading: 0) == "8 m ahead, slightly right")
    #expect(line(point(8, 320), heading: 0) == "8 m ahead, slightly left")
    #expect(line(point(8, 90), heading: 0) == "8 m to your right")
    #expect(line(point(8, 270), heading: 0) == "8 m to your left")
    #expect(line(point(8, 140), heading: 0) == "8 m behind you, to the right")
    #expect(line(point(8, 220), heading: 0) == "8 m behind you, to the left")
    #expect(line(point(8, 180), heading: 0) == "8 m behind you")
    // Facing west, a place to the north is on the right.
    #expect(line(point(8, 0), heading: 270) == "8 m to your right")
    #expect(DirectionLine.Side(-370) == .ahead)
  }

  /// A side holds until the angle is 10° past its boundary (§C).
  @Test func hysteresisHoldsTheSide() {
    // 25° is the ahead / slightly right boundary.
    #expect(DirectionLine.side(30, held: .ahead) == .ahead)
    #expect(DirectionLine.side(34, held: .ahead) == .ahead)
    #expect(DirectionLine.side(36, held: .ahead) == .slightlyRight)
    #expect(DirectionLine.side(20, held: .slightlyRight) == .slightlyRight)
    #expect(DirectionLine.side(14, held: .slightlyRight) == .ahead)
    // Across behind: 175° and -175° are both behind; left and right flip only past the margin.
    #expect(DirectionLine.side(150, held: .behind) == .behind)
    #expect(DirectionLine.side(-150, held: .behindRight) == .behindLeft)
    #expect(DirectionLine.side(-170, held: .behindRight) == .behind)
    #expect(DirectionLine.side(30, held: nil) == .slightlyRight)
    #expect(line(point(8, 30), heading: 0, held: .ahead) == "8 m ahead")
  }

  @Test func metricAndUSDistances() {
    #expect(DirectionLine.distance(7.4, us: false) == "7 m")
    #expect(DirectionLine.distance(23, us: false) == "25 m")
    #expect(DirectionLine.distance(143, us: false) == "140 m")
    #expect(DirectionLine.distance(1240, us: false) == "1.2 km")
    #expect(DirectionLine.distance(8, us: true) == "25 ft")
    #expect(DirectionLine.distance(40, us: true) == "130 ft")
    #expect(DirectionLine.distance(400, us: true) == "0.2 mi")
    #expect(line(point(8, 45), us: true) == "25 ft northeast of you")
  }

  @Test func announcementsFollowTheKindNotTheNumber() {
    #expect(DirectionLine.announcementKind("8 m ahead, slightly left") == "ahead, slightly left")
    #expect(DirectionLine.announcementKind("7 m ahead, slightly left") == "ahead, slightly left")
    #expect(DirectionLine.announcementKind("25 ft northeast of you") == "northeast of you")
    #expect(DirectionLine.announcementKind("You're at it. It's the tree at the big pin.") == "You're at it. It's the tree at the big pin.")
    #expect(DirectionLine.announcementKind(nil) == nil)
  }

  @Test func treesCampaignNoun() {
    #expect(Noun.from(match: ["natural": "tree"]) == tree)
    #expect(Wording.cantTell(tree) == "I can't tell which tree")
    #expect(Wording.otherDots(tree) == "Grey dots are other trees in this campaign.")
    #expect(Wording.locationOff(tree) == "Turn on location to see which way the tree is.")
  }
}
