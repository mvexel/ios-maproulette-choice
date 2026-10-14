import SwiftUI

/// Which map style to load for the system appearance. OpenFreeMap has one dark style; every
/// OpenFreeMap light style (the campaign map's positron, the task map's liberty) maps to it in
/// dark mode. Any other style URL (a custom MAP_STYLE_URL) is left as configured.
enum MapStyle {
  static let dark = URL(string: "https://tiles.openfreemap.org/styles/dark")!

  static func url(_ light: URL, for scheme: ColorScheme) -> URL {
    scheme == .dark && light.host == dark.host ? dark : light
  }
}
