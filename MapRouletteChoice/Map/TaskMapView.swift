@preconcurrency import MapLibre
import CoreLocation
import SwiftUI

/// A MapLibre map (OpenFreeMap style by default) of a campaign's places, with the brand pins
/// (brand/pins): to check, checked, and saved but not on the map yet (`pending`, a guest's
/// answers), each a different shape. Tapping a pin shows its name; tapping the callout opens it.
/// With VoiceOver, activating a pin to check opens it directly. Pins are added nearest to
/// `origin` first (else north to south), which is the order VoiceOver reads them.
/// `done` marks finished tasks; `interactive` false gives a fixed preview map.
struct TaskMapView: UIViewRepresentable {
  let styleURL: URL
  let tasks: [LocatedTask]
  var done: Set<Int64> = []
  /// Of `done`: saved for later (guest), not on the map yet.
  var pending: Set<Int64> = []
  /// The user's location, for the VoiceOver reading order.
  var origin: CLLocationCoordinate2D?
  var noun = Noun.place
  var interactive = true
  let open: (Int64) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(open: open) }

  func makeUIView(context: Context) -> MLNMapView {
    let map = interactive ? MLNMapView(frame: .zero, styleURL: styleURL) : QuietMapView(frame: .zero, styleURL: styleURL)
    map.delegate = context.coordinator
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
    // Salt Lake City until tasks load.
    map.setCenter(CLLocationCoordinate2D(latitude: 40.7608, longitude: -111.8910), zoomLevel: 11, animated: false)
    return map
  }

  func updateUIView(_ map: MLNMapView, context: Context) {
    context.coordinator.open = open
    if map.showsUserLocation != Self.locationAllowed { map.showsUserLocation = Self.locationAllowed }
    context.coordinator.show(tasks, done: done, pending: pending, origin: origin, noun: noun, on: map)
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

    /// `pending` only counts for a done place.
    init(done: Bool, pending: Bool) {
      self = done ? (pending ? .pending : .done) : .toCheck
    }

    var imageName: String {
      switch self {
      case .toCheck: "PinTodo"
      case .done: "PinDone"
      case .pending: "PinPending"
      }
    }

    /// The state, as VoiceOver's value.
    var accessibilityValue: String {
      switch self {
      case .toCheck: "To check"
      case .done: "Already checked"
      case .pending: "Saved, not on the map yet"
      }
    }

    /// What activating the pin does; only places to check open.
    var accessibilityHint: String? { self == .toCheck ? "Opens the questions" : nil }

    /// The callout's second line, for sighted users.
    var calloutSubtitle: String { self == .toCheck ? "Tap to answer" : accessibilityValue }
  }

  final class TaskAnnotation: MLNPointAnnotation {
    var taskID: Int64 = 0
    var pin = Pin.toCheck
  }

  /// A brand pin drawn at its own size (28 pt) in the middle of a 44 pt frame, so the touch
  /// target and VoiceOver frame are 44 pt without a bigger pin.
  final class PinView: MLNAnnotationView {
    static let reuseID = "pin"
    static let side: CGFloat = 44

    private let imageView = UIImageView()
    private var name: String?
    private var pin = Pin.toCheck
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
      addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ task: TaskAnnotation, onActivate: (() -> Void)?) {
      name = task.title
      pin = task.pin
      imageView.image = UIImage(named: task.pin.imageName)
      self.onActivate = onActivate
    }

    override var accessibilityLabel: String? {
      get { name }
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

  @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
    var open: (Int64) -> Void
    private var shown: [Int64] = []
    private var shownDone: Set<Int64> = []
    private var shownPending: Set<Int64> = []
    private var shownOrigin: CLLocationCoordinate2D?
    private var fitted = false

    init(open: @escaping (Int64) -> Void) { self.open = open }

    func show(
      _ tasks: [LocatedTask], done: Set<Int64>, pending: Set<Int64>, origin: CLLocationCoordinate2D?, noun: Noun,
      on map: MLNMapView
    ) {
      let ids = tasks.map(\.id)
      let moved = origin?.latitude != shownOrigin?.latitude || origin?.longitude != shownOrigin?.longitude
      guard ids != shown || done != shownDone || pending != shownPending || moved else { return }
      let refit = ids != shown && !fitted
      shown = ids
      shownDone = done
      shownPending = pending
      shownOrigin = origin
      if let old = map.annotations?.filter({ $0 is TaskAnnotation }), !old.isEmpty {
        map.removeAnnotations(old)
      }
      // VoiceOver reads pins in the order they are added: nearest first.
      let from = origin ?? map.userLocation?.location?.coordinate
      let annotations: [TaskAnnotation] = TaskLocation.mapOrder(tasks, from: from).compactMap { task in
        guard let coordinate = task.coordinate else { return nil }
        let a = TaskAnnotation()
        a.taskID = task.id
        a.pin = Pin(done: done.contains(task.id), pending: pending.contains(task.id))
        a.coordinate = coordinate
        a.title = Wording.placeName(task.task, noun)
        a.subtitle = a.pin.calloutSubtitle
        return a
      }
      guard !annotations.isEmpty else { return }
      map.addAnnotations(annotations)
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

    /// Symbol layers from these OpenMapTiles source layers (shops, bus stops, stations, airports)
    /// look tappable and compete with campaign pins, so they are hidden.
    static let hiddenSymbolSources: Set<String> = ["poi", "aerodrome_label"]

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
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
    }

    /// Pins are views rather than annotation images, for a 44 pt touch target and their own
    /// VoiceOver value. The user location (not a TaskAnnotation) keeps MapLibre's puck.
    func mapView(_ mapView: MLNMapView, viewFor annotation: any MLNAnnotation) -> MLNAnnotationView? {
      guard let task = annotation as? TaskAnnotation else { return nil }
      let view =
        mapView.dequeueReusableAnnotationView(withIdentifier: PinView.reuseID) as? PinView
        ?? PinView(reuseID: PinView.reuseID)
      let id = task.taskID
      view.configure(task, onActivate: task.pin == .toCheck ? { [weak self] in self?.open(id) } : nil)
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
      guard task.pin == .toCheck else { return }
      mapView.deselectAnnotation(task, animated: false)
      open(task.taskID)
    }
  }
}

/// The non-interactive header map: MapLibre lists its pins, puck, compass and attribution through
/// its own accessibility container methods, which `accessibilityElementsHidden` doesn't stop.
private final class QuietMapView: MLNMapView {
  override func accessibilityElementCount() -> Int { 0 }
  override func accessibilityElement(at index: Int) -> Any? { nil }
  override func index(ofAccessibilityElement element: Any) -> Int { NSNotFound }
}
