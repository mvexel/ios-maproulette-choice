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
}
