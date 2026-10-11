import Foundation
import MapRoulette

/// What a campaign's tasks are called on screen ("stop", "bench"), derived from the identity tag
/// the challenge's payload guards on (`match`). Falls back to "place".
struct Noun: Hashable, Sendable {
  let one: String
  let many: String

  static let place = Noun(one: "place", many: "places")

  /// Known identity tags, most specific first.
  private static let known: [(key: String, value: String, noun: Noun)] = [
    ("highway", "bus_stop", Noun(one: "stop", many: "stops")),
    ("public_transport", "platform", Noun(one: "stop", many: "stops")),
    ("railway", "platform", Noun(one: "platform", many: "platforms")),
    ("amenity", "bench", Noun(one: "bench", many: "benches")),
    ("amenity", "bicycle_parking", Noun(one: "bike rack", many: "bike racks")),
    ("amenity", "waste_basket", Noun(one: "trash can", many: "trash cans")),
    ("amenity", "drinking_water", Noun(one: "water fountain", many: "water fountains")),
    ("amenity", "toilets", Noun(one: "restroom", many: "restrooms")),
    ("amenity", "shelter", Noun(one: "shelter", many: "shelters")),
    ("leisure", "playground", Noun(one: "playground", many: "playgrounds")),
    ("leisure", "park", Noun(one: "park", many: "parks")),
  ]

  static func from(match: [String: String]) -> Noun {
    known.first { match[$0.key] == $0.value }?.noun ?? .place
  }

  /// The noun for a campaign: from the first choice task's identity guard.
  static func from(_ tasks: [MapRouletteTask]) -> Noun {
    for task in tasks {
      if case .choice(_, let match, _, _) = task.work() { return from(match: match) }
    }
    return .place
  }

  /// "1 stop", "7 stops".
  func count(_ n: Int) -> String { "\(n) \(n == 1 ? one : many)" }
  var One: String { one.prefix(1).uppercased() + one.dropFirst() }
}

/// Participant-facing copy (docs: /mnt/project-files/design/personas-and-design.md §4). Expert
/// wording stays in `TaskText` and shows only with "Show OSM details".
enum Wording {
  static let notSure = "I'm not sure"
  static let notSureShort = "Not sure"
  static let somethingWrong = "Something's wrong here"
  static func cantCheck(_ noun: Noun) -> String { "I can't check this \(noun.one)" }

  // MARK: "Something's wrong here" (design/not-here-moved.md §2, §7)

  static let skipExplained = "Leave it for someone else."
  static let cantCheckExplained = "You're near it but can't see or reach it."
  static let notHere = "It's not here"
  static func notHereExplained(_ noun: Noun) -> String { "You're at the spot and there's no \(noun.one)." }
  static let moved = "It's moved"
  static let movedExplained = "You can see it somewhere else nearby. You'll show where."
  static let problemsMessage = "Nothing here changes OpenStreetMap. The organizer checks every report."
  /// With OSM details on, under "It's not here" and "It's moved".
  static let reportDetails = "Marks the task “Too hard”. Does not edit OpenStreetMap."

  static func movedTitle(_ noun: Noun) -> String { "Where is the \(noun.one) now?" }
  static let movedHelp = "Tap the map where it is, or stand next to it and use your location."
  static let standingAtIt = "I'm standing at it"
  static let waitingForFix = "Waiting for a better location. Or tap the map."
  static let onTheMap = "On the map"
  static let saveThisSpot = "Save this spot"
  /// Under 100 m to the nearest 5 m, then to the nearest 10 m.
  static func roundedMeters(_ meters: Double) -> Int {
    let step = meters < 100 ? 5.0 : 10.0
    return Int((meters / step).rounded() * step)
  }
  static func movedDistance(_ meters: Double) -> String {
    "About \(roundedMeters(meters)) m from where the map has it."
  }
  static let movedTooClose =
    "That's where the map already has it. If it's there, go back and answer the questions instead."
  static func movedFar(_ meters: Double, _ noun: Noun) -> String {
    "That's \(roundedMeters(meters)) m away. If it's a different \(noun.one), use “\(notHere)” instead."
  }
  static func movedTooFar(_ noun: Noun) -> String { "That's too far to be the same \(noun.one)." }
  static let spotOnly = "Only the spot you pick is saved, not your own location."
  static func spotIsHere(_ noun: Noun) -> String { "Your current location is saved as the \(noun.one)'s new spot." }

