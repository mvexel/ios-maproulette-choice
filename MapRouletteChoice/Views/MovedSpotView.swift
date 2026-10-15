@preconcurrency import MapLibre
import CoreLocation
import MapRoulette
import SwiftUI

/// "Where is the stop now?" (design/not-here-moved.md §3.2): a full-screen map centered on where
/// the map has the place. The participant taps the map, or stands at the place and uses their
/// location; the navy pin can then be dragged. Only that one spot is saved. With VoiceOver,
/// "I'm standing at it" is the way in, and the pin is adjustable: swipe up or down to move it 5 m
/// north or south, or use the east and west actions.
struct MovedSpotView: View {
  /// Where the map has the place now.
  let mapped: CLLocationCoordinate2D
  let noun: Noun
  let save: (MovedLocation) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var spot: CLLocationCoordinate2D?
  @State private var source = MovedLocation.Source.tap
  /// The latest location fix good enough for "I'm standing at it".
  @State private var fix: CLLocationCoordinate2D?
  @State private var locator = Locator(accuracy: kCLLocationAccuracyBest)
  /// Bumped when the location permission may have changed, so the map shows the puck.
  @State private var asked = 0

  /// Distances that change what can be saved (§3.2 step 3).
  static let tooClose: CLLocationDistance = 5
  static let far: CLLocationDistance = 150
  static let tooFar: CLLocationDistance = 500
  /// A fix less accurate than this doesn't enable "I'm standing at it".
  static let goodFix: CLLocationAccuracy = 50
  /// One VoiceOver adjustment.
  static let step: CLLocationDistance = 5

  private var distance: CLLocationDistance? { spot.map { TaskLocation.meters(mapped, $0) } }

  private var canSave: Bool {
    guard let distance else { return false }
    return distance >= Self.tooClose && distance <= Self.tooFar
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Text(Wording.movedTitle(noun)).font(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Text(Wording.movedHelp)
        Button {
          guard let fix else { return }
          spot = fix
          source = .here
        } label: {
          Label(Wording.standingAtIt, systemImage: "location.fill")
            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(fix == nil)
        // Disabled until a fix is accurate enough; say so, so it doesn't look broken.
        if fix == nil { Text(Wording.waitingForFix).font(.footnote).foregroundStyle(.secondary) }
        map
        status
        Button {
          guard let spot, canSave, let location = try? MovedLocation(
            latitude: spot.latitude, longitude: spot.longitude, source: source)
          else { return }
          save(location)
        } label: {
          Text(Wording.saveThisSpot).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSave)
      }
      .padding()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(Wording.cancel) { dismiss() } }
      }
    }
    .onAppear(perform: locate)
    .onDisappear { locator.stop() }
  }

  private var map: some View {
    SpotMapView(
      mapped: mapped, spot: spot, asked: asked,
      picked: { coordinate in
        spot = coordinate
        source = .tap
      },
      located: { coordinate in
        #if DEBUG
          // `-demoHere` pins the fix; the simulator's own location would replace it.
          if ProcessInfo.processInfo.arguments.contains("-demoHere") { return }
        #endif
        fix = coordinate
      }
    )
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .frame(maxHeight: .infinity)
    // VoiceOver can't tap a spot on a map: the pin is adjustable once "I'm standing at it" placed it.
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("New spot")
    .accessibilityValue(spotDescription)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: move(north: Self.step)
      case .decrement: move(north: -Self.step)
      @unknown default: break
      }
    }
    .accessibilityAction(named: "Move east") { move(east: Self.step) }
    .accessibilityAction(named: "Move west") { move(east: -Self.step) }
    .accessibilityHidden(spot == nil)
  }

  @ViewBuilder private var status: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let distance {
        Text(Wording.movedDistance(distance)).font(.headline)
        if distance < Self.tooClose {
          Text(Wording.movedTooClose)
        } else if distance > Self.tooFar {
          Text(Wording.movedTooFar(noun))
        } else if distance > Self.far {
          Text(Wording.movedFar(distance, noun))
        }
      }
      Text(source == .here && spot != nil ? Wording.spotIsHere(noun) : Wording.spotOnly)
        .font(.footnote).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.updatesFrequently)
  }

  /// "About 30 m northeast of where the map has it", for VoiceOver.
  private var spotDescription: String {
    guard let spot, let distance else { return "" }
    // Under 5 m a compass direction is noise.
    guard distance >= 5 else { return "Where the map has it" }
    return "About \(Wording.movedMeasure(distance)) \(TaskLocation.compass(TaskLocation.bearing(from: mapped, to: spot))) of where the map has it"
  }

  private func move(north: CLLocationDistance = 0, east: CLLocationDistance = 0) {
    guard let current = spot else { return }
    let metersPerDegree = 111_320.0
    spot = CLLocationCoordinate2D(
      latitude: current.latitude + north / metersPerDegree,
      longitude: current.longitude + east / (metersPerDegree * cos(current.latitude * .pi / 180)))
    source = .tap
  }

  private func locate() {
    #if DEBUG
      // `-demoHere`: a fix about 30 m east of the place, for screenshots of "I'm standing at it".
      if ProcessInfo.processInfo.arguments.contains("-demoHere") {
        fix = CLLocationCoordinate2D(
          latitude: mapped.latitude, longitude: mapped.longitude + 30 / (111_320 * cos(mapped.latitude * .pi / 180)))
        return
      }
    #endif
    // Asks for permission if needed; the map's own updates then keep the fix current.
    locator.locate { result in
      asked += 1
      if case .found(let coordinate) = result, fix == nil { fix = coordinate }
    }
  }
}

