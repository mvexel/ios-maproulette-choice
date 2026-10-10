@preconcurrency import MapLibre
import SwiftUI

/// A MapLibre map (OpenFreeMap style by default) of a challenge's tasks. Tapping a marker shows
/// its name; tapping the callout opens the task.
struct TaskMapView: UIViewRepresentable {
  let styleURL: URL
  let tasks: [LocatedTask]
  let open: (Int64) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(open: open) }

  func makeUIView(context: Context) -> MLNMapView {
    let map = MLNMapView(frame: .zero, styleURL: styleURL)
    map.delegate = context.coordinator
    map.showsUserLocation = true
    map.compassViewPosition = .topRight
    // Salt Lake City until tasks load.
    map.setCenter(CLLocationCoordinate2D(latitude: 40.7608, longitude: -111.8910), zoomLevel: 11, animated: false)
    return map
  }

  func updateUIView(_ map: MLNMapView, context: Context) {
    context.coordinator.open = open
    context.coordinator.show(tasks, on: map)
  }

  final class TaskAnnotation: MLNPointAnnotation {
    var taskID: Int64 = 0
  }

  @MainActor final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
    var open: (Int64) -> Void
    private var shown: [Int64] = []

    init(open: @escaping (Int64) -> Void) { self.open = open }

    func show(_ tasks: [LocatedTask], on map: MLNMapView) {
      let ids = tasks.map(\.id)
      guard ids != shown else { return }
      shown = ids
      if let old = map.annotations?.filter({ $0 is TaskAnnotation }), !old.isEmpty {
        map.removeAnnotations(old)
      }
      let annotations: [TaskAnnotation] = tasks.compactMap { task in
        guard let coordinate = task.coordinate else { return nil }
        let a = TaskAnnotation()
        a.taskID = task.id
        a.coordinate = coordinate
        a.title = task.task.name
        a.subtitle = "Task \(task.id) · tap to answer"
        return a
      }
      guard !annotations.isEmpty else { return }
      map.addAnnotations(annotations)
      if annotations.count == 1 {
        map.setCenter(annotations[0].coordinate, zoomLevel: 16, animated: true)
      } else {
        map.showAnnotations(annotations, animated: true)
      }
    }

    func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: any MLNAnnotation) -> Bool {
      annotation is TaskAnnotation
    }

    func mapView(_ mapView: MLNMapView, tapOnCalloutFor annotation: any MLNAnnotation) {
      guard let task = annotation as? TaskAnnotation else { return }
      mapView.deselectAnnotation(task, animated: false)
      open(task.taskID)
    }
  }
}
