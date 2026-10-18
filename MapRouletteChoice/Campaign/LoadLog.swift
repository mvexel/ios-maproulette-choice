import Foundation
import os

/// Campaign load timings: subsystem lol.osm.maproulette.choice, category "load", at debug level
/// (kept in memory only, so release builds write nothing). The open-time CI job
/// (scripts/open-time.sh) reads them; so can Console or Instruments.
@MainActor enum LoadLog {
  static let log = Logger(subsystem: "lol.osm.maproulette.choice", category: "load")
  /// When the campaign screen started reading the open campaign's pages.
  static var started = ContinuousClock.now
  /// Seconds since `started`, as "12.34 s".
  static var elapsed: String {
    let d = started.duration(to: .now).components
    return String(format: "%.2f s", Double(d.seconds) + Double(d.attoseconds) / 1e18)
  }
}
