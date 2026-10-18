import Foundation
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
}
