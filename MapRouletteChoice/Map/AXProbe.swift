import Observation
import SwiftUI
import UIKit

/// `-demoAXProbe`, for UI tests of VoiceOver on the clustered map (Tess AB17a): the simulator has
/// no VoiceOver, and XCUITest's tap doesn't call `accessibilityActivate`. A small overlay on the
/// campaign map activates the first listed cluster or place as a VoiceOver double tap does, and
/// shows the map's zoom and the label of the element the app last asked VoiceOver to focus.
@MainActor @Observable final class AXProbe {
  static let shared = AXProbe()

  static var isOn: Bool {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains("-demoAXProbe")
    #else
      false
    #endif
  }

  enum Kind { case cluster, place }

  var zoom = 0.0
  /// The label of the element last activated by the probe.
  var activated = ""
  /// The label of the element last posted to VoiceOver.
  var focused = ""
  /// Activates the first listed cluster or place; its label, or nil when none is listed.
  @ObservationIgnored var activate: ((Kind) -> String?)?

  /// Asks VoiceOver to focus `target`, and notes its label for the probe.
  static func post(_ notification: UIAccessibility.Notification, _ target: UIAccessibilityElement) {
    UIAccessibility.post(notification: notification, argument: target)
    if isOn { shared.focused = target.accessibilityLabel ?? "" }
  }
}

/// The probe's buttons and readouts, over the campaign map.
struct AXProbeOverlay: View {
  private var probe: AXProbe { .shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Button("Probe cluster") { run(.cluster) }.accessibilityIdentifier("probe-cluster")
        Button("Probe place") { run(.place) }.accessibilityIdentifier("probe-place")
      }
      Text(String(format: "%.2f", probe.zoom)).accessibilityIdentifier("probe-zoom")
      Text(probe.activated.isEmpty ? "none" : probe.activated).accessibilityIdentifier("probe-activated")
      Text(probe.focused.isEmpty ? "none" : probe.focused).accessibilityIdentifier("probe-focused")
    }
    .font(.caption2)
    .padding(4)
    .background(.regularMaterial)
  }

  private func run(_ kind: AXProbe.Kind) {
    probe.focused = ""
    probe.activated = probe.activate?(kind) ?? ""
  }
}
