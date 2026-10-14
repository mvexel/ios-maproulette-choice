@preconcurrency import MapLibre
import CoreLocation
import SwiftUI

/// Another place in the campaign, drawn as a dot on the close-up map.
struct Neighbour: Hashable, Sendable {
  enum State: String, Sendable { case open, checked, look }
  let id: Int64
  let latitude: Double
  let longitude: Double
  var state: State

  var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// The task screen's close-up map (design/which-one-spec.md §A, §B): pan and pinch, north-up, the
/// target as its brand pin, the campaign's other places as small dots under it, and the blue dot
/// with its heading. The first frame fits you and the target (zoom 17–20); without you, or more
/// than 150 m away, the target alone at 19. `recenter` changing restores that frame. VoiceOver
/// reads the map as one element (the SwiftUI side labels it).
struct CloseUpMapView: UIViewRepresentable {
  let styleURL: URL
  let target: CLLocationCoordinate2D
  let pin: TaskMapView.Pin
  let name: String
  let neighbours: [Neighbour]
  /// The live position, for the first frame.
  let you: CLLocationCoordinate2D?
  var recenter = 0
  /// The aerial photo under the labels instead of the street map (design/which-one-spec.md §D).
  var aerial = false
  /// Buildings draw their outline and crossings a bar across the street (which-one-sprint.md §3 E).
  var kind: Footprint.Kind = .point
  /// The person moved the map (pan or pinch); the recenter button shows.
  var moved: (Bool) -> Void = { _ in }
  /// How many neighbours are in view, for the "Grey dots…" line: after each frame and each move.
  var framed: (Int) -> Void = { _ in }
  /// A `-demoFix` reading, drawn as the blue dot: the map's own puck follows only the real location.
  var demoYou: CLLocationCoordinate2D?

  static let farAway: CLLocationDistance = 150
  static let zoomRange: ClosedRange<Double> = 17...20
  static let targetZoom: Double = 19

  /// USDA NAIP 2024 (60 cm), public domain and keyless, from its ImageServer: each tile is an
  /// `exportImage` of the tile's Web Mercator box (design/imagery-licence-check.md). Rendered on
  /// demand, so requests stop at z19 and MapLibre overzooms to 20.
  static let aerialTiles =
    "https://apps.geo.fpac.usda.gov/geo-imagery/rest/services/naip/conus_naip/ImageServer/exportImage?f=image&format=jpg&bbox={bbox-epsg-3857}&bboxSR=3857&imageSR=3857&size=256,256"
  static let aerialMaxZoom = 19
  static let aerialCredit = "Imagery: USDA NAIP 2024"

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> MLNMapView {
    let map = CloseUpMap(frame: .zero, styleURL: styleURL)
    map.delegate = context.coordinator
    map.tintColor = .systemBlue
    // North-up: the heading on the blue dot shows facing (§A).
    map.allowsRotating = false
    map.allowsTilting = false
    map.compassView.isHidden = true
    map.showsUserLocation = Self.locationAllowed
    map.showsUserHeadingIndicator = true
    map.setCenter(target, zoomLevel: Self.targetZoom, animated: false)
    let annotation = TaskMapView.TaskAnnotation()
    annotation.coordinate = target
    annotation.pin = pin
    annotation.title = name
    map.addAnnotation(annotation)
    return map
  }

  func updateUIView(_ map: MLNMapView, context: Context) {
    let c = context.coordinator
    c.parent = self
    if map.showsUserLocation != Self.locationAllowed { map.showsUserLocation = Self.locationAllowed }
    if let style = map.style {
      c.drawNeighbours(in: style)
      c.drawFootprints(in: style)
      c.showAerial(aerial, in: style)
      c.drawDemoYou(in: style)
    }
    if recenter != c.recentered {
      c.recentered = recenter
      c.frame(map, report: false)
    } else if !c.userMoved, !c.framedWithYou, you != nil {
      // The first fix after opening: frame you and the target, unless the map was moved.
      c.frame(map, report: true)
    }
  }

