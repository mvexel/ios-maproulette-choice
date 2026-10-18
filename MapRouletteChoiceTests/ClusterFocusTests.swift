import Testing
import UIKit

@testable import MapRouletteChoice

/// VoiceOver on the clustered map keeps one element per cluster or pin, so focus can go back to
/// the place that was opened (A11y1).
@MainActor @Suite struct ClusterFocusTests {
  private let container = NSObject()

  @Test func sameKeySameElement() {
    let pool = ClusteredPins.Pool()
    let first = pool.element("place-1", in: container)
    pool.keep(["place-1"])
    #expect(pool.element("place-1", in: container) === first)
    #expect(pool.element("place-2", in: container) !== first)
  }

  @Test func unlistedElementsAreDropped() {
    let pool = ClusteredPins.Pool()
    let first = pool.element("place-1", in: container)
    pool.keep(["place-2"])
    #expect(pool.element("place-1", in: container) !== first)
  }

  @Test func focusReturnsToTheOpenedPlaceOnce() {
    let pool = ClusteredPins.Pool()
    let near = pool.element("cluster-9", in: container)
    let opened = pool.element("place-1", in: container)
    #expect(pool.returnFocus(in: [near, opened]) == nil, "nothing opened yet")
    pool.activate("place-1")
    // Off screen while the questions are open: kept although not listed.
    pool.keep([])
    let again = pool.element("place-1", in: container)
    #expect(again === opened)
    #expect(pool.returnFocus(in: [near, again]) === opened)
    #expect(pool.returnFocus(in: [near, again]) == nil, "asked once")
  }

  @Test func focusFallsBackToTheNearestWhenThePlaceIsGone() {
    let pool = ClusteredPins.Pool()
    _ = pool.element("place-1", in: container)
    pool.activate("place-1")
    let near = pool.element("cluster-9", in: container)
    #expect(pool.returnFocus(in: [near]) === near)
  }
}
