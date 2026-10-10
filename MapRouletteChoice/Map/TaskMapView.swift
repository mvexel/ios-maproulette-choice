@preconcurrency import MapLibre
import CoreLocation
import SwiftUI

/// A MapLibre map (OpenFreeMap style by default) of a campaign's places, with the brand pins
/// (brand/pins): to check, checked, and saved but not on the map yet (`pending`, a guest's
/// answers), each a different shape. Tapping a pin shows its name; tapping the callout opens it.
/// `done` marks finished tasks; `interactive` false gives a fixed preview map.
struct TaskMapView: UIViewRepresentable {
  let styleURL: URL
  let tasks: [LocatedTask]
  var done: Set<Int64> = []
  /// Of `done`: saved for later (guest), not on the map yet.
  var pending: Set<Int64> = []
  var noun = Noun.place
  var interactive = true
  let open: (Int64) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(open: open) }

  func makeUIView(context: Context) -> MLNMapView {
    let map = MLNMapView(frame: .zero, styleURL: styleURL)
    map.delegate = context.coordinator
    // Turning this on makes MapLibre ask for location itself, so wait until the app has asked.
    map.showsUserLocation = Self.locationAllowed
    map.compassViewPosition = .topRight
    map.isUserInteractionEnabled = interactive
    // Salt Lake City until tasks load.
    map.setCenter(CLLocationCoordinate2D(latitude: 40.7608, longitude: -111.8910), zoomLevel: 11, animated: false)
    return map
  }

  func updateUIView(_ map: MLNMapView, context: Context) {
    context.coordinator.open = open
    if map.showsUserLocation != Self.locationAllowed { map.showsUserLocation = Self.locationAllowed }
    context.coordinator.show(tasks, done: done, pending: pending, noun: noun, on: map)
  }

  private static var locationAllowed: Bool {
    switch CLLocationManager().authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways: true
    default: false
    }
  }

  final class TaskAnnotation: MLNPointAnnotation {
    var taskID: Int64 = 0
    var done = false
    var pending = false
  }

  @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
    var open: (Int64) -> Void
    private var shown: [Int64] = []
    private var shownDone: Set<Int64> = []
    private var shownPending: Set<Int64> = []
    private var fitted = false

    init(open: @escaping (Int64) -> Void) { self.open = open }

    func show(_ tasks: [LocatedTask], done: Set<Int64>, pending: Set<Int64>, noun: Noun, on map: MLNMapView) {
      let ids = tasks.map(\.id)
      guard ids != shown || done != shownDone || pending != shownPending else { return }
      let refit = ids != shown && !fitted
      shown = ids
      shownDone = done
      shownPending = pending
      if let old = map.annotations?.filter({ $0 is TaskAnnotation }), !old.isEmpty {
        map.removeAnnotations(old)
      }
      let annotations: [TaskAnnotation] = tasks.compactMap { task in
        guard let coordinate = task.coordinate else { return nil }
        let a = TaskAnnotation()
        a.taskID = task.id
        a.done = done.contains(task.id)
        a.pending = a.done && pending.contains(task.id)
        a.coordinate = coordinate
        a.title = Wording.placeName(task.task, noun)
        a.subtitle = a.pending ? "Saved, not on the map yet" : a.done ? "Already checked" : "Tap to answer"
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
        if let symbols = layer as? MLNSymbolStyleLayer, let source = symbols.sourceLayerIdentifier,
          Self.hiddenSymbolSources.contains(source)
        {
          symbols.isVisible = false
        }
      }
    }

    func mapView(_ mapView: MLNMapView, imageFor annotation: any MLNAnnotation) -> MLNAnnotationImage? {
      guard let task = annotation as? TaskAnnotation else { return nil }
      let name = task.pending ? "PinPending" : task.done ? "PinDone" : "PinTodo"
      if let image = mapView.dequeueReusableAnnotationImage(withIdentifier: name) { return image }
      return UIImage(named: name).map { MLNAnnotationImage(image: $0, reuseIdentifier: name) }
    }

    func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: any MLNAnnotation) -> Bool {
      annotation is TaskAnnotation
    }

    func mapView(_ mapView: MLNMapView, tapOnCalloutFor annotation: any MLNAnnotation) {
      guard let task = annotation as? TaskAnnotation, !task.done else { return }
      mapView.deselectAnnotation(task, animated: false)
      open(task.taskID)
    }
  }
}
