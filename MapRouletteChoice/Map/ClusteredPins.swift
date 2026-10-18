@preconcurrency import MapLibre
import CoreLocation
import UIKit

/// A big campaign's places (over 500) on the map: one clustered GeoJSON source drawn by style
/// layers instead of one annotation view per place, whose redraws took seconds each at 5,000
/// places (L1-CLUSTER; the open-time CI job measures it). Up to zoom 15 nearby places merge into a
/// circle with the number still to check, or a tick when all are checked (brand/pins/README.md "Map
/// clusters"); from zoom 16 every place has its own pin. Places that need another look are never
/// clustered. Radius, zoom and size steps match Android (Kai).
/// Tapping a cluster zooms in; tapping a pin shows the usual callout (a `TaskAnnotation` put over
/// it). VoiceOver gets one element per visible cluster and pin, nearest first, at most 200
/// (`PinOrderMapView`), each with a 44 pt frame.
@MainActor final class ClusteredPins {
  static let threshold = 500

  struct Place {
    let task: LocatedTask
    let coordinate: CLLocationCoordinate2D
    let pin: TaskMapView.Pin
    var id: Int64 { task.id }
  }

  static let sourceID = "campaign-places"
  static let lookSourceID = "campaign-look"
  static let circleLayerID = "campaign-clusters"
  static let countLayerID = "campaign-cluster-counts"
  static let tickLayerID = "campaign-cluster-ticks"
  static let pinLayerID = "campaign-pins"
  static let lookLayerID = "campaign-look-pins"
  private static let tappable: Set<String> = [circleLayerID, countLayerID, tickLayerID, pinLayerID, lookLayerID]
  private static let tickImage = "campaign-cluster-tick"
  private static let pinImages = ["PinTodo", "PinDone", "PinPending", "PinWaiting", "PinLook"]

  /// Opens a place to check.
  var open: (Int64) -> Void
  /// Shows a place's callout.
  var select: (Place) -> Void
  var noun = Noun.place
  /// The person's location, for VoiceOver's order and distances.
  var origin: CLLocationCoordinate2D?
  private var places: [Place] = []
  private var byID: [Int64: Place] = [:]
  private var spoken: [UIAccessibilityElement]?
  private var spokenAt = Date.distantPast

  var isActive: Bool { !places.isEmpty }

  init(open: @escaping (Int64) -> Void, select: @escaping (Place) -> Void) {
    self.open = open
    self.select = select
  }

  func show(_ places: [Place], on map: MLNMapView) {
    self.places = places
    byID = Dictionary(places.map { ($0.id, $0) }) { first, _ in first }
    invalidate()
    // Before the style loads, `restyle` draws them.
    if let style = map.style { draw(in: style, dark: MapStyle.isDark(map)) }
  }

  /// Back to annotation views (a campaign that shrank under the threshold).
  func remove(from map: MLNMapView) {
    places = []
    byID = [:]
    invalidate()
    guard let style = map.style else { return }
    for id in [Self.lookLayerID, Self.pinLayerID, Self.tickLayerID, Self.countLayerID, Self.circleLayerID] {
      if let layer = style.layer(withIdentifier: id) { style.removeLayer(layer) }
    }
    for id in [Self.lookSourceID, Self.sourceID] {
      if let source = style.source(withIdentifier: id) { style.removeSource(source) }
    }
  }

  /// A new style (the appearance changed) has none of the sources or layers.
  func restyle(_ style: MLNStyle, dark: Bool) {
    guard isActive else { return }
    draw(in: style, dark: dark)
  }

  /// The pins and clusters on screen changed: VoiceOver's list is built again when next asked.
  func invalidate() { spoken = nil }

  // MARK: Drawing

