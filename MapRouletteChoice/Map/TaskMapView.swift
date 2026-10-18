@preconcurrency import MapLibre
import CoreLocation
import MapRoulette
import SwiftUI
import os

/// A MapLibre map (OpenFreeMap style by default) of a campaign's places, with the brand pins
/// (brand/pins): to check, checked, and saved but not on the map yet (`pending`, a guest's
/// answers), each a different shape. Tapping a pin shows its name; tapping the callout opens it.
/// With VoiceOver, activating a pin to check opens it directly. Pins are added nearest to
/// `origin` first (else north to south), which is the order VoiceOver reads them.
/// `done` marks finished tasks; `interactive` false gives a fixed preview map. A place someone
/// reported (design/not-here-moved.md §4) reads "Needs another look"; a moved one also gets a small
/// gray dot at the reported spot, joined to its pin by a dashed line.
struct TaskMapView: UIViewRepresentable {
  let styleURL: URL
  let tasks: [LocatedTask]
  var done: Set<Int64> = []
  /// Of `done`: saved for later (guest), not on the map yet.
  var pending: Set<Int64> = []
  /// A guest's answers kept on this phone until there's signal (O1).
  var waiting: Set<Int64> = []
  /// Reported as not here or moved.
  var reports: [Int64: TaskReport] = [:]
  /// Closed here with another status-6 outcome: "Needs another look", with no dot.
  var flagged: Set<Int64> = []
  /// The user's location, for the VoiceOver reading order.
  var origin: CLLocationCoordinate2D?
  var noun = Noun.place
  var interactive = true
  /// Counts the times the questions for a place closed: each new value sends VoiceOver back to
  /// the place that was opened (A11y1).
  var returns = 0
  let open: (Int64) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(open: open) }

  func makeUIView(context: Context) -> MLNMapView {
    let style = MapStyle.url(styleURL, for: context.environment.colorScheme)
    let map = interactive ? PinOrderMapView(frame: .zero, styleURL: style) : QuietMapView(frame: .zero, styleURL: style)
    map.delegate = context.coordinator
    context.coordinator.returns = returns
    // Turning this on makes MapLibre ask for location itself, so wait until the app has asked.
    map.showsUserLocation = Self.locationAllowed
    map.compassViewPosition = .topRight
    // The system blue puck: the brand tint would make "you" look like another stop.
    map.tintColor = .systemBlue
    if interactive {
      map.accessibilityIdentifier = "TaskMap"
      map.accessibilityHint = "Each pin is a place. The List view has the same places, nearest first."
    } else {
      // The preview's street names are drawn into the tiles; the SwiftUI side labels the map instead.
      // QuietMapView also drops MapLibre's own elements (pin, puck, compass, attribution).
      map.accessibilityElementsHidden = true
    }
    map.isUserInteractionEnabled = interactive
    if let ordered = map as? PinOrderMapView {
      ordered.clusters = context.coordinator.clusters
      // Taps on cluster and pin layers; MapLibre's own double tap (zoom) goes first.
      let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
      for case let other as UITapGestureRecognizer in map.gestureRecognizers ?? [] where other.numberOfTapsRequired == 2 {
        tap.require(toFail: other)
      }
      tap.delegate = context.coordinator
      map.addGestureRecognizer(tap)
      if AXProbe.isOn {
        AXProbe.shared.activate = { [weak ordered, weak clusters = context.coordinator.clusters] kind in
          guard let ordered, let clusters else { return nil }
          return clusters.activateFirst(kind, in: ordered, limit: PinOrderMapView.spokenPins)
        }
      }
    }
    // Salt Lake City until tasks load.
    map.setCenter(CLLocationCoordinate2D(latitude: 40.7608, longitude: -111.8910), zoomLevel: 11, animated: false)
    return map
  }

  func updateUIView(_ map: MLNMapView, context: Context) {
    context.coordinator.open = open
    if returns != context.coordinator.returns {
      context.coordinator.returns = returns
      (map as? PinOrderMapView)?.focusReturnedPlace()
    }
    // Pins are annotations, so they survive the style swap when the appearance changes.
    let style = MapStyle.url(styleURL, for: context.environment.colorScheme)
    if map.styleURL != style { map.styleURL = style }
    if map.showsUserLocation != Self.locationAllowed { map.showsUserLocation = Self.locationAllowed }
    context.coordinator.show(
      tasks, done: done, pending: pending, waiting: waiting, reports: reports, flagged: flagged, origin: origin,
      noun: noun,
      on: map)
  }

  private static var locationAllowed: Bool {
    switch CLLocationManager().authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: true
    default: false
    }
  }

  /// A pin's state: its image and what VoiceOver reads for it. Places that no longer need
  /// checking are not on the map, so there is no stale pin.
  enum Pin: Equatable {
    case toCheck, done, pending
    /// Answered as a guest, kept on this phone until there's signal (offline-copy.md).
    case waiting
    /// Open, but someone reported it not here or moved. It can still be opened.
    case reported

    /// `pending` only counts for a done place, `reported` only for an open one.
    init(done: Bool, pending: Bool, reported: Bool = false, waiting: Bool = false) {
      self = done ? (pending ? .pending : .done) : waiting ? .waiting : reported ? .reported : .toCheck
    }

    var imageName: String {
      switch self {
      case .toCheck: "PinTodo"
      case .done: "PinDone"
      case .pending: "PinPending"
      case .waiting: "PinWaiting"
      case .reported: "PinLook"
      }
    }

    /// The state, as VoiceOver's value.
    var accessibilityValue: String {
      switch self {
      case .toCheck: "To check"
      case .done: "Already checked"
      case .pending: "Saved, not on the map yet"
      case .waiting: Wording.waitingToSend
      case .reported: Wording.needsAnotherLook
      }
    }

    /// Places to check and reported ones open.
    var opens: Bool { self == .toCheck || self == .reported }

    /// What activating the pin does.
    var accessibilityHint: String? { opens ? "Opens the questions" : nil }

    /// The callout's second line, for sighted users.
    var calloutSubtitle: String { self == .toCheck ? "Tap to answer" : accessibilityValue }
  }

  /// Where someone reported a moved place to be: a small gray dot, not a VoiceOver element (the
  /// place's pin says it needs another look).
  final class ReportedSpot: MLNPointAnnotation {}

  final class ReportedSpotView: MLNAnnotationView {
    static let reuseID = "reported"

    init(reuseID: String) {
      super.init(annotation: nil, reuseIdentifier: reuseID)
      frame = CGRect(x: 0, y: 0, width: 12, height: 12)
      scalesWithViewingDistance = false
      backgroundColor = .systemGray
      layer.cornerRadius = 6
      layer.borderWidth = 2
      layer.borderColor = UIColor.white.cgColor
      isAccessibilityElement = false
      accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
  }

  final class TaskAnnotation: MLNPointAnnotation {
    var taskID: Int64 = 0
    var pin = Pin.toCheck
    /// "130 m northeast", as the list row reads it; nil without a location.
    var distance: String?
    /// Place in VoiceOver's reading order: 0 is nearest.
    var rank = 0
  }

  /// A brand pin drawn at its own size (28 pt) in the middle of a 44 pt frame, so the touch
  /// target and VoiceOver frame are 44 pt without a bigger pin.
  final class PinView: MLNAnnotationView {
    static let reuseID = "pin"
    static let side: CGFloat = 44

    private let imageView = UIImageView()
    private var task: TaskAnnotation? { annotation as? TaskAnnotation }
    /// From the annotation, which a refresh updates without replacing the pin.
    var rank: Int { task?.rank ?? .max }
    private var pin: Pin { task?.pin ?? .toCheck }
    /// Opens the place; nil for pins that don't open.
    private var onActivate: (() -> Void)?

    init(reuseID: String) {
      super.init(annotation: nil, reuseIdentifier: reuseID)
      frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
      // Flat like the old annotation images: no scaling when the map is pitched.
      scalesWithViewingDistance = false
      imageView.frame = bounds
      imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      imageView.contentMode = .center
      imageView.haloInDarkMode()
      addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ task: TaskAnnotation, onActivate: (() -> Void)?) {
      annotation = task
      imageView.image = UIImage(named: task.pin.imageName)
      self.onActivate = onActivate
    }

    /// Name and distance, as the list row reads them.
    override var accessibilityLabel: String? {
      get { [task?.title, task?.distance].compactMap { $0 }.joined(separator: ", ") }
      set {}
    }

    override var accessibilityValue: String? {
      get { pin.accessibilityValue }
      set {}
    }

    override var accessibilityHint: String? {
      get { pin.accessibilityHint }
      set {}
    }

    /// MapLibre reports annotation views' frames in map coordinates; VoiceOver needs screen ones.
    override var accessibilityFrame: CGRect {
      get { UIAccessibility.convertToScreenCoordinates(bounds, in: self) }
      set {}
    }

    /// VoiceOver's double tap opens the place instead of showing the callout.
    override func accessibilityActivate() -> Bool {
      guard let onActivate else { return false }
      onActivate()
      return true
    }
  }

  @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate, UIGestureRecognizerDelegate {
    var open: (Int64) -> Void
    var returns = 0
    /// Campaigns over 500 places, drawn as clusters instead of `pins`.
    private(set) lazy var clusters = ClusteredPins(
      open: { [weak self] id in self?.open(id) }, select: { [weak self] place in self?.showCallout(place) })
    /// A clustered campaign's tapped pin: an annotation over it, for the callout.
    private var calloutPin: TaskAnnotation?
    private weak var map: MLNMapView?
    private var shown: [Int64] = []
    private var shownDone: Set<Int64> = []
    private var shownPending: Set<Int64> = []
    private var shownWaiting: Set<Int64> = []
    private var shownReports: [Int64: TaskReport] = [:]
    private var shownFlagged: Set<Int64> = []
    /// Pin to reported spot, for each moved place; drawn once the style has loaded.
    private var reportLines: [[CLLocationCoordinate2D]] = []
    private var shownOrigin: CLLocationCoordinate2D?
    /// The pins on the map, by task id.
    private var pins: [Int64: TaskAnnotation] = [:]
    private var fitted = false

    init(open: @escaping (Int64) -> Void) { self.open = open }

    func show(
      _ tasks: [LocatedTask], done: Set<Int64>, pending: Set<Int64>, waiting: Set<Int64>, reports: [Int64: TaskReport],
      flagged: Set<Int64>, origin: CLLocationCoordinate2D?, noun: Noun, on map: MLNMapView
    ) {
      let began = ContinuousClock.now
      let ids = tasks.map(\.id)
      let moved = origin?.latitude != shownOrigin?.latitude || origin?.longitude != shownOrigin?.longitude
      guard ids != shown || done != shownDone || pending != shownPending || waiting != shownWaiting || reports != shownReports || flagged != shownFlagged || moved
      else { return }
      let refit = ids != shown && !fitted
      shown = ids
      shownDone = done
      shownPending = pending
      shownWaiting = waiting
      shownReports = reports
      shownFlagged = flagged
      shownOrigin = origin
      if let old = map.annotations?.filter({ $0 is ReportedSpot }), !old.isEmpty {
        map.removeAnnotations(old)
      }
      showReportedSpots(tasks, done: done, reports: reports, on: map)
      self.map = map
      if tasks.count > ClusteredPins.threshold {
        showClustered(
          tasks, done: done, pending: pending, waiting: waiting, reports: reports, flagged: flagged, origin: origin,
          noun: noun, refit: refit, began: began, on: map)
        return
      }
      if clusters.isActive { clusters.remove(from: map) }
      // Only pins that are new or changed are added again: a big campaign arrives a page at a time,
      // and replacing every pin for each page made each page cost more than the last (Tess, AB13).
      // Rank and distance change in place; PinView reads them from its annotation.
      let from = origin ?? map.userLocation?.location?.coordinate
      var keep: [Int64: TaskAnnotation] = [:]
      var added: [TaskAnnotation] = []
      let annotations: [TaskAnnotation] = TaskLocation.mapOrder(tasks, from: from).enumerated().compactMap { rank, task in
        guard let coordinate = task.coordinate else { return nil }
        let pin = Pin(
          done: done.contains(task.id), pending: pending.contains(task.id),
          reported: reports[task.id] != nil || flagged.contains(task.id), waiting: waiting.contains(task.id))
        let title = Wording.placeName(task.task, noun)
        let a: TaskAnnotation
        if let old = pins[task.id], old.pin == pin, old.title == title,
          old.coordinate.latitude == coordinate.latitude, old.coordinate.longitude == coordinate.longitude
        {
          a = old
        } else {
          a = TaskAnnotation()
          a.taskID = task.id
          a.pin = pin
          a.coordinate = coordinate
          a.title = title
          a.subtitle = pin.calloutSubtitle
          added.append(a)
        }
        // VoiceOver reads pins nearest first (PinOrderMapView).
        a.rank = rank
        a.distance = TaskLocation.directionText(from, coordinate)
        keep[task.id] = a
        return a
      }
      let gone = pins.values.filter { keep[$0.taskID] !== $0 }
      if !gone.isEmpty { map.removeAnnotations(gone) }
      pins = keep
      if !added.isEmpty { map.addAnnotations(added) }
      LoadLog.log.debug(
        "pins: \(annotations.count) on the map (+\(added.count) -\(gone.count)) in \(began.duration(to: .now), privacy: .public) at \(LoadLog.elapsed, privacy: .public)"
      )
      guard !annotations.isEmpty else { return }
      // Fit once; later refreshes (a task marked done) keep the user's view.
      guard refit else { return }
      fitted = true
      if annotations.count == 1 {
        // 16 keeps at least one named street in a small header (MapLibre zooms run a level closer).
        map.setCenter(annotations[0].coordinate, zoomLevel: 16, animated: false)
      } else {
        map.showAnnotations(annotations, animated: true)
      }
    }

    /// A big campaign: one clustered source instead of an annotation view per place, and no
    /// per-pin rank or distance (VoiceOver's elements work them out for what's on screen).
    private func showClustered(
      _ tasks: [LocatedTask], done: Set<Int64>, pending: Set<Int64>, waiting: Set<Int64>,
      reports: [Int64: TaskReport], flagged: Set<Int64>, origin: CLLocationCoordinate2D?, noun: Noun, refit: Bool,
      began: ContinuousClock.Instant, on map: MLNMapView
    ) {
      if !pins.isEmpty {
        map.removeAnnotations(Array(pins.values))
        pins = [:]
      }
      clusters.noun = noun
      clusters.origin = origin
      var south = 90.0, north = -90.0, west = 180.0, east = -180.0
      let places = tasks.compactMap { task -> ClusteredPins.Place? in
        guard let c = task.coordinate else { return nil }
        south = min(south, c.latitude)
        north = max(north, c.latitude)
        west = min(west, c.longitude)
        east = max(east, c.longitude)
        let pin = Pin(
          done: done.contains(task.id), pending: pending.contains(task.id),
          reported: reports[task.id] != nil || flagged.contains(task.id), waiting: waiting.contains(task.id))
        return ClusteredPins.Place(task: task, coordinate: c, pin: pin)
      }
      clusters.show(places, on: map)
      LoadLog.log.debug(
        "clusters: \(places.count) places in \(began.duration(to: .now), privacy: .public) at \(LoadLog.elapsed, privacy: .public)"
      )
      guard refit, !places.isEmpty else { return }
      fitted = true
      let bounds = MLNCoordinateBounds(
        sw: CLLocationCoordinate2D(latitude: south, longitude: west),
        ne: CLLocationCoordinate2D(latitude: north, longitude: east))
      map.setVisibleCoordinateBounds(
        bounds, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true,
        completionHandler: nil)
    }

    /// A clustered pin's callout, as an unclustered pin shows it: an annotation over the pin.
    private func showCallout(_ place: ClusteredPins.Place) {
      guard let map else { return }
      if let old = calloutPin { map.removeAnnotation(old) }
      let a = TaskAnnotation()
      a.taskID = place.id
      a.pin = place.pin
      a.coordinate = place.coordinate
      a.title = Wording.placeName(place.task.task, clusters.noun)
      a.subtitle = place.pin.calloutSubtitle
      calloutPin = a
      map.addAnnotation(a)
      map.selectAnnotation(a, animated: false, completionHandler: nil)
    }

    @objc func tapped(_ tap: UITapGestureRecognizer) {
      guard clusters.isActive, tap.state == .ended, let map = tap.view as? MLNMapView else { return }
      let point = tap.location(in: map)
      // After MapLibre's own tap, which deselects whatever was selected.
      Task { @MainActor [weak self] in self?.clusters.tap(at: point, on: map) }
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    func mapView(_ mapView: MLNMapView, didDeselect annotation: any MLNAnnotation) {
      guard let calloutPin, annotation === calloutPin else { return }
      mapView.removeAnnotation(calloutPin)
      self.calloutPin = nil
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
      clusters.invalidate()
      if AXProbe.isOn { AXProbe.shared.zoom = mapView.zoomLevel }
      // A VoiceOver zoom into a cluster: the cluster is gone, so focus the nearest of what is shown.
      if let next = clusters.focusAfterMove(in: mapView, limit: PinOrderMapView.spokenPins) {
        AXProbe.post(.layoutChanged, next)
      }
    }

    /// The zoomed-in clusters and pins weren't drawn yet when the region changed.
    func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
      if let next = clusters.focusAfterMove(in: mapView, limit: PinOrderMapView.spokenPins) {
        AXProbe.post(.layoutChanged, next)
      }
    }

    /// A dot and a dashed line for each open place reported as moved. Added before the pins, so
    /// they sit underneath.
    private func showReportedSpots(
      _ tasks: [LocatedTask], done: Set<Int64>, reports: [Int64: TaskReport], on map: MLNMapView
    ) {
      var spots: [ReportedSpot] = []
      reportLines = []
      for task in tasks where !done.contains(task.id) {
        guard let from = task.coordinate, case .moved(let lat, let lon)? = reports[task.id] else { continue }
        let spot = ReportedSpot()
        spot.coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        spots.append(spot)
        reportLines.append([from, spot.coordinate])
      }
      if !spots.isEmpty { map.addAnnotations(spots) }
      if let style = map.style { Self.drawLines(reportLines, in: style, dark: MapStyle.isDark(map)) }
    }

    static let reportLinesID = "reported-lines"

    /// One dashed gray line per pair, in a shape source the delegate refreshes.
    /// Light grey on the dark map (which-one-spec.md, "Dark map" 1).
    static func drawLines(_ lines: [[CLLocationCoordinate2D]], in style: MLNStyle, dark: Bool) {
      let shapes = lines.map { points in
        var points = points
        return MLNPolylineFeature(coordinates: &points, count: UInt(points.count))
      }
      let collection = MLNShapeCollectionFeature(shapes: shapes)
      if let source = style.source(withIdentifier: reportLinesID) as? MLNShapeSource {
        source.shape = collection
        return
      }
      let source = MLNShapeSource(identifier: reportLinesID, shape: collection, options: nil)
      style.addSource(source)
      let line = MLNLineStyleLayer(identifier: reportLinesID, source: source)
      line.lineColor = NSExpression(forConstantValue: dark ? UIColor(white: 0.8, alpha: 1) : UIColor.systemGray)
      line.lineWidth = NSExpression(forConstantValue: 2)
      line.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
      style.addLayer(line)
    }

    /// Symbol layers from these OpenMapTiles source layers (shops, bus stops, stations, airports)
    /// look tappable and compete with campaign pins, so they are hidden.
    static let hiddenSymbolSources: Set<String> = ["poi", "aerodrome_label"]

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
      if MapStyle.isDark(mapView) { MapStyle.brightenLabels(in: style) }
      for layer in style.layers {
        // Flat buildings: 3D extrusions clutter the small header map.
        if let buildings = layer as? MLNFillExtrusionStyleLayer {
          buildings.isVisible = false
          continue
        }
        if let symbols = layer as? MLNSymbolStyleLayer, let source = symbols.sourceLayerIdentifier,
          Self.hiddenSymbolSources.contains(source)
        {
          symbols.isVisible = false
        }
      }
      Self.drawLines(reportLines, in: style, dark: MapStyle.isDark(mapView))
      clusters.restyle(style, dark: MapStyle.isDark(mapView))
    }

    /// Pins are views rather than annotation images, for a 44 pt touch target and their own
    /// VoiceOver value. The user location (not a TaskAnnotation) keeps MapLibre's puck.
    func mapView(_ mapView: MLNMapView, viewFor annotation: any MLNAnnotation) -> MLNAnnotationView? {
      if annotation is ReportedSpot {
        return mapView.dequeueReusableAnnotationView(withIdentifier: ReportedSpotView.reuseID)
          ?? ReportedSpotView(reuseID: ReportedSpotView.reuseID)
      }
      guard let task = annotation as? TaskAnnotation else { return nil }
      let view =
        mapView.dequeueReusableAnnotationView(withIdentifier: PinView.reuseID) as? PinView
        ?? PinView(reuseID: PinView.reuseID)
      let id = task.taskID
      view.configure(task, onActivate: task.pin.opens ? { [weak self] in self?.open(id) } : nil)
      return view
    }

    static let youAreHere = "You are here"

    /// MapLibre reads the puck as its title plus the coordinates in degrees and minutes when
    /// there is no subtitle; an empty subtitle leaves just "You are here".
    func mapView(_ mapView: MLNMapView, didUpdate userLocation: MLNUserLocation?) {
      guard let userLocation, userLocation.title != Self.youAreHere else { return }
      userLocation.title = Self.youAreHere
      userLocation.subtitle = ""
    }

    func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: any MLNAnnotation) -> Bool {
      annotation is TaskAnnotation
    }

    func mapView(_ mapView: MLNMapView, tapOnCalloutFor annotation: any MLNAnnotation) {
      guard let task = annotation as? TaskAnnotation else { return }
      openIfToCheck(task, on: mapView)
    }

    /// The callout is hard to reach with VoiceOver, so with VoiceOver on, selecting a pin to check
    /// opens it directly. A backstop: PinView's accessibilityActivate usually opens it first.
    func mapView(_ mapView: MLNMapView, didSelect annotation: any MLNAnnotation) {
      guard UIAccessibility.isVoiceOverRunning, let task = annotation as? TaskAnnotation else { return }
      openIfToCheck(task, on: mapView)
    }

    private func openIfToCheck(_ task: TaskAnnotation, on mapView: MLNMapView) {
      guard task.pin.opens else { return }
      mapView.deselectAnnotation(task, animated: false)
      open(task.taskID)
    }
  }
}