/// The map behind `MovedSpotView`: the place where the map has it (a gray hollow marker labeled
/// "On the map"), the participant's pick (a navy pin, draggable), and a dashed line between them.
/// Not `interactive`, it's the fixed map on the review screen, framed on both points.
struct SpotMapView: UIViewRepresentable {
  let mapped: CLLocationCoordinate2D
  let spot: CLLocationCoordinate2D?
  var interactive = true
  /// Changes when the location permission may have; the puck shows once it's allowed.
  var asked = 0
  var picked: (CLLocationCoordinate2D) -> Void = { _ in }
  var located: (CLLocationCoordinate2D) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator(picked: picked, located: located) }

  func makeUIView(context: Context) -> MLNMapView {
    let map = MLNMapView(frame: .zero, styleURL: MapStyle.url(AppConfig.detailStyle, for: context.environment.colorScheme))
    map.delegate = context.coordinator
    map.tintColor = .systemBlue
    map.setCenter(mapped, zoomLevel: 18, animated: false)
    let mappedMarker = MappedSpot()
    mappedMarker.coordinate = mapped
    map.addAnnotation(mappedMarker)
    context.coordinator.mapped = mapped
    context.coordinator.interactive = interactive
    guard interactive else {
      map.isUserInteractionEnabled = false
      map.compassView.isHidden = true
      return map
    }
    map.compassViewPosition = .topRight
    map.showsUserLocation = Self.locationAllowed
    let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
    // A double tap still zooms.
    for case let other as UITapGestureRecognizer in map.gestureRecognizers ?? [] where other.numberOfTapsRequired == 2 {
      tap.require(toFail: other)
    }
    map.addGestureRecognizer(tap)
    return map
  }

  func updateUIView(_ map: MLNMapView, context: Context) {
    context.coordinator.picked = picked
    context.coordinator.located = located
    let style = MapStyle.url(AppConfig.detailStyle, for: context.environment.colorScheme)
    if map.styleURL != style { map.styleURL = style }
    if interactive, map.showsUserLocation != Self.locationAllowed { map.showsUserLocation = Self.locationAllowed }
    context.coordinator.show(spot, on: map)
    if !interactive { context.coordinator.frameBoth(on: map) }
  }

  private static var locationAllowed: Bool {
    switch CLLocationManager().authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: true
    default: false
    }
  }

  final class MappedSpot: MLNPointAnnotation {}
  final class NewSpot: MLNPointAnnotation {}

  /// Gray hollow circle with "On the map" under it.
  final class MappedSpotView: MLNAnnotationView {
    static let reuseID = "mapped"

    init(reuseID: String) {
      super.init(annotation: nil, reuseIdentifier: reuseID)
      frame = CGRect(x: 0, y: 0, width: 22, height: 22)
      scalesWithViewingDistance = false
      layer.cornerRadius = 11
      layer.borderWidth = 3
      layer.borderColor = UIColor.systemGray.cgColor
      backgroundColor = UIColor.systemBackground.withAlphaComponent(0.6)
      let label = UILabel()
      label.text = Wording.onTheMap
      label.font = .preferredFont(forTextStyle: .caption1)
      label.textColor = .label
      label.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
      label.sizeToFit()
      label.frame.origin = CGPoint(x: (22 - label.frame.width) / 2, y: 24)
      addSubview(label)
      clipsToBounds = false
      isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  }

  /// The navy pin; its tip is the spot. Dragging reports where it was dropped.
  final class NewSpotView: MLNAnnotationView {
    static let reuseID = "new"
    var dropped: ((CLLocationCoordinate2D) -> Void)?

    private let image = UIImageView()

    init(reuseID: String) {
      super.init(annotation: nil, reuseIdentifier: reuseID)
      frame = CGRect(x: 0, y: 0, width: 44, height: 44)
      scalesWithViewingDistance = false
      image.frame = bounds
      image.contentMode = .center
      addSubview(image)
      isDraggable = true
      isAccessibilityElement = false
      applyAppearance()
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: NewSpotView, _: UITraitCollection) in
        view.applyAppearance()
      }
    }

    /// Light: the navy pin, its tip on the spot. Dark: a white disc with the navy pin glyph and a
    /// dark halo, centred on the spot, so it can't be missed on the dark map (which-one-spec.md,
    /// "Dark map" 1).
    private func applyAppearance() {
      let navy = UIColor(named: "BrandNavy") ?? .systemIndigo
      let dark = traitCollection.userInterfaceStyle == .dark
      if dark {
        image.image = UIImage(
          systemName: "mappin.circle.fill",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .bold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [navy, .white])))
        centerOffset = .zero
      } else {
        image.image = UIImage(
          systemName: "mappin", withConfiguration: UIImage.SymbolConfiguration(pointSize: 36, weight: .bold))
        image.tintColor = navy
        // The symbol's tip, not its middle, marks the spot.
        centerOffset = CGVector(dx: 0, dy: -18)
      }
      image.layer.shadowColor = UIColor.black.cgColor
      image.layer.shadowOffset = .zero
      image.layer.shadowRadius = 2
      image.layer.shadowOpacity = dark ? 1 : 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setDragState(_ dragState: MLNAnnotationViewDragState, animated: Bool) {
      super.setDragState(dragState, animated: animated)
      if dragState == .ending, let coordinate = annotation?.coordinate { dropped?(coordinate) }
    }
  }

  @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
    var picked: (CLLocationCoordinate2D) -> Void
    var located: (CLLocationCoordinate2D) -> Void
    var mapped: CLLocationCoordinate2D?
    var interactive = true
    private var pin: NewSpot?

    init(picked: @escaping (CLLocationCoordinate2D) -> Void, located: @escaping (CLLocationCoordinate2D) -> Void) {
      self.picked = picked
      self.located = located
    }

    @objc func tapped(_ gesture: UITapGestureRecognizer) {
      guard let map = gesture.view as? MLNMapView else { return }
      picked(map.convert(gesture.location(in: map), toCoordinateFrom: map))
    }

    func show(_ spot: CLLocationCoordinate2D?, on map: MLNMapView) {
      if let spot {
        if let pin {
          if pin.coordinate.latitude != spot.latitude || pin.coordinate.longitude != spot.longitude {
            pin.coordinate = spot
          }
        } else {
          let pin = NewSpot()
          pin.coordinate = spot
          map.addAnnotation(pin)
          self.pin = pin
        }
      } else if let pin {
        map.removeAnnotation(pin)
        self.pin = nil
      }
      drawLine(on: map)
    }

    private var framed = false

    /// The fixed map: both points in view, once the map has a size.
    func frameBoth(on map: MLNMapView) {
      guard !framed, map.bounds.width > 0, let mapped, let spot = pin?.coordinate else { return }
      framed = true
      // Room for the pin above its tip and the label under the marker.
      let bounds = MLNCoordinateBounds(
        sw: CLLocationCoordinate2D(
          latitude: min(mapped.latitude, spot.latitude), longitude: min(mapped.longitude, spot.longitude)),
        ne: CLLocationCoordinate2D(
          latitude: max(mapped.latitude, spot.latitude), longitude: max(mapped.longitude, spot.longitude)))
      map.setVisibleCoordinateBounds(
        bounds, edgePadding: UIEdgeInsets(top: 50, left: 40, bottom: 30, right: 40), animated: false,
        completionHandler: nil)
      if map.zoomLevel > 18 { map.setCenter(map.centerCoordinate, zoomLevel: 18, animated: false) }
    }

    private func drawLine(on map: MLNMapView) {
      guard let style = map.style, let mapped else { return }
      TaskMapView.Coordinator.drawLines(pin.map { [[mapped, $0.coordinate]] } ?? [], in: style, dark: MapStyle.isDark(map))
    }

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
      if MapStyle.isDark(mapView) { MapStyle.brightenLabels(in: style) }
      for layer in style.layers {
        if let buildings = layer as? MLNFillExtrusionStyleLayer { buildings.isVisible = false }
      }
      drawLine(on: mapView)
      if !interactive { frameBoth(on: mapView) }
    }

    func mapView(_ mapView: MLNMapView, viewFor annotation: any MLNAnnotation) -> MLNAnnotationView? {
      if annotation is MappedSpot {
        return mapView.dequeueReusableAnnotationView(withIdentifier: MappedSpotView.reuseID)
          ?? MappedSpotView(reuseID: MappedSpotView.reuseID)
      }
      guard annotation is NewSpot else { return nil }
      let view =
        mapView.dequeueReusableAnnotationView(withIdentifier: NewSpotView.reuseID) as? NewSpotView
        ?? NewSpotView(reuseID: NewSpotView.reuseID)
      view.isDraggable = interactive
      view.dropped = { [weak self] coordinate in self?.picked(coordinate) }
      return view
    }

    func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: any MLNAnnotation) -> Bool { false }

    /// Live fixes from the map's puck, when they're good enough to stand in for the place.
    func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
      guard let location = userLocation?.location, location.horizontalAccuracy >= 0,
        location.horizontalAccuracy <= MovedSpotView.goodFix
      else { return }
      located(location.coordinate)
    }
  }
}
