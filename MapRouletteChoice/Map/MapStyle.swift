@preconcurrency import MapLibre
import Network
import SwiftUI

/// Which map style to load for the system appearance. OpenFreeMap has one dark style; every
/// OpenFreeMap light style (the campaign map's positron, the task map's liberty) maps to it in
/// dark mode. Any other style URL (a custom MAP_STYLE_URL) is left as configured.
enum MapStyle {
  static let dark = URL(string: "https://tiles.openfreemap.org/styles/dark")!

  static func url(_ light: URL, for scheme: ColorScheme) -> URL {
    scheme == .dark && light.host == dark.host ? dark : light
  }

  @MainActor static func isDark(_ map: MLNMapView) -> Bool { map.styleURL == dark || map.styleURL == plain(dark: true) }

  /// A plain background, loaded instead of a style that failed (offline with none cached, or the
  /// tile server down), so the places drawn on top still show (Android #59 parity). Glyphs still
  /// point at OpenFreeMap: cached ones draw the cluster counts.
  static func plain(dark: Bool) -> URL { dark ? plainDark : plainLight }
  static func isPlain(_ url: URL?) -> Bool { url == plainLight || url == plainDark }
  private static let plainLight = writePlain("plain-light", background: "#F2F1EC")
  private static let plainDark = writePlain("plain-dark", background: "#111827")

  private static func writePlain(_ name: String, background: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-style-\(name).json")
    let style: [String: Any] = [
      "version": 8, "name": name,
      "glyphs": "https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf",
      "sources": [String: Any](),
      "layers": [["id": "background", "type": "background", "paint": ["background-color": background]]],
    ]
    if let data = try? JSONSerialization.data(withJSONObject: style) { try? data.write(to: url, options: .atomic) }
    return url
  }

  /// Swaps a map whose style can't load to the plain background, and keeps SwiftUI updates from
  /// asking for that style again until the wanted style changes (the appearance) or the phone gets
  /// a connection back, which reloads it. Offline, MapLibre can hold the style request instead of
  /// failing, so a style still loading after `wait(online:)` counts as failed too (Android #59, Kai).
  @MainActor final class Fallback {
    private var failed: URL?
    private weak var map: MLNMapView?
    private var timer: Task<Void, Never>?
    private var reconnect: (any NSObjectProtocol)?

    /// How long a style may take before the plain background goes in: 6 s offline, 20 s online
    /// (Android #59).
    nonisolated static func wait(online: Bool) -> Duration { online ? .seconds(20) : .seconds(6) }

    isolated deinit {
      timer?.cancel()
      if let reconnect { NotificationCenter.default.removeObserver(reconnect) }
    }

    /// From `mapViewWillStartLoadingMap`: starts the clock on this style.
    func styleStarted(on map: MLNMapView) {
      self.map = map
      timer?.cancel()
      guard let url = map.styleURL, !MapStyle.isPlain(url) else { return }
      let wait = Self.wait(online: Connection.shared.online)
      timer = Task { [weak self, weak map] in
        try? await Task.sleep(for: wait)
        guard !Task.isCancelled, let self, let map, map.styleURL == url else { return }
        self.styleFailed(on: map)
      }
    }

    /// From `didFinishLoading style`.
    func styleLoaded() {
      timer?.cancel()
      timer = nil
    }

    /// From `mapViewDidFailLoadingMap`, or when the style took too long.
    func styleFailed(on map: MLNMapView) {
      timer?.cancel()
      timer = nil
      guard let url = map.styleURL, !MapStyle.isPlain(url) else { return }
      self.map = map
      failed = url
      map.styleURL = MapStyle.plain(dark: url == MapStyle.dark)
      guard reconnect == nil else { return }
      reconnect = NotificationCenter.default.addObserver(forName: Connection.back, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.retry() }
      }
    }

    /// Whether `map` should load `wanted`: it isn't showing it, and it isn't the one that failed.
    func shouldLoad(_ wanted: URL, on map: MLNMapView) -> Bool {
      guard map.styleURL != wanted, wanted != failed else { return false }
      failed = nil
      return true
    }

    /// The connection is back: try the real style again.
    private func retry() {
      guard let failed, let map, MapStyle.isPlain(map.styleURL) else { return }
      self.failed = nil
      map.styleURL = failed
    }
  }

  /// Whether the phone has a connection, for the fallback's wait, and a `back` notification when
  /// it returns.
  @MainActor final class Connection {
    static let shared = Connection()
    static let back = Notification.Name("MapStyle.Connection.back")
    private(set) var online = true
    private let monitor = NWPathMonitor()

    private init() {
      monitor.pathUpdateHandler = { path in
        let online = path.status == .satisfied
        Task { @MainActor in
          let shared = Connection.shared
          let returned = online && !shared.online
          shared.online = online
          if returned { NotificationCenter.default.post(name: Connection.back, object: nil) }
        }
      }
      monitor.start(queue: DispatchQueue(label: "map-style.network"))
    }
  }

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