  private static var locationAllowed: Bool {
    switch CLLocationManager().authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: true
    default: false
    }
  }

  @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
    var parent: CloseUpMapView?
    var recentered = 0
    var userMoved = false
    var framedWithYou = false
    private var drawn: [Neighbour] = []
    /// Footprints found in the loaded tiles: the target's, and the neighbours' by id. Places
    /// already looked for are not looked for again.
    private var targetFootprint: [CLLocationCoordinate2D]?
    private var footprints: [Int64: [CLLocationCoordinate2D]] = [:]
    private var lookedForTarget = false
    private var lookedFor: Set<Int64> = []
    private var drawnFootprints: [String] = []
    private var styleLoaded = false

    /// You and the target with 40 pt padding, zoom clamped to 17–20; the target alone at 19 without you
    /// or when you're far.
    func frame(_ map: MLNMapView, report: Bool) {
      guard let parent, map.bounds.width > 0 else { return }
      let target = parent.target
      if let you = parent.you, TaskLocation.meters(you, target) <= CloseUpMapView.farAway {
        framedWithYou = true
        let bounds = MLNCoordinateBounds(
          sw: CLLocationCoordinate2D(latitude: min(you.latitude, target.latitude), longitude: min(you.longitude, target.longitude)),
          ne: CLLocationCoordinate2D(latitude: max(you.latitude, target.latitude), longitude: max(you.longitude, target.longitude)))
        map.setVisibleCoordinateBounds(
          bounds, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false, completionHandler: nil)
        let zoom = min(max(map.zoomLevel, CloseUpMapView.zoomRange.lowerBound), CloseUpMapView.zoomRange.upperBound)
        if zoom != map.zoomLevel { map.setCenter(map.centerCoordinate, zoomLevel: zoom, animated: false) }
      } else {
        if parent.you != nil { framedWithYou = true }
        map.setCenter(target, zoomLevel: CloseUpMapView.targetZoom, animated: false)
      }
      setMoved(false)
      if report { reportFramed(map) }
    }

    private func setMoved(_ value: Bool) {
      guard userMoved != value else { return }
      userMoved = value
      let moved = parent?.moved
      // Not during a SwiftUI update.
      DispatchQueue.main.async { moved?(value) }
    }

    private func reportFramed(_ map: MLNMapView) {
      guard let parent else { return }
      let visible = map.visibleCoordinateBounds
      let count = parent.neighbours.filter { n in
        n.latitude >= visible.sw.latitude && n.latitude <= visible.ne.latitude && n.longitude >= visible.sw.longitude
          && n.longitude <= visible.ne.longitude
      }.count
      let framed = parent.framed
      DispatchQueue.main.async { framed(count) }
    }

    static let sourceID = "neighbours"
    static let aerialID = "aerial"

