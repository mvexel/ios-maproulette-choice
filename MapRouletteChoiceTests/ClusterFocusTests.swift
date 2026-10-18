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

  /// A cluster the source no longer has (re-clustered since its element was built) is never asked
  /// for its expansion zoom; the map zooms in two levels instead.
  @Test func goneClusterZoomsInTwoLevels() {
    #expect(ClusteredPins.zoom(expansion: nil, from: 12) == 14)
    #expect(ClusteredPins.zoom(expansion: 15, from: 12) == 15)
    #expect(ClusteredPins.zoom(expansion: 12.5, from: 12) == 13)
    // Capped at the first zoom without clusters, and never zooming out.
    #expect(ClusteredPins.zoom(expansion: nil, from: 15) == 16)
    #expect(ClusteredPins.zoom(expansion: nil, from: 17) == 17)
  }
}