  private func draw(in style: MLNStyle, dark: Bool) {
    var clustered: [MLNPointFeature] = []
    var look: [MLNPointFeature] = []
    clustered.reserveCapacity(places.count)
    for place in places {
      let feature = MLNPointFeature()
      feature.coordinate = place.coordinate
      feature.identifier = NSNumber(value: place.id)
      feature.attributes = ["pin": place.pin.imageName, "left": place.pin == .toCheck ? 1 : 0]
      if place.pin == .reported { look.append(feature) } else { clustered.append(feature) }
    }
    let shape = MLNShapeCollectionFeature(shapes: clustered)
    let lookShape = MLNShapeCollectionFeature(shapes: look)
    if let source = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource,
      let lookSource = style.source(withIdentifier: Self.lookSourceID) as? MLNShapeSource
    {
      source.shape = shape
      lookSource.shape = lookShape
      return
    }

    for name in Self.pinImages {
      if let image = UIImage(named: name) { style.setImage(image, forName: name) }
    }
    style.setImage(Self.tick(dark: dark), forName: Self.tickImage)

    // `left`: how many of a cluster's places are still to check.
    let left: [String: [NSExpression]] = [
      "left": [NSExpression(format: "sum:({$featureAccumulated, left})"), NSExpression(forKeyPath: "left")]
    ]
    let source = MLNShapeSource(
      identifier: Self.sourceID, shape: shape,
      options: [.clustered: true, .clusterRadius: 50, .maximumZoomLevelForClustering: 15, .clusterProperties: left])
    let lookSource = MLNShapeSource(identifier: Self.lookSourceID, shape: lookShape, options: nil)
    style.addSource(source)
    style.addSource(lookSource)

    // 36, 44 and 52 pt across for under 100, under 1,000 and more places.
    let circles = MLNCircleStyleLayer(identifier: Self.circleLayerID, source: source)
    circles.predicate = NSPredicate(format: "cluster == YES")
    circles.circleRadius = NSExpression(format: "mgl_step:from:stops:(point_count, 18, %@)", [100: 22, 1000: 26] as NSDictionary)
    circles.circleColor = NSExpression(
      format: "TERNARY(left > 0, %@, %@)", Self.color(0xA84F00), Self.color(dark ? 0x34D399 : 0x1F7A4D))
    // A 3 pt ring while places are left (navy, white on the dark map: Tess AE8); all checked, a
    // 2 pt edge in the tick's colour.
    circles.circleStrokeColor = NSExpression(
      format: "TERNARY(left > 0, %@, %@)", dark ? UIColor.white : Self.color(0x14213D),
      dark ? Self.color(0x0B1220) : UIColor.white)
    circles.circleStrokeWidth = NSExpression(format: "TERNARY(left > 0, 3, 2)")
    style.addLayer(circles)

    // The full number, grouped as the phone's region writes it ("1,240"), never "1.2k".
    let counts = MLNSymbolStyleLayer(identifier: Self.countLayerID, source: source)
    counts.predicate = NSPredicate(format: "cluster == YES AND left > 0")
    let locale = Locale.current.identifier(.bcp47)
    counts.text = NSExpression(mglJSONObject: ["number-format", ["get", "left"], ["locale": locale]] as [Any])
    counts.textFontNames = NSExpression(forConstantValue: ["Noto Sans Bold"])
    counts.textFontSize = NSExpression(format: "mgl_step:from:stops:(point_count, 13, %@)", [1000: 14] as NSDictionary)
    counts.textColor = NSExpression(forConstantValue: UIColor.white)
    counts.textAllowsOverlap = NSExpression(forConstantValue: true)
    counts.textIgnoresPlacement = NSExpression(forConstantValue: true)
    style.addLayer(counts)

    let ticks = MLNSymbolStyleLayer(identifier: Self.tickLayerID, source: source)
    ticks.predicate = NSPredicate(format: "cluster == YES AND left == 0")
    ticks.iconImageName = NSExpression(forConstantValue: Self.tickImage)
    ticks.iconAllowsOverlap = NSExpression(forConstantValue: true)
    ticks.iconIgnoresPlacement = NSExpression(forConstantValue: true)
    style.addLayer(ticks)

    for (id, from, image) in [
      (Self.pinLayerID, source, NSExpression(forKeyPath: "pin")),
      (Self.lookLayerID, lookSource, NSExpression(forConstantValue: "PinLook")),
    ] {
      let pins = MLNSymbolStyleLayer(identifier: id, source: from)
      if from === source { pins.predicate = NSPredicate(format: "cluster != YES") }
      pins.iconImageName = image
      pins.iconAllowsOverlap = NSExpression(forConstantValue: true)
      pins.iconIgnoresPlacement = NSExpression(forConstantValue: true)
      style.addLayer(pins)
    }
  }

  private static func color(_ rgb: Int) -> UIColor {
    UIColor(
      red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255,
      alpha: 1)
  }