/// The campaign map. MapLibre lists visible pins to VoiceOver nearest the middle of the map first;
/// this lists them nearest the person first (`TaskAnnotation.rank`), like the List, then the rest
/// (puck, compass, attribution) as MapLibre has them (Tess, #50). At most the nearest 200 pins are
/// listed (Android parity, AE6).
/// A clustered campaign lists its visible clusters and pins instead (`ClusteredPins`), also at most 200.
private final class PinOrderMapView: MLNMapView {
  static let spokenPins = 200
  weak var clusters: ClusteredPins?
  private var cached: [Any] = []
  private var cachedAt = Date.distantPast

  /// VoiceOver asks for every index in turn, so the order is kept briefly rather than rebuilt for
  /// each; a pan or new pins change MapLibre's count, which rebuilds it.
  private func ordered() -> [Any] {
    let count = super.accessibilityElementCount()
    if let clusters, clusters.isActive {
      // MapLibre's own elements here are the puck, compass and attribution (and a callout pin).
      var rest: [Any] = []
      for i in 0..<count {
        if let element = super.accessibilityElement(at: i), !(element is TaskMapView.PinView) { rest.append(element) }
      }
      return clusters.accessibilityElements(in: self, limit: Self.spokenPins) + rest
    }
    if count == cached.count, Date().timeIntervalSince(cachedAt) < 0.5 { return cached }
    var pins: [TaskMapView.PinView] = []
    var rest: [Any] = []
    for i in 0..<count {
      guard let element = super.accessibilityElement(at: i) else { continue }
      if let pin = element as? TaskMapView.PinView { pins.append(pin) } else { rest.append(element) }
    }
    // Thousands of pins on screen are unusable by swiping and slow to list: the nearest 200 only.
    cached = Array(pins.sorted { $0.rank < $1.rank }.prefix(Self.spokenPins)) + rest
    cachedAt = Date()
    return cached
  }

