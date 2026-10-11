import Foundation

/// Per-device campaign state: the campaign to reopen, welcome cards already seen, how many places
/// this device checked per campaign per day, and tasks finished since the lists last reloaded.
@MainActor @Observable final class CampaignStore {
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let calendar: Calendar

  /// Tasks this device finished (saved or recorded) since launch; shown as done before a reload.
  private(set) var justDone: Set<Int64> = []
  /// Bumped when a count changes, so views showing counts refresh.
  private(set) var revision = 0

  init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
    self.defaults = defaults
    self.now = now
    self.calendar = calendar
  }

  /// The campaign the app opens on launch: the last one opened.
  var lastCampaign: Int64? {
    get {
      _ = revision
      let v = (defaults.object(forKey: "lastCampaign") as? NSNumber)?.int64Value ?? 0
      return v > 0 ? v : nil
    }
    set {
      if let newValue { defaults.set(NSNumber(value: newValue), forKey: "lastCampaign") } else {
        defaults.removeObject(forKey: "lastCampaign")
      }
      revision += 1
    }
  }

  func hasSeenWelcome(_ challenge: Int64) -> Bool {
    seenWelcome.contains(challenge)
  }

  func markWelcomeSeen(_ challenge: Int64) {
    var seen = seenWelcome
    guard seen.insert(challenge).inserted else { return }
    defaults.set(seen.sorted().map { NSNumber(value: $0) }, forKey: "welcomeSeen")
  }

  private var seenWelcome: Set<Int64> {
    Set((defaults.array(forKey: "welcomeSeen") as? [NSNumber] ?? []).map(\.int64Value))
  }

  /// Places this device checked in `challenge` today (local calendar day).
  func checkedToday(_ challenge: Int64) -> Int {
    _ = revision
    return defaults.integer(forKey: key(challenge))
  }

  /// Records one finished task; repeated calls for the same task count once.
  func recordChecked(_ challenge: Int64, task: Int64) {
    guard !justDone.contains(task) else { return }
    justDone.insert(task)
    defaults.set(defaults.integer(forKey: key(challenge)) + 1, forKey: key(challenge))
    revision += 1
  }

  private func key(_ challenge: Int64) -> String {
    let d = calendar.dateComponents([.year, .month, .day], from: now())
    return "checked.\(challenge).\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)"
  }
}

/// Settings keys shared by views (`@AppStorage`).
enum SettingsKey {
  static let showOSMDetails = "showOSMDetails"
  /// The guest's "put them on the map" card was shown after the first saved answer.
  static let putOnMapCardShown = "putOnMapCardShown"
}
