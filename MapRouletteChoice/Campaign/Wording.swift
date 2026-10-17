import Foundation
import MapRoulette

/// What a campaign's tasks are called on screen ("stop", "bench"), derived from the identity tag
/// the challenge's payload guards on (`match`). Falls back to "place".
struct Noun: Hashable, Sendable {
  let one: String
  let many: String

  static let place = Noun(one: "place", many: "places")

  /// Known identity tags, most specific first. A nil value matches any value of the key
  /// (`entrance=main`, `entrance=yes`).
  private static let known: [(key: String, value: String?, noun: Noun)] = [
    ("highway", "bus_stop", Noun(one: "stop", many: "stops")),
    ("highway", "crossing", Noun(one: "crossing", many: "crossings")),
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
    ("entrance", nil, Noun(one: "entrance", many: "entrances")),
    ("natural", "tree", Noun(one: "tree", many: "trees")),
    // Last: any building, whatever else it is.
    ("building", nil, Noun(one: "building", many: "buildings")),
  ]

  static func from(match: [String: String]) -> Noun {
    known.first { k in match[k.key].map { k.value == nil || $0 == k.value } ?? false }?.noun ?? .place
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
  /// "a stop", "an entrance". Every known noun starts with a letter that sounds as written.
  var aOne: String { ("aeiou".contains(one.prefix(1)) ? "an " : "a ") + one }
}

/// Participant-facing copy (docs: /mnt/project-files/design/personas-and-design.md §4). Expert
/// wording stays in `TaskText` and shows only with "Show OSM details".
enum Wording {
  static let notSure = "I'm not sure"
  /// 403 mobile_writes_disabled: the server has saving switched off (copy-fixes-2026-10-11.md).
  /// On save, above the kept form; on opening a place, in place of the form.
  static let writesPaused =
    "Saving answers is paused right now. This answer wasn't saved, and nothing changed on the map. Please try again later."
  static func writesPausedOnOpen(_ noun: Noun) -> String {
    "Saving answers is paused right now, so this \(noun.one) can't be checked. Nothing changed on the map. Please try again later."
  }
  static let notSureShort = "Not sure"
  static let somethingWrong = "Something's wrong here"
  /// A guest on a task that can't hold answers until sign-in.
  static func accountNeededTitle(_ noun: Noun) -> String { "Sign in to check this \(noun.one)" }
  static func accountNeeded(_ noun: Noun) -> String {
    "This \(noun.one) needs an OpenStreetMap account. Any answers you've saved stay saved."
  }
  static func cantCheck(_ noun: Noun) -> String { "I can't check this \(noun.one)" }

  // MARK: "Something's wrong here" (design/not-here-moved.md §2, §7)

  static let skipExplained = "Leave it for someone else."
  static let cantCheckExplained = "You're near it but can't see or reach it."
  /// The way out on the question screen (design/which-one-spec.md §F): records "I can't check".
  static func cantTell(_ noun: Noun) -> String { "I can't tell which \(noun.one)" }
  static func cantTellThanks(_ noun: Noun) -> String { "Thanks. Someone will take another look at this \(noun.one)." }
  /// Under the close-up map, when its first frame shows other places (§B).
  static func otherDots(_ noun: Noun) -> String { "Grey dots are other \(noun.many) in this campaign." }
  /// The task map's toggle (design/which-one-spec.md §D).
  static let mapView = "Map"
  static let aerialView = "Aerial photo"
  /// Under the task map when location is denied or off (design/which-one-spec.md §C rule 1).
  static func locationOff(_ noun: Noun) -> String { "Turn on location to see which way the \(noun.one) is." }
  static let openSettings = "Open Settings"
  static func closeUpMapLabel(_ name: String, _ noun: Noun, neighbours: Bool) -> String {
    neighbours ? "Map of \(name), with other \(noun.many) nearby" : "Map of \(name)"
  }
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
  /// A moved distance under the app's one unit rule: metres as `roundedMeters`, feet and miles in
  /// the US (design/which-one-spec.md §C).
  static func movedMeasure(_ meters: Double, us: Bool = DirectionLine.usesFeet) -> String {
    us ? DirectionLine.distance(meters, us: true) : "\(roundedMeters(meters)) m"
  }
  static func movedDistance(_ meters: Double, us: Bool = DirectionLine.usesFeet) -> String {
    "About \(movedMeasure(meters, us: us)) from where the map has it."
  }
  static let movedTooClose =
    "That's where the map already has it. If it's there, go back and answer the questions instead."
  static func movedFar(_ meters: Double, _ noun: Noun, us: Bool = DirectionLine.usesFeet) -> String {
    "That's \(movedMeasure(meters, us: us)) away. If it's a different \(noun.one), use “\(notHere)” instead."
  }
  static func movedTooFar(_ noun: Noun) -> String { "That's too far to be the same \(noun.one)." }
  static let spotOnly = "Only the spot you pick is saved, not your own location."
  static func spotIsHere(_ noun: Noun) -> String { "Your current location is saved as the \(noun.one)'s new spot." }