    /// The photo sits under the first label layer, so street names stay on top and the street map's
    /// fills and lines are covered. Added once, then only shown or hidden.
    func showAerial(_ on: Bool, in style: MLNStyle) {
      guard styleLoaded else { return }
      if let layer = style.layer(withIdentifier: Self.aerialID) {
        if layer.isVisible != on { layer.isVisible = on }
        return
      }
      guard on else { return }
      let source = MLNRasterTileSource(
        identifier: Self.aerialID, tileURLTemplates: [CloseUpMapView.aerialTiles],
        options: [.tileSize: 256, .maximumZoomLevel: CloseUpMapView.aerialMaxZoom])
      style.addSource(source)
      let layer = MLNRasterStyleLayer(identifier: Self.aerialID, source: source)
      if let labels = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
        style.insertLayer(layer, below: labels)
      } else if let dots = style.layer(withIdentifier: "\(Self.sourceID)-\(Neighbour.State.checked.rawValue)") {
        style.insertLayer(layer, below: dots)
      } else {
        style.addLayer(layer)
      }
    }

    /// One shape source, one circle layer per state (§B): open gray with a white ring, checked
    /// green and smaller, needs another look gray with an amber ring. Style layers sit under the
    /// target's pin view.
    func drawNeighbours(in style: MLNStyle) {
      guard styleLoaded, let parent, parent.neighbours != drawn || style.source(withIdentifier: Self.sourceID) == nil
      else { return }
      drawn = parent.neighbours
      let features = parent.neighbours.map { n in
        let f = MLNPointFeature()
        f.coordinate = n.coordinate
        f.attributes = ["state": n.state.rawValue]
        return f
      }
      if let source = style.source(withIdentifier: Self.sourceID) as? MLNShapeSource {
        source.shape = MLNShapeCollectionFeature(shapes: features)
        return
      }
      let source = MLNShapeSource(identifier: Self.sourceID, shape: MLNShapeCollectionFeature(shapes: features), options: nil)
      style.addSource(source)
      func layer(_ state: Neighbour.State, radius: Double, fill: UIColor, ring: UIColor?, ringWidth: Double) {
        let l = MLNCircleStyleLayer(identifier: "\(Self.sourceID)-\(state.rawValue)", source: source)
        l.predicate = NSPredicate(format: "state == %@", state.rawValue)
        l.circleRadius = NSExpression(forConstantValue: radius)
        l.circleColor = NSExpression(forConstantValue: fill)
        if let ring {
          l.circleStrokeColor = NSExpression(forConstantValue: ring)
          l.circleStrokeWidth = NSExpression(forConstantValue: ringWidth)
        }
        style.addLayer(l)
      }
      layer(.checked, radius: 4, fill: UIColor(named: "PinDoneColor") ?? .systemGreen, ring: nil, ringWidth: 0)
      layer(.open, radius: 5, fill: .systemGray, ring: .white, ringWidth: 1.5)
      layer(.look, radius: 5, fill: .systemGray, ring: UIColor(named: "BrandAmber") ?? .systemOrange, ringWidth: 2)
    }

    static let footprintID = "footprints"

    /// Once the tiles in view are loaded, looks up footprints for the target and for neighbours in
    /// view that haven't been looked up.
    func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
      guard let parent, parent.kind != .point, let style = mapView.style else { return }
      let visible = mapView.visibleCoordinateBounds
      let todo = parent.neighbours.filter { n in
        !lookedFor.contains(n.id) && n.latitude >= visible.sw.latitude && n.latitude <= visible.ne.latitude
          && n.longitude >= visible.sw.longitude && n.longitude <= visible.ne.longitude
      }
      guard !lookedForTarget || !todo.isEmpty else { return }
      let shapes = Self.tileLines(in: style, sourceLayer: parent.kind == .building ? "building" : "transportation")
      guard !shapes.isEmpty else { return }
      func find(_ point: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        parent.kind == .building ? Footprint.outline(for: point, in: shapes) : Footprint.bar(for: point, streets: shapes)
      }
      if !lookedForTarget {
        lookedForTarget = true
        targetFootprint = find(parent.target)
      }
      for n in todo {
        lookedFor.insert(n.id)
        footprints[n.id] = find(n.coordinate)
      }
      drawFootprints(in: style)
    }

    /// Building rings or street lines from the style's vector tiles, in the loaded tiles only.
    /// Streets are the ones cars use: a crossing sits on one.
    private static func tileLines(in style: MLNStyle, sourceLayer: String) -> [[CLLocationCoordinate2D]] {
      let sourceID = style.layers.lazy.compactMap { $0 as? MLNVectorStyleLayer }
        .first { $0.sourceLayerIdentifier == sourceLayer }?.sourceIdentifier
      guard let sourceID, let source = style.source(withIdentifier: sourceID) as? MLNVectorTileSource else { return [] }
      let streets = ["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service"]
      let predicate = sourceLayer == "transportation" ? NSPredicate(format: "%K IN %@", "class", streets) : nil
      func points(_ shape: MLNMultiPoint) -> [CLLocationCoordinate2D] {
        Array(UnsafeBufferPointer(start: shape.coordinates, count: Int(shape.pointCount)))
      }
      return source.features(sourceLayerIdentifiers: [sourceLayer], predicate: predicate).flatMap { feature -> [[CLLocationCoordinate2D]] in
        switch feature {
        case let f as MLNPolygonFeature: [points(f)]
        case let f as MLNMultiPolygonFeature: f.polygons.map(points)
        case let f as MLNPolylineFeature: [points(f)]
        case let f as MLNMultiPolylineFeature: f.polylines.map(points)
        default: []
        }
      }
    }

    /// Outlines (fill and line) or bars (a wide cased line), coloured like the pins and dots: the
    /// target navy, open gray, checked green, needs another look amber. Under the dots and the pin.
    func drawFootprints(in style: MLNStyle) {
      guard styleLoaded, let parent, parent.kind != .point else { return }
      let state = Dictionary(uniqueKeysWithValues: parent.neighbours.map { ($0.id, $0.state.rawValue) })
      var shapes: [(String, [CLLocationCoordinate2D])] = targetFootprint.map { [("target", $0)] } ?? []
      for (id, ring) in footprints.sorted(by: { $0.key < $1.key }) {
        if let s = state[id] { shapes.append((s, ring)) }
      }
      let key = shapes.map { "\($0.0)\($0.1.first?.latitude ?? 0)" }
      guard key != drawnFootprints || style.source(withIdentifier: Self.footprintID) == nil else { return }
      drawnFootprints = key
      let features: [MLNShape & MLNFeature] = shapes.map { s, points in
        var points = points
        if parent.kind == .building {
          let f = MLNPolygonFeature(coordinates: &points, count: UInt(points.count))
          f.attributes = ["state": s]
          return f
        }
        let f = MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
        f.attributes = ["state": s]
        return f
      }
      if let source = style.source(withIdentifier: Self.footprintID) as? MLNShapeSource {
        source.shape = MLNShapeCollectionFeature(shapes: features)
        return
      }
      let source = MLNShapeSource(identifier: Self.footprintID, shape: MLNShapeCollectionFeature(shapes: features), options: nil)
      style.addSource(source)
      let below = style.layer(withIdentifier: "\(Self.sourceID)-\(Neighbour.State.checked.rawValue)")
      func insert(_ layer: MLNStyleLayer) {
        if let below { style.insertLayer(layer, below: below) } else { style.addLayer(layer) }
      }
      let colors: [(String, UIColor)] = [
        ("open", .systemGray), ("checked", UIColor(named: "PinDoneColor") ?? .systemGreen),
        ("look", UIColor(named: "BrandAmber") ?? .systemOrange), ("target", UIColor(named: "BrandNavy") ?? .label),
      ]
      for (s, color) in colors {
        let target = s == "target"
        let id = "\(Self.footprintID)-\(s)"
        let predicate = NSPredicate(format: "state == %@", s)
        if parent.kind == .building {
          let fill = MLNFillStyleLayer(identifier: "\(id)-fill", source: source)
          fill.predicate = predicate
          fill.fillColor = NSExpression(forConstantValue: color)
          fill.fillOpacity = NSExpression(forConstantValue: target ? 0.25 : 0.12)
          insert(fill)
          let line = MLNLineStyleLayer(identifier: "\(id)-line", source: source)
          line.predicate = predicate
          line.lineColor = NSExpression(forConstantValue: color)
          line.lineWidth = NSExpression(forConstantValue: target ? 3 : 1.5)
          insert(line)
        } else {
          let casing = MLNLineStyleLayer(identifier: "\(id)-casing", source: source)
          casing.predicate = predicate
          casing.lineColor = NSExpression(forConstantValue: color)
          casing.lineWidth = NSExpression(forConstantValue: target ? 12 : 8)
          insert(casing)
          let stripes = MLNLineStyleLayer(identifier: "\(id)-stripes", source: source)
          stripes.predicate = predicate
          stripes.lineColor = NSExpression(forConstantValue: UIColor.white)
          stripes.lineWidth = NSExpression(forConstantValue: target ? 8 : 5)
          stripes.lineDashPattern = NSExpression(forConstantValue: [0.4, 0.4])
          insert(stripes)
        }
      }
    }

    static let demoYouID = "demo-you"

    func drawDemoYou(in style: MLNStyle) {
      guard styleLoaded, let you = parent?.demoYou else { return }
      let point = MLNPointFeature()
      point.coordinate = you
      if let source = style.source(withIdentifier: Self.demoYouID) as? MLNShapeSource {
        source.shape = point
        return
      }
      let source = MLNShapeSource(identifier: Self.demoYouID, shape: point, options: nil)
      style.addSource(source)
      let dot = MLNCircleStyleLayer(identifier: Self.demoYouID, source: source)
      dot.circleRadius = NSExpression(forConstantValue: 8)
      dot.circleColor = NSExpression(forConstantValue: UIColor.systemBlue)
      dot.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
      dot.circleStrokeWidth = NSExpression(forConstantValue: 3)
      style.addLayer(dot)
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
      // 3D buildings tilt and hide the street at this zoom; flat footprints keep the context.
      for buildings in style.layers.compactMap({ $0 as? MLNFillExtrusionStyleLayer }) {
        buildings.isVisible = false
        guard let sourceID = buildings.sourceIdentifier, let source = style.source(withIdentifier: sourceID),
          style.layer(withIdentifier: "\(buildings.identifier)-flat") == nil
        else { continue }
        let flat = MLNFillStyleLayer(identifier: "\(buildings.identifier)-flat", source: source)
        flat.sourceLayerIdentifier = buildings.sourceLayerIdentifier
        flat.predicate = buildings.predicate
        flat.fillColor = NSExpression(forConstantValue: UIColor(white: 0.86, alpha: 1))
        flat.fillOutlineColor = NSExpression(forConstantValue: UIColor(white: 0.7, alpha: 1))
        style.insertLayer(flat, below: buildings)
      }
      for layer in style.layers {
        if layer is MLNFillExtrusionStyleLayer { continue }
        if let symbols = layer as? MLNSymbolStyleLayer, let source = symbols.sourceLayerIdentifier,
          TaskMapView.Coordinator.hiddenSymbolSources.contains(source)
        {
          symbols.isVisible = false
        }
      }
      styleLoaded = true
      drawNeighbours(in: style)
      if let parent { showAerial(parent.aerial, in: style) }
      drawDemoYou(in: style)
      if !userMoved { frame(mapView, report: true) }
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated: Bool) {
      let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom]
      if !reason.intersection(gestures).isEmpty { setMoved(true) }
      reportFramed(mapView)
    }

    func mapView(_ mapView: MLNMapView, viewFor annotation: any MLNAnnotation) -> MLNAnnotationView? {
      guard let task = annotation as? TaskMapView.TaskAnnotation else { return nil }
      let view =
        mapView.dequeueReusableAnnotationView(withIdentifier: TaskMapView.PinView.reuseID) as? TaskMapView.PinView
        ?? TaskMapView.PinView(reuseID: TaskMapView.PinView.reuseID)
      view.configure(task, onActivate: nil)
      return view
    }

    /// The target pin needs no callout here: it's the place on screen.
    func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: any MLNAnnotation) -> Bool { false }
  }
}

/// The map is one VoiceOver element, labelled by the task screen: MapLibre lists its pin, puck and
/// attribution through its own accessibility container methods otherwise.
private final class CloseUpMap: MLNMapView {
  override func accessibilityElementCount() -> Int { 0 }
  override func accessibilityElement(at index: Int) -> Any? { nil }
  override func index(ofAccessibilityElement element: Any) -> Int { NSNotFound }
}