  /// The questions for a place opened from here closed: VoiceOver goes to that place again, not
  /// to Back (A11y1). A layout change, posted once the pop has ended, after the navigation's own
  /// screen change (which would otherwise win); a pop with no transition to wait for (or one
  /// already over) gets a short delay instead.
  func focusReturnedPlace() {
    guard let clusters, clusters.isActive else { return }
    let focus = { [weak self] in
      guard let self, self.window != nil, let target = clusters.returnFocus(in: self, limit: Self.spokenPins)
      else { return }
      AXProbe.post(.layoutChanged, target)
    }
    var responder: UIResponder? = self
    while let next = responder?.next, !(next is UIViewController) { responder = next }
    if let transition = (responder?.next as? UIViewController)?.navigationController?.transitionCoordinator {
      transition.animate(alongsideTransition: nil) { context in
        guard !context.isCancelled else { return }
        DispatchQueue.main.async(execute: focus)
      }
    } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: focus)
    }
  }

  override func accessibilityElementCount() -> Int { ordered().count }
  override func accessibilityElement(at index: Int) -> Any? {
    let all = ordered()
    return all.indices.contains(index) ? all[index] : nil
  }
  override func index(ofAccessibilityElement element: Any) -> Int {
    ordered().firstIndex { ($0 as AnyObject) === (element as AnyObject) } ?? NSNotFound
  }
}

/// The non-interactive header map: MapLibre lists its pins, puck, compass and attribution through
/// its own accessibility container methods, which `accessibilityElementsHidden` doesn't stop.
private final class QuietMapView: MLNMapView {
  override func accessibilityElementCount() -> Int { 0 }
  override func accessibilityElement(at index: Int) -> Any? { nil }
  override func index(ofAccessibilityElement element: Any) -> Int { NSNotFound }
}
