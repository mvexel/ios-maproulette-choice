import Foundation
import MapRoulette

/// Per-device campaign state: the campaign to reopen, welcome cards already seen, how many places
/// this device checked per campaign per day, and tasks finished since the lists last reloaded.
@MainActor @Observable final class CampaignStore {
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let calendar: Calendar

  /// Tasks this device finished (saved or recorded) since launch; shown as done before a reload.
  private(set) var justDone: Set<Int64> = []
  /// Tasks this device reported as not here or moved since launch (design/not-here-moved.md §4):
  /// they count in the participant's own total, but not as checked in the campaign, and are never
  /// offered as "next nearest".
  private(set) var justReported: [Int64: TaskReport] = [:]
  /// Tasks this device closed with another status-6 outcome since launch ("There's no door", "I
  /// can't check this"): like a report, "Needs another look", out of the tally and never next
  /// nearest, but with no banner or dot (not-here-moved.md §3.3).
  private(set) var justFlagged: Set<Int64> = []
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

  /// Places that need another look: reported (`reports`, from the list or this device) or flagged
  /// here.
  func lookAgain(_ reports: [Int64: TaskReport]) -> Set<Int64> { justFlagged.union(reports.keys) }

  /// Places this device checked in `challenge` today (local calendar day).
  func checkedToday(_ challenge: Int64) -> Int {
    _ = revision
    return defaults.integer(forKey: key(challenge))
  }

  /// Records one finished task; repeated calls for the same task count once. A `report` (not here
  /// or moved) or a `flagged` outcome counts for the participant but leaves the task open in the
  /// campaign.
  func recordChecked(_ challenge: Int64, task: Int64, report: TaskReport? = nil, flagged: Bool = false) {
    guard !justDone.contains(task), justReported[task] == nil, !justFlagged.contains(task) else { return }
    if let report { justReported[task] = report } else if flagged { justFlagged.insert(task) } else {
      justDone.insert(task)
    }
    defaults.set(defaults.integer(forKey: key(challenge)) + 1, forKey: key(challenge))
    revision += 1
  }

  /// One more for today without marking the place done: a guest's answer kept on the phone
  /// (offline-copy.md: today's count includes it).
  func countToday(_ challenge: Int64) {
    defaults.set(defaults.integer(forKey: key(challenge)) + 1, forKey: key(challenge))
    revision += 1
  }

  /// A kept answer reached the server: the place is done here, already in today's count.
  func sent(_ task: Int64) {
    justDone.insert(task)
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
  /// The task map shows the aerial photo (design/which-one-spec.md §D); kept from place to place.
  static let aerialPhoto = "aerialPhoto"
}