  static let checkReport = "Check your report"
  static let reporting = "You're reporting:"
  static func reportNotHere(_ noun: Noun) -> String { "The \(noun.one) isn't here." }
  static func reportMoved(_ meters: Double, _ noun: Noun, us: Bool = DirectionLine.usesFeet) -> String {
    "The \(noun.one) has moved, about \(movedMeasure(meters, us: us)) from where the map has it."
  }
  static let reportNotHereNote = "Nothing changes on OpenStreetMap. The organizer will check it."
  static let reportMovedNote = "Nothing changes on OpenStreetMap. The organizer will move it on the map."
  static let reportedNotHere = "Thanks, reported. The organizer will check it."
  static let reportedMoved = "Thanks, reported. The organizer will move it on the map."
  static func someoneReportedNotHere(_ noun: Noun) -> String { "Someone reported this \(noun.one) isn't here." }
  static func someoneReportedMoved(_ meters: Double, _ noun: Noun, us: Bool = DirectionLine.usesFeet) -> String {
    "Someone reported this \(noun.one) moved, about \(movedMeasure(meters, us: us))."
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
  /// Guests' answers are counted at once; local mappers add them to OSM under their own names
  /// (design/handback-copy.md §1).
  static let guestAnswersArePublic =
    "Your answers are counted for this campaign right away. Local mappers then check them and add them to OpenStreetMap, the free map anyone can use, under their own names."
  static func locationStaysOnPhone(_ noun: Noun) -> String {
    "We use your location to find the nearest \(noun.many). It stays on your phone, unless you tap “I'm standing at it” to show where \(noun.aOne) has moved."
  }

  static func skip(_ noun: Noun) -> String { "Skip this \(noun.one)" }
  /// A place the fresh OSM check turned down: gone from the map, changed since the campaign
  /// started, or (key changed, unknown) already checked. A save refused because the place changed
  /// while answering says so, unless every answered key was filled by someone else (Iris, Tess AB7).
  static func noLongerNeeded(_ noun: Noun, _ reason: IneligibleReason?, onSave: Bool = false) -> String {
    switch reason {
    case .keyChanged? where onSave: "This \(noun.one) changed on the map while you were answering. Thanks anyway!"
    case .elementGone?: "This \(noun.one) is no longer on the map. Thanks anyway!"
    case .matchFailed?: "This \(noun.one) changed on the map since the campaign started. Thanks anyway!"
    case .keyChanged?, .unknown?, nil: "Someone already checked this \(noun.one). Thanks anyway!"
    }
  }
  /// Opening a place that's gone: nothing was answered, so no thanks (Iris, offline-copy.md).
  static func goneOnOpen(_ noun: Noun) -> String { "This \(noun.one) is no longer on the map." }
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
  /// Phone sign-in claims the saved answers (B5), so the original line is true again
  /// (design/copy-fixes-2026-10-11.md row 5).
  static let signInPutsOnMap = "Sign in now and your saved answers go on the map right away."
  /// The account line after sign-in (copy-fixes-2026-10-11.md): the OSM name when known.
  static func signedIn(_ name: String?) -> String {
    name.map { "You're signed in as \($0)." } ?? "You're signed in with OpenStreetMap."
  }
  /// After a phone sign-in with saved answers (B5; design/copy-fixes-2026-10-11.md, "Phone claim
  /// status line"). `name` is the signed-in OSM account, which matters when the answers turn out
  /// to be linked to another one.
  static func claimMessage(_ outcome: AppSession.ClaimOutcome, name: String?) -> String {
    let who = signedIn(name)
    switch outcome {
    case .started(let pending, let waiting):
      guard pending > 0 else { return "\(who) New answers go straight on the map from now on." }
      let one = pending == 1
      if waiting {
        return "\(who) \(one ? "Your saved answer is" : "Your \(pending) saved answers are") now linked to your "
          + "account. \(one ? "It'll" : "They'll") go on the map later."
      }
      return "\(who) Putting \(one ? "your saved answer" : "your \(pending) saved answers") on the map\u{2026}"
    case .gone:
      return "\(who) We couldn't find your saved answers. "
        + "They may have expired, or they're linked to a different OpenStreetMap account."
    case .reauth:
      // Not signed in in any useful sense, so no "You're signed in as" prefix.
      return "Sign in again so we can put your saved answers on the map."
    case .later:
      return "\(who) Your answers are still saved. We'll try again next time you open the app."
    }
  }
  /// A claim's progress and result on the status line (design/copy-fixes-2026-10-11.md, "Phone
  /// claim status line" and its edge cases; no "You're signed in" prefix). Superseded answers
  /// were replaced by newer ones, so they don't count. Answers that failed are still saved.
  static func claimProgress(_ status: ClaimStatus) -> String {
    let n = max(status.total - status.superseded, 0)
    let k = status.published
    let m = status.skipped
    switch status.state {
    case .waiting, .queued, .running:
      return "Putting your answers on the map\u{2026} \(k) of \(n)"
    case .failed, .done where status.failed > 0:
      let some = k == 0 ? "None of your answers are on the map yet." : "\(k) of \(n) \(k == 1 ? "is" : "are") on the map."
      if m > 0 {
        return some + " "
          + (m == 1
            ? "1 wasn't added, because someone changed that place after you checked."
            : "\(m) weren't added, because someone changed those places after you checked.")
          + " The rest are still saved."
      }
      guard k > 0 else {
        return n == 1
          ? "Your answer isn't on the map yet. It's still saved."
          : "None of your answers are on the map yet. They're still saved."
      }
      return some + " The rest are still saved."
    case .done:
      let on = k == 1 ? "\u{2713} 1 answer is on the map." : "\u{2713} \(k) answers are on the map."
      guard m > 0 else { return on }
      guard k > 0 else {
        return m == 1
          ? "Your answer wasn't added, because someone changed that place on the map after you checked."
          : "None of your answers were added, because someone changed those places on the map after you checked."
      }
      return on + " "
        + (m == 1
          ? "1 wasn't added, because someone changed that place on the map after you checked."
          : "\(m) weren't added, because someone changed those places on the map after you checked.")
    }
  }
  /// When the app stops reading a claim that hasn't finished: the "…" line would look live.
  static let claimStillGoing = "Your answers are still going on the map. You can carry on; this finishes on its own."
  /// The campaign page's banner: counted now, on the map once a local mapper adds it (handback §1).
  static func savedNotOnMap(_ count: Int, _ noun: Noun) -> String {
    "\(noun.count(count)) saved and counted."
  }
  /// Deferred sign-up §1.4 summary: "You checked 14 stops. The tally: 212 of 410."
  /// With nothing checked today only the tally shows (Iris).
  static func daySummary(_ checked: Int, done: Int, total: Int, _ noun: Noun) -> String {
    let tally = "The tally: \(done) of \(total)."
    return checked == 0 ? tally : "You checked \(noun.count(checked)). " + tally
  }
  /// The day summary's heading: "Your answers" when nothing was checked today (Iris).
  static func daySummaryTitle(_ checked: Int) -> String { checked == 0 ? "Your answers" : "Nice work today." }
  /// Answers a local mapper has put on the map, shown only in "Your answers" (handback §1).
  /// Skipped or rejected answers show nothing.
  static func onMap(_ count: Int) -> String { "\u{2713} \(count) on the map" }
  /// What VoiceOver reads for `onMap`, without "check mark".
  static func onMapSpoken(_ count: Int) -> String { "\(count) on the map" }
  /// Never says when, or that they will be added (handback §1).
  static let daySummarySaved = "Local mappers will check them and add them to the map."
  static let doneForToday = "I'm done for today"
  static let deleteMyData = "Delete my data"
  static let deleteMyDataExplained =
    "Removes your saved answers that aren't on the map yet, so mappers won't see them. Answers already on the map stay there, because they're part of OpenStreetMap now."
  /// iOS keeps the guest identity in the Keychain, which outlives the app.
  static let deleteMyDataReinstall = "Deleting the app doesn't remove them. Use this button instead."
  static let deleteMyDataDone = "Done. Your saved answers are deleted."
  /// Added to the explainer while answers wait on the phone (offline-copy.md).
  static let deleteMyDataWaiting = "It also removes answers still waiting on this phone."

  /// The campaign shown from the phone's copy, with no connection (offline-copy.md, O2).
  static func keptCopy(_ time: String) -> String { "No signal. Showing the list from \(time). Some may be done already." }
  /// When the kept copy was saved: minutes within the hour (at least 1), the device's time the same
  /// day, "yesterday", then the device's month and day.
  static func keptTime(_ saved: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current)
    -> String
  {
    let minutes = max(0, Int(now.timeIntervalSince(saved) / 60))
    if minutes < 60 { return "\(max(1, minutes)) min ago" }
    if calendar.isDate(saved, inSameDayAs: now) {
      let time = DateFormatter()
      time.locale = locale
      time.calendar = calendar
      time.timeZone = calendar.timeZone
      time.dateStyle = .none
      time.timeStyle = .short
      return time.string(from: saved)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(saved, inSameDayAs: yesterday) {
      return "yesterday"
    }
    let day = DateFormatter()
    day.locale = locale
    day.calendar = calendar
    day.timeZone = calendar.timeZone
    day.setLocalizedDateFormatFromTemplate("MMMd")
    return day.string(from: saved)
  }
  /// A campaign bigger than the app reads (L1). Not "first" or "nearest": the server order is by id (Iris).
  static func notAllShown(_ count: Int, _ noun: Noun) -> String {
    "Showing \(count.formatted()) \(noun.many). This campaign has more."
  }
  /// A campaign opened with no signal that the phone has no copy of; shown with Retry.
  static let notKeptNoSignal = "No signal, and this campaign isn't on your phone yet. Try again when you have signal."

  // MARK: Waiting on the phone (BACKLOG O1, design/offline-copy.md)
  // Never "offline", "queue", "sync" or "upload"; never "saved and counted" for these.

  /// Under "Saved. That's N today." every time the answer stays on the phone, in place of the save note.
  static let keptOnPhone = "Kept on this phone for now. It sends by itself when you have signal."
  /// The place's pin and list row.
  static let waitingToSend = "Waiting to send"
  /// First line of "Your answers".
  static func waitingForSignal(_ count: Int) -> String { "\(count) waiting for signal" }
  /// Day summary, after the tally line.
  static func stillOnPhone(_ count: Int, _ noun: Noun) -> String {
    count == 1
      ? "1 \(noun.one) is still on this phone. It sends by itself when you have signal, so keep Street Tally installed until then."
      : "\(noun.count(count)) are still on this phone. They send by themselves when you have signal, so keep Street Tally installed until then."
  }
  static let savedForLaterNote = "Saved and counted. Local mappers check answers and add them to the map."
  /// The guest pending cap (200 per install, an abuse limit; handback §1).
  /// Waiting answers the server turned down once it could check the map (offline-copy.md row 17).
  static func waitingNotNeeded(_ count: Int) -> String {
    count == 1
      ? "1 waiting answer wasn't needed. The place changed on the map before it was sent."
      : "\(count) waiting answers weren't needed. The places changed on the map before they were sent."
  }
  static func pendingLimit(_ noun: Noun) -> String {
    "That's as many \(noun.many) as one phone can answer without an account for now. "
      + "Tap “I already use OpenStreetMap” to sign in and keep going."
  }
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
    guard hasOrigin else { return "Choose \(noun.aOne)" }
    return "Nearest \(noun.one)" + (distance.map { " · \($0)" } ?? "")
  }
  static func locationUnavailable(_ noun: Noun, isOff: Bool) -> String {
    (isOff ? "Location is off." : "Your location isn't available yet.")
      + " Choose \(noun.aOne) on the map or in the list."
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
