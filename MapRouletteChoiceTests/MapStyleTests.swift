import Foundation
@preconcurrency import MapLibre
import SwiftUI
import Testing

@testable import MapRouletteChoice

@Suite struct MapStyleTests {
  @Test func darkModeUsesOpenFreeMapDark() {
    #expect(MapStyle.url(AppConfig.defaultStyle, for: .dark) == MapStyle.dark)
    #expect(MapStyle.url(AppConfig.detailStyle, for: .dark) == MapStyle.dark)
    #expect(MapStyle.url(AppConfig.defaultStyle, for: .light) == AppConfig.defaultStyle)
    #expect(MapStyle.url(AppConfig.detailStyle, for: .light) == AppConfig.detailStyle)
  }

  @Test func customStyleIsLeftAlone() {
    let custom = URL(string: "https://example.org/style.json")!
    #expect(MapStyle.url(custom, for: .dark) == custom)
  }

  /// The plain background a map falls back to when its style can't load (Android #59 parity).
  @Test func plainStylesAreValidBackgrounds() throws {
    for dark in [false, true] {
      let url = MapStyle.plain(dark: dark)
      #expect(MapStyle.isPlain(url))
      let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      #expect(json["version"] as? Int == 8)
      let layers = try #require(json["layers"] as? [[String: Any]])
      #expect(layers.map { $0["type"] as? String } == ["background"])
    }
    #expect(MapStyle.plain(dark: true) != MapStyle.plain(dark: false))
    #expect(!MapStyle.isPlain(AppConfig.defaultStyle))
  }

  /// Android #59's waits before the plain background goes in.
  @Test func fallbackWaitsMatchAndroid() {
    #expect(MapStyle.Fallback.wait(online: false) == .seconds(6))
    #expect(MapStyle.Fallback.wait(online: true) == .seconds(20))
  }

  /// The clock starts from makeUIView, for the style MLNMapView's init already requested (Tess
  /// AB18: the delegate's will-start call comes too late for it). The style here never loads.
  @MainActor @Test func firstStyleIsTimed() async throws {
    let (map, style) = Self.stalledMap()
    let fallback = MapStyle.Fallback(wait: { _ in .milliseconds(100) }, retryEvery: .seconds(60))
    fallback.styleStarted(on: map)
    try await Task.sleep(for: .milliseconds(500))
    #expect(MapStyle.isPlain(map.styleURL), "plain after the wait, not after the network timeout")
    #expect(!fallback.shouldLoad(style, on: map), "SwiftUI doesn't ask for the failed style again")
  }

  /// A connection coming back reloads the real style once.
  @MainActor @Test func connectionBackReloads() async throws {
    let (map, style) = Self.stalledMap()
    let fallback = MapStyle.Fallback(wait: { _ in .seconds(60) }, retryEvery: .seconds(60))
    fallback.styleFailed(on: map)
    #expect(MapStyle.isPlain(map.styleURL))
    NotificationCenter.default.post(name: MapStyle.Connection.back, object: nil)
    try await Task.sleep(for: .milliseconds(100))  // delivered on the main queue
    #expect(map.styleURL == style)
  }

  /// Online, a style that stalled is tried again without a connection change (Tess AB18).
  @MainActor @Test func stalledStyleRetriesWhileOnline() async throws {
    let (map, style) = Self.stalledMap()
    let fallback = MapStyle.Fallback(wait: { _ in .seconds(60) }, retryEvery: .milliseconds(100))
    fallback.styleFailed(on: map)
    #expect(MapStyle.isPlain(map.styleURL))
    try await Task.sleep(for: .milliseconds(500))
    #expect(!MapStyle.Connection.shared.online || map.styleURL == style)
  }

  @MainActor private static func stalledMap() -> (MLNMapView, URL) {
    let style = URL(string: "https://style.invalid/never.json")!
    return (MLNMapView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), styleURL: style), style)
  }
}