  static let checkReport = "Check your report"
  static let reporting = "You're reporting:"
  static func reportNotHere(_ noun: Noun) -> String { "The \(noun.one) isn't here." }
  static func reportMoved(_ meters: Double, _ noun: Noun) -> String {
    "The \(noun.one) has moved, about \(roundedMeters(meters)) m from where the map has it."
  }
  static let reportNotHereNote = "Nothing changes on OpenStreetMap. The organizer will check it."
  static let reportMovedNote = "Nothing changes on OpenStreetMap. The organizer will move it on the map."
  static let reportedNotHere = "Thanks, reported. The organizer will check it."
  static let reportedMoved = "Thanks, reported. The organizer will move it on the map."
  static func someoneReportedNotHere(_ noun: Noun) -> String { "Someone reported this \(noun.one) isn't here." }
  static func someoneReportedMoved(_ meters: Double, _ noun: Noun) -> String {
    "Someone reported this \(noun.one) moved, about \(roundedMeters(meters)) m."
  }
  static let needsAnotherLook = "Needs another look"
  static let needsAccount = "To save answers you'll sign in with a free OpenStreetMap account."

  /// A place's display name: its `name`, else "Stop 12345" from `ref`, else "Stop". The
  /// task name is often an OSM id ("node/123"), so it is shown only with OSM details.
  static func placeName(_ task: MapRouletteTask, _ noun: Noun) -> String {
    let properties = task.templateProperties()
    if let name = properties["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
    if let ref = properties["ref"]?.trimmingCharacters(in: .whitespaces), !ref.isEmpty { return "\(noun.One) \(ref)" }
    return noun.One
  }
  static let done = "Done"
  static let showDetails = "Show OSM details"
  static let showDetailsFooter =
    "For organizers and experienced mappers: shows tag changes, task and element ids, changeset links and the deletion setting."
  static let answersArePublic =
    "Your answers are saved to OpenStreetMap, the free map anyone can use and improve. Edits are public and show your OpenStreetMap username."
  /// Guests' answers reach OSM only after they finish signing up, under the username they pick then.
  static let guestAnswersArePublic =
    "Your answers go on OpenStreetMap, the free map anyone can use, when you finish on a computer. Map edits are public and show the username you choose then."
  static func locationStaysOnPhone(_ noun: Noun) -> String {
    "We use your location to find the nearest \(noun.many). It stays on your phone, unless you tap “I'm standing at it” to show where a \(noun.one) has moved."
  }

  static func skip(_ noun: Noun) -> String { "Skip this \(noun.one)" }
  static func alreadyChecked(_ noun: Noun) -> String { "Someone already checked this \(noun.one). Thanks anyway!" }
  static func cannotAnswer(_ noun: Noun) -> String { "This \(noun.one) can't be answered in the app." }
  static func checkFailed(_ noun: Noun) -> String {
    "Couldn't check this \(noun.one) right now. Check your connection and try again."
  }
  static func takenByOther(_ noun: Noun) -> String {
    "Someone else is checking this \(noun.one) right now. Try another one."
  }
  static func notSureCloses(_ noun: Noun) -> String {
    // Partial answers close the place (SDK decision D7); it returns only if the organizer
    // makes new tasks, so don't promise a later visit.
    "That's fine. The organizer can send someone back to \(noun.many) with open questions."
  }
  static func nothingAnswered(_ noun: Noun) -> String {
    "You weren't sure about any question. You can skip this \(noun.one) instead."
  }
  /// A guest's answers: saved, not on the map yet (deferred sign-up copy, never "on the map").
  static func savedForLater(_ todayCount: Int, _ noun: Noun) -> String {
    "Saved. That's \(noun.count(todayCount)) today."
  }
  static let putOnMapIntro =
    "To put them on the map, finish on a computer. We can email you a link."
  static let emailUse = "We only email you about these answers, and delete your address once they're on the map or removed."
  static func linkSent(to email: String, until: Date?) -> String {
    "Sent to \(email). Check your email later." + (until.map { " The link works until \(day($0))." } ?? "")
  }
  /// "Nov 30": the one date format for guest deadlines. A non-breaking space keeps month and day
  /// on one line (Iris B-8).
  static func day(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day()).replacingOccurrences(of: " ", with: "\u{00A0}")
  }
  static let enterEmailAgain = "Enter your email again and we'll send a new link."
  /// Phone sign-in doesn't claim saved answers yet (claim B5 not built); restore the old line when it does.
  static let signInPutsOnMap =
    "Sign in now and your next answers go straight on the map. The ones you already saved stay saved until you finish on a computer."
  /// Only a bad address is the participant's to fix (shown in red); the rest are calm.
  static func isInputError(_ error: any Error) -> Bool { (error as? MapRouletteError)?.kind == .validation }
  /// The backend sends the link only once the guest has a saved answer (409 `nothing_saved`).
  /// Matched by kind and server code, which the SDK has exposed since the guest API (#2).
  static func isNothingSaved(_ error: any Error) -> Bool {
    guard let error = error as? MapRouletteError else { return false }
    return error.kind == .conflict && error.reason == "nothing_saved"
  }
  static func linkFailed(_ error: any Error, _ noun: Noun = .place) -> String {
    if isNothingSaved(error) { return "Answer a \(noun.one) first, then we can send you the link." }
    if let error = error as? MapRouletteError, error.kind == .conflict, error.reason == "guest_claimed" {
      return "These answers are already linked to an OpenStreetMap account. Sign in with it to see them."
    }
    return switch (error as? MapRouletteError)?.kind {
    case .validation?: "That doesn't look like an email address."
    case .rateLimit?: "We've sent a few links already. Try again tomorrow."
    case .network?: "Couldn't connect. Check your connection and try again."
    default: "Couldn't send the link right now. Try again later."
    }
  }
  static func savedNotOnMap(_ count: Int, _ noun: Noun, until: Date?) -> String {
    "\(noun.count(count)) saved, not on the map yet."
      + (until.map { " Finish on a computer by \(day($0))." } ?? "")
  }
  /// Deferred sign-up §1.4 summary: "You checked 14 stops. The tally: 212 of 410."
  static func daySummary(_ checked: Int, done: Int, total: Int, _ noun: Noun) -> String {
    "You checked \(noun.count(checked)). The tally: \(done) of \(total)."
  }
  static func daySummarySaved(until: Date?) -> String {
    (until.map { "They're saved until \(day($0))." } ?? "They're saved for now.")
      + " If we emailed you a link, open it on a computer to put them on the map."
  }
  static let doneForToday = "I'm done for today"
  /// Deferred sign-up §1.6, in the last 3 days.
  static func savedClosing(_ count: Int, _ noun: Noun, on date: Date) -> String {
    "\(count) saved \(count == 1 ? noun.one : noun.many) will be removed on "
      + "\(day(date)) unless you finish on a computer."
  }
  /// After the deadline: calm, no error tone (§1.6).
  static let savedExpired =
    "Your saved answers weren't put on the map, so we removed them. They still count in the campaign's totals. Thanks for checking."
  static let deleteMyData = "Delete my data"
  static let deleteMyDataExplained =
    "Removes your email and any saved answers that aren't on the map yet. Answers already on the map stay there, because they belong to OpenStreetMap now."
  static let deleteMyDataDone = "Done. Your email and saved answers are deleted."
  static let savedForLaterNote = "Saved on our server. They go on the map when you finish on a computer."
  static func saved(_ todayCount: Int, _ noun: Noun) -> String {
    "Saved, thanks! That's \(noun.count(todayCount)) today."
  }
  static func checkedByOtherFirst(_ noun: Noun) -> String {
    "Someone else checked this \(noun.one) first, so your answers weren't saved."
  }
  static func next(_ noun: Noun, distance: String?, hasOrigin: Bool) -> String {
    guard hasOrigin else { return "Choose another \(noun.one)" }
    return "Next nearest \(noun.one)" + (distance.map { " · \($0)" } ?? "")
  }
  static func nearest(_ noun: Noun, distance: String?, hasOrigin: Bool) -> String {
    guard hasOrigin else { return "Choose a \(noun.one)" }
    return "Nearest \(noun.one)" + (distance.map { " · \($0)" } ?? "")
  }
  static func locationUnavailable(_ noun: Noun, isOff: Bool) -> String {
    (isOff ? "Location is off." : "Your location isn't available yet.")
      + " Choose a \(noun.one) on the map or in the list."
  }
  static func progress(done: Int, total: Int, _ noun: Noun) -> String {
    "The tally: \(done) of \(noun.count(total)) checked"
  }

