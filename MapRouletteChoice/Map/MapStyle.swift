@preconcurrency import MapLibre
import SwiftUI

/// Which map style to load for the system appearance. OpenFreeMap has one dark style; every
/// OpenFreeMap light style (the campaign map's positron, the task map's liberty) maps to it in
/// dark mode. Any other style URL (a custom MAP_STYLE_URL) is left as configured.
enum MapStyle {
  static let dark = URL(string: "https://tiles.openfreemap.org/styles/dark")!

  static func url(_ light: URL, for scheme: ColorScheme) -> URL {
    scheme == .dark && light.host == dark.host ? dark : light
  }

  @MainActor static func isDark(_ map: MLNMapView) -> Bool { map.styleURL == dark }

  /// The dark style's street names are too dim to read outdoors (which-one-spec.md, "Dark map" 4).
  /// Called once the dark style has loaded.
  @MainActor static func brightenLabels(in style: MLNStyle) {
    for case let symbols as MLNSymbolStyleLayer in style.layers {
      symbols.textColor = NSExpression(forConstantValue: UIColor(white: 0xB8 / 255.0, alpha: 1))
      symbols.textHaloColor = NSExpression(forConstantValue: UIColor.black)
      symbols.textHaloWidth = NSExpression(forConstantValue: 1)
    }
  }
}

extension UIView {
  /// A thin white halo in dark mode. The navy pins have no dark variant, so without it they
  /// vanish into the dark map. It follows appearance changes.
  func haloInDarkMode() {
    applyHalo()
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UIView, _: UITraitCollection) in
      view.applyHalo()
    }
  }

  private func applyHalo() {
    layer.shadowColor = UIColor.white.cgColor
    layer.shadowOffset = .zero
    layer.shadowRadius = 2
    layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 1 : 0
  }
}