  /// White on the light map's done green, near-black on the dark map's lighter green.
  private static func tick(dark: Bool) -> UIImage {
    let symbol = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    let tinted = symbol?.withTintColor(dark ? color(0x0B1220) : .white, renderingMode: .alwaysOriginal)
    let size = tinted?.size ?? CGSize(width: 16, height: 16)
    return UIGraphicsImageRenderer(size: size).image { _ in tinted?.draw(at: .zero) }
  }

  // MARK: Taps

  /// A cluster or pin within 22 pt of `point` (a 44 pt target): a cluster zooms in, a pin shows
  /// its callout. False when nothing is there.
  @discardableResult func tap(at point: CGPoint, on map: MLNMapView) -> Bool {
    let target = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
    let hits = map.visibleFeatures(in: target, styleLayerIdentifiers: Self.tappable)
    func distance(_ feature: any MLNFeature) -> CGFloat {
      let p = map.convert(feature.coordinate, toPointTo: map)
      return hypot(p.x - point.x, p.y - point.y)
    }
    guard let hit = hits.min(by: { distance($0) < distance($1) }) else { return false }
    if let cluster = hit as? MLNPointFeatureCluster {
      zoom(into: cluster, on: map)
    } else if let id = (hit.identifier as? NSNumber)?.int64Value, let place = byID[id] {
      select(place)
    }
    return true
  }

  private func zoom(into cluster: MLNPointFeatureCluster, on map: MLNMapView) {
    guard let source = map.style?.source(withIdentifier: Self.sourceID) as? MLNShapeSource else { return }
    let zoom = max(source.zoomLevel(forExpanding: cluster), map.zoomLevel + 1)
    map.setCenter(cluster.coordinate, zoomLevel: zoom, animated: !UIAccessibility.isReduceMotionEnabled)
  }

  // MARK: VoiceOver

  /// What a VoiceOver double tap does.
  final class Element: UIAccessibilityElement {
    var action: (() -> Void)?
    override func accessibilityActivate() -> Bool {
      guard let action else { return false }
      action()
      return true
    }
  }

  /// The visible clusters and pins, nearest the person first (else north to south), at most
  /// `limit`. Kept briefly: VoiceOver asks for every index in turn.
  func accessibilityElements(in map: MLNMapView, limit: Int) -> [UIAccessibilityElement] {
    if let spoken, Date().timeIntervalSince(spokenAt) < 1 { return spoken }
    let from = origin ?? map.userLocation?.location?.coordinate
    var found: [(key: Double, element: Element)] = []
    for feature in map.visibleFeatures(in: map.bounds, styleLayerIdentifiers: Self.tappable) {
      let coordinate = feature.coordinate
      let element = Element(accessibilityContainer: map)
      if let cluster = feature as? MLNPointFeatureCluster {
        let left = (cluster.attribute(forKey: "left") as? NSNumber)?.intValue ?? 0
        element.accessibilityLabel =
          left > 0
          ? Wording.clusterLeft(left, noun) : Wording.clusterAllChecked(Int(cluster.clusterPointCount), noun)
        element.accessibilityHint = Wording.clusterHint
        element.accessibilityTraits = .button
        element.action = { [weak self, weak map, weak cluster] in
          guard let self, let map, let cluster else { return }
          self.zoom(into: cluster, on: map)
        }
      } else if let id = (feature.identifier as? NSNumber)?.int64Value, let place = byID[id] {
        element.accessibilityLabel = [
          Wording.placeName(place.task.task, noun), TaskLocation.directionText(from, place.coordinate),
        ].compactMap { $0 }.joined(separator: ", ")
        element.accessibilityValue = place.pin.accessibilityValue
        element.accessibilityHint = place.pin.accessibilityHint
        if place.pin.opens {
          element.accessibilityTraits = .button
          element.action = { [weak self] in self?.open(id) }
        }
      } else {
        continue
      }
      let p = map.convert(coordinate, toPointTo: map)
      element.accessibilityFrame = UIAccessibility.convertToScreenCoordinates(
        CGRect(x: p.x - 22, y: p.y - 22, width: 44, height: 44), in: map)
      let key =
        from.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(
          from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) }
        ?? -coordinate.latitude
      found.append((key, element))
    }
    let elements = found.sorted { $0.key < $1.key }.prefix(limit).map(\.element)
    spoken = elements
    spokenAt = Date()
    return elements
  }
}