  // MARK: Campaign preview (design/preview-mode.md §8)

  /// The banner reads "**Preview.** Answers aren't saved." with Exit.
  static let previewBannerTitle = "Preview."
  static let previewBannerText = "Answers aren't saved."
  static let previewAnnouncement = "Preview mode. Answers aren't saved."
  static let exitPreview = "Exit"
  static let previewSignInTitle = "Sign in to preview this campaign"
  static let previewSignInText =
    "This campaign isn't published yet. Sign in with the OpenStreetMap account that manages it."
  static let previewSignIn = "Sign in to OpenStreetMap"
  static let cancel = "Cancel"
  static let previewNoAccessTitle = "You can't preview this campaign"
  /// `account`: who is signed in now; the parenthesis is left out when unknown.
  static func previewNoAccessText(_ account: String?) -> String {
    "Only the campaign's organizers can see it before it's published. Check you're signed in as the right account"
      + (account.map { " (now: \($0))." } ?? ".")
  }
  static let switchAccount = "Switch account"
  static let close = "Close"
  static let previewAlreadyPublished = "This campaign is published, so answers are saved for real."
  static func previewingAs(_ account: String) -> String { "You're previewing as \(account)." }
  /// The signed-in account as preview names it: the OpenStreetMap username (no "@"), else
  /// "MapRoulette user 7" when the server didn't send one.
  static func account(_ userID: Int64?, displayName: String? = nil) -> String? {
    if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
    return userID.map { "MapRoulette user \($0)" }
  }
  static let donePreview = "Done (preview)"
  static let previewNotSaved = "Preview: not saved."
  /// `realLine`: what the saved screen says in the real campaign, quoted.
  static func previewWouldSay(_ realLine: String) -> String { "In the real campaign this would say: “\(realLine)”" }
  static func wouldSet(_ tags: String) -> String { "Would set: \(tags)" }
  static let previewNowPublished = "This campaign is now published."
  static let openForReal = "Open it for real"
  /// An empty draft. `noun` is the campaign's own (`Noun.from`); a draft without places has no
  /// identity guard to name them by, so it is usually the generic "places".
  /// A draft opened without its preview link.
  static let notPublished = "This campaign isn't published yet."

  static func previewNoPlaces(_ noun: Noun) -> String {
    "No \(noun.many) yet. Add them in the admin, then pull down to refresh."
  }
  static func invalidSurvey(_ reason: String) -> String { "This question set can't be shown: \(reason)" }
  /// Why a draft's place can't be asked about, for `invalidSurvey`. The SDK doesn't say which part
  /// of a payload failed to parse.
  static func invalidSurveyReason(_ task: MapRouletteTask) -> String {
    switch task.work() {
    case .unknown: "its question payload isn't valid. Check the questions and answers in the admin."
    default: "it has no multiple-choice questions."
    }
  }
}
