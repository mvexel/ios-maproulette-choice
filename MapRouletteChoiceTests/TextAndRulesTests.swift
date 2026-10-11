import Foundation
import MapRoulette
import Testing

@testable import MapRouletteChoice

@MainActor @Suite struct TaskTextTests {
  @Test func statusLabels() {
    #expect(TaskText.status(nil) == "Status unavailable")
    #expect(TaskText.status(2) == "Not an issue")
    #expect(TaskText.status(42) == "Unknown status (42)")
    #expect(TaskText.reviewStatus(-1) == nil)
    #expect(TaskText.reviewStatus(0) == "Review requested")
  }

  @Test func tagChangeAndExplanations() async throws {
    let task = try await makeTask()
    guard case .choice(let element, _, let questions, _) = task.work() else { Issue.record("not choice"); return }
    #expect(TaskText.tagChange(questions[0].options[0]) == "backrest=yes")
    let off = outcomes(task, deletion: false)
    let on = outcomes(task, deletion: true)
    #expect(TaskText.outcomeExplanation(on[1], element: element).hasPrefix("Deletes node/123"))
    #expect(TaskText.outcomeExplanation(off[1], element: element) == "Marks the task “Not an issue”. Does not edit OpenStreetMap.")
    #expect(TaskText.outcomeExplanation(off[1], element: element, notDeletable: true).contains("is not deleted"))
    #expect(TaskText.outcomeExplanation(off[2], element: element).contains("stays open"))
  }

  @Test func answersSummaryListsExactChangesAndCantTell() async throws {
    let task = try await makeTask()
    let work = try #require(ChoiceWork(task.work()))
    var form = TaskWorkController.form(work, outcomes: outcomes(task), deleteAllowed: true)
    form.answers = ["backrest": "no"]
    let text = TaskText.answersSummary(form, taskID: 42, me: 7, osmServer: TaskText.devOSM)
    #expect(text.contains("• backrest=no"))
    #expect(text.contains("Left as “Can't tell” (not changed):\n• What is the seat mainly made of?"))
    #expect(text.contains("marks task 42 as Fixed for user 7"))
    #expect(text.contains("development OpenStreetMap server (master.apis.dev.openstreetmap.org)"))
  }

  @Test func outcomeSummaries() async throws {
    let task = try await makeTask()
    let gone = try #require(outcomes(task, deletion: true).first { $0.id == "gone" })
    let element = try #require(ChoiceWork(task.work())).element
    #expect(
      TaskText.outcomeSummary(gone, element: element, taskID: 42, me: 7, osmServer: nil)
        .hasPrefix("Delete node/123 from OpenStreetMap"))
    let plain = try #require(TaskWorkController.withoutDeletion(gone))
    #expect(
      TaskText.outcomeSummary(plain, element: element, taskID: 42, me: 7, osmServer: nil, notDeletable: true)
        .contains("so it is not deleted"))
  }

  @Test func completedByAndChangesetLinks() {
    #expect(TaskText.completedBy(7, me: 7) == "Completed by you (MapRoulette user 7).")
    #expect(TaskText.completedBy(8, me: 7).contains("not you"))
    #expect(TaskText.completedBy(nil, me: 7).contains("did not report"))
    #expect(TaskText.changesetURL(TaskText.devOSM, 5)?.absoluteString == "https://master.apis.dev.openstreetmap.org/changeset/5")
    #expect(TaskText.changesetURL(nil, 5) == nil)
  }

  @Test func nextTasksWrapAroundAndSkipTheCurrentTask() {
    #expect(TaskText.nextTasks([1, 2, 3, 4], current: 3) == [4, 1, 2])
    #expect(TaskText.nextTasks([1, 2], current: 9) == [1, 2])
    #expect(TaskText.nextTasks([5], current: 5) == [])
  }

  @Test func unavailableReasons() async throws {
    #expect(TaskText.unavailableReason(try await makeTask(bundleID: 3)).contains("bundle"))
    #expect(TaskText.unavailableReason(try await makeTask(payload: nil)).contains("only handles multiple-choice"))
    #expect(TaskText.unavailableReason(try await makeTask(status: 1)) == "This task is fixed. There is nothing left to do.")
  }

  @Test func instructionFallsBackToTheChallenge() async throws {
    let challenge = try await makeChallenge()
    #expect(TaskText.instruction(try await makeTask(), challenge) == "Add backrest")
    #expect(TaskText.instruction(try await makeTask(instruction: "Task {{#mrTaskId}}"), challenge) == "Task 42")
  }
}

@Suite struct SessionRuleTests {
  @Test func writesOnlyForTheAllowlistedStagingOrigin() {
    #expect(AppSession.writesAllowed(origin: "https://mr-api.osm.lol", loopbackAllowed: false))
    #expect(!AppSession.writesAllowed(origin: "https://maproulette.org", loopbackAllowed: false))
    #expect(!AppSession.writesAllowed(origin: "https://mr-api.osm.lol.evil", loopbackAllowed: false))
    #expect(!AppSession.writesAllowed(origin: "http://127.0.0.1:9000", loopbackAllowed: false))
    #expect(AppSession.writesAllowed(origin: "http://127.0.0.1:9000", loopbackAllowed: true))
  }

  @Test func stageAndProdWritesOnlyWhenTheBuildAllowsThem() {
    for origin in ["https://mr-stage.osm.lol", "https://mr-prod.osm.lol"] {
      #expect(!AppSession.writesAllowed(origin: origin, loopbackAllowed: false))
      #expect(AppSession.writesAllowed(origin: origin, loopbackAllowed: false, liveAllowed: true))
      #expect(AppSession.osmServers[origin] == TaskText.liveOSM)
    }
    #expect(!AppSession.writesAllowed(origin: "https://maproulette.org", loopbackAllowed: false, liveAllowed: true))
    #expect(!AppSession.writesAllowed(origin: "https://mr-prod.osm.lol.evil", loopbackAllowed: false, liveAllowed: true))
  }

  @Test func scopes() {
    #expect(AppSession.requestedScope(writesConfigured: true) == "tasks:read tasks:write osm:tagfix")
    #expect(AppSession.requestedScope(writesConfigured: false) == "tasks:read")
    let all = "tasks:read tasks:write osm:tagfix"
    #expect(AppSession.acceptableGrant(["tasks:read"], requested: all))
    #expect(AppSession.acceptableGrant(["tasks:read", "tasks:write", "osm:tagfix"], requested: all))
    #expect(!AppSession.acceptableGrant(["tasks:read", "osm:tagfix"], requested: all))
    #expect(!AppSession.acceptableGrant(["tasks:read", "tasks:write"], requested: "tasks:read"))
    #expect(!AppSession.acceptableGrant(["tasks:write"], requested: all))
    #expect(AppSession.needsReconsent(writesConfigured: true, granted: ["tasks:read", "tasks:write"]))
    #expect(!AppSession.needsReconsent(writesConfigured: true, granted: ["tasks:read", "tasks:write", "osm:tagfix"]))
    #expect(!AppSession.needsReconsent(writesConfigured: false, granted: ["tasks:read"]))
  }

  @Test func taskWritesAreRecognizedWhateverTheMethod() {
    let base = "https://mr-api.osm.lol/api/v2/task/12/"
    for write in ["start", "refreshLock", "release", "skip", "choice", "1", "6"] {
      #expect(AppSession.isTaskWrite(URL(string: base + write)!), "\(write)")
    }
    #expect(!AppSession.isTaskWrite(URL(string: base + "choice/check")!))
    #expect(!AppSession.isTaskWrite(URL(string: "https://mr-api.osm.lol/api/v2/task/12")!))
    #expect(!AppSession.isTaskWrite(URL(string: "https://mr-api.osm.lol/api/v2/challenge/3/tasks?limit=50")!))
  }

  @Test func osmReauthIsDetectedFromTheBody() {
    #expect(AppSession.isOsmReauth(Data(#"{"error":"osm_reauth_required"}"#.utf8)))
    #expect(!AppSession.isOsmReauth(Data(#"{"error":"invalid_token"}"#.utf8)))
    #expect(!AppSession.isOsmReauth(Data("not json".utf8)))
  }

  @Test func pkceChallengeIsS256Base64URL() {
    // printf %s VERIFIER | openssl dgst -sha256 -binary | base64, then base64url without padding.
    #expect(
      AppSession.challenge("dBjftJeZ4CVP-mJ92K9a7xGSaWPMQbCqvrRB3t3G1nE")
        == "C7fJsMKDyV4zukZMpHln8NfheCz-LQxDT-4T-nsjxpw")
  }
}

@Suite struct EndpointTests {
  @Test func originIsValidatedAndNormalized() throws {
    let e = try AuthEndpoints(baseURL: "https://MR-API.osm.lol/", clientID: "maproulette-ios-example", allowLoopback: false)
    #expect(e.origin == "https://mr-api.osm.lol")
    #expect(e.api.absoluteString == "https://mr-api.osm.lol/api/v2/")
    #expect(e.token.absoluteString == "https://mr-api.osm.lol/oauth/mobile/token")
    #expect(throws: AuthEndpoints.InvalidConfiguration.self) {
      try AuthEndpoints(baseURL: "http://mr-api.osm.lol", clientID: "", allowLoopback: false)
    }
    #expect(throws: AuthEndpoints.InvalidConfiguration.self) {
      try AuthEndpoints(baseURL: "https://mr-api.osm.lol/api", clientID: "", allowLoopback: false)
    }
    #expect(throws: AuthEndpoints.InvalidConfiguration.self) {
      try AuthEndpoints(baseURL: "https://user@mr-api.osm.lol", clientID: "", allowLoopback: false)
    }
    #expect(throws: AuthEndpoints.InvalidConfiguration.self) {
      try AuthEndpoints(baseURL: "https://mr-api.osm.lol", clientID: "bad id", allowLoopback: false)
    }
    #expect(throws: AuthEndpoints.InvalidConfiguration.self) {
      try AuthEndpoints(baseURL: "http://127.0.0.1:9000", clientID: "", allowLoopback: false)
    }
    #expect(try AuthEndpoints(baseURL: "http://127.0.0.1:9000", clientID: "", allowLoopback: true).origin == "http://127.0.0.1:9000")
  }

  @Test func connectionsAndCallbacksAreExact() throws {
    let e = try AuthEndpoints(baseURL: "https://mr-api.osm.lol", clientID: "c", allowLoopback: false)
    #expect(e.permitsConnection(URL(string: "https://mr-api.osm.lol/oauth/mobile/token")!))
    #expect(!e.permitsConnection(URL(string: "https://mr-api.osm.lol:444/oauth/mobile/token")!))
    #expect(!e.permitsConnection(URL(string: "https://evil.example/oauth/mobile/token")!))
    let scheme = AuthEndpoints.callbackScheme
    #expect(AuthEndpoints.redirect == "\(scheme):/oauth2redirect")
    #expect(e.acceptsCallback(URL(string: "\(scheme):/oauth2redirect?code=a&state=b")!))
    #expect(!e.acceptsCallback(URL(string: "\(scheme):/other?code=a")!))
    #expect(!e.acceptsCallback(URL(string: "\(scheme):/oauth2redirect#x")!))
    #expect(!e.acceptsCallback(URL(string: "org.evil:/oauth2redirect?code=a")!))
  }

}

@Suite struct GuestUpgradeTextTests {
  @Test func claimedMessageNamesAccountAndCount() {
    let status = GuestStatus(
      guestID: "g", state: .claimed, email: .verified, pendingCount: 0, publishedCount: 12,
      expiresAt: Date(), claimedAs: ClaimedAccount(displayName: "rosa_slc", osmID: 1))
    #expect(
      AppSession.claimedMessage(status)
        == "You're signed in as rosa_slc. Your 12 answers are on the map. New answers go straight on the map from now on.")
    #expect(AppSession.claimedMessage(nil).hasPrefix("You're signed in with OpenStreetMap. New answers"))
  }

  @Test func deadlineCopy() {
    let stops = Noun.from(match: ["highway": "bus_stop"])
    #expect(Wording.savedClosing(14, stops, on: Date()).hasPrefix("14 saved stops will be removed on "))
    #expect(Wording.savedClosing(1, stops, on: Date()).hasSuffix(" unless you finish on a computer."))
  }
}

@Suite struct GuestLinkTextTests {
  @Test func linkSentCopy() {
    #expect(Wording.linkSent(to: "a@b.org", until: nil) == "Sent to a@b.org. Check your email later.")
    #expect(Wording.linkSent(to: "a@b.org", until: Date()).hasPrefix("Sent to a@b.org. Check your email later. The link works until "))
  }

  @Test func nothingSavedIsCalmAndAsksForAnAnswerFirst() {
    let nothingSaved = MapRouletteError(.conflict, status: 409, reason: "nothing_saved")
    #expect(Wording.isNothingSaved(nothingSaved))
    #expect(!Wording.isInputError(nothingSaved))
    #expect(Wording.linkFailed(nothingSaved) == "Answer a place first, then we can send you the link.")
    #expect(Wording.linkFailed(nothingSaved, Noun(one: "stop", many: "stops"))
      == "Answer a stop first, then we can send you the link.")
    // A claimed guest is a different conflict.
    let claimed = MapRouletteError(.conflict, status: 409, reason: "guest_claimed")
    #expect(!Wording.isNothingSaved(claimed))
    #expect(Wording.linkFailed(claimed)
      == "These answers are already linked to an OpenStreetMap account. Sign in with it to see them.")
    // Any other conflict is not a promise about the map.
    #expect(Wording.linkFailed(MapRouletteError(.conflict, status: 409, reason: "other"))
      == "Couldn't send the link right now. Try again later.")
    #expect(!Wording.isNothingSaved(MapRouletteError(.validation, reason: "nothing_saved")))
  }

  /// design/copy-fixes-2026-10-11.md rows 2, 3, 5: no unmeasured time, no claim an email went out,
  /// no promise that phone sign-in puts saved answers on the map.
  @Test func noUnbackedPromises() {
    #expect(Wording.putOnMapIntro == "To put them on the map, finish on a computer. We can email you a link.")
    #expect(Wording.daySummarySaved(until: nil)
      == "They're saved for now. If we emailed you a link, open it on a computer to put them on the map.")
    // Phone sign-in claims the saved answers (B5), so row 5's original line is back.
    #expect(Wording.signInPutsOnMap == "Sign in now and your saved answers go on the map right away.")
    for text in [Wording.putOnMapIntro, Wording.daySummarySaved(until: Date()), Wording.signInPutsOnMap] {
      #expect(!text.contains("minutes"))
      #expect(!text.contains("email we sent"))
    }
  }

  /// After a phone sign-in with saved answers (B5).
  @Test func claimMessages() {
    let who = "You're signed in as rosa_slc. "
    func line(_ outcome: AppSession.ClaimOutcome) -> String { Wording.claimMessage(outcome, name: "rosa_slc") }
    #expect(line(.started(pending: 3, waiting: false)) == who + "Putting your 3 saved answers on the map\u{2026}")
    #expect(line(.started(pending: 1, waiting: false)) == who + "Putting your saved answer on the map\u{2026}")
    #expect(line(.started(pending: 0, waiting: false)) == who + "New answers go straight on the map from now on.")
    #expect(line(.started(pending: 2, waiting: true))
      == who + "Your 2 saved answers are now linked to your account. They'll go on the map later.")
    #expect(line(.started(pending: 1, waiting: true))
      == who + "Your saved answer is now linked to your account. It'll go on the map later.")
    #expect(line(.gone) == who + "We couldn't find your saved answers. "
      + "They may have expired, or they're linked to a different OpenStreetMap account.")
    #expect(line(.reauth) == "Sign in again so we can put your saved answers on the map.")
    #expect(line(.later) == who + "Your answers are still saved. We'll try again next time you open the app.")
    #expect(Wording.claimMessage(.later, name: nil).hasPrefix("You're signed in with OpenStreetMap. "))
    #expect(Wording.signedIn("rosa_slc") == "You're signed in as rosa_slc.")
  }

  @Test func dayNeverWraps() {
    let day = Wording.day(Date())
    #expect(!day.contains(" "))
    #expect(day.contains("\u{00A0}"))
  }
}

@Suite struct ProblemsTextTests {
  /// design/not-here-moved.md §7.
  @Test func notHereAndMovedCopy() {
    let stops = Noun.from(match: ["highway": "bus_stop"])
    #expect(Wording.problemsMessage == "Nothing here changes OpenStreetMap. The organizer checks every report.")
    #expect(Wording.notHereExplained(stops) == "You're at the spot and there's no stop.")
    #expect(Wording.movedTitle(stops) == "Where is the stop now?")
    #expect(Wording.reportMoved(31, stops) == "The stop has moved, about 30 m from where the map has it.")
    #expect(Wording.someoneReportedMoved(28, stops) == "Someone reported this stop moved, about 30 m.")
    #expect(Wording.movedFar(212, stops) == "That's 210 m away. If it's a different stop, use “It's not here” instead.")
  }

  /// Under 100 m to the nearest 5 m, then to the nearest 10 m.
  @Test func distancesAreRounded() {
    #expect([2, 31, 33, 97, 104, 156].map(Wording.roundedMeters) == [0, 30, 35, 95, 100, 160])
  }
}

@Suite struct PlaceSelectionTextTests {
  @Test func noOriginOffersManualChoiceWithoutInventingDistance() {
    let stops = Noun(one: "stop", many: "stops")
    #expect(Wording.nearest(stops, distance: nil, hasOrigin: false) == "Choose a stop")
    #expect(Wording.next(stops, distance: nil, hasOrigin: false) == "Choose another stop")
    // A leftover distance cannot restore a nearest claim without a valid origin.
    #expect(Wording.nearest(stops, distance: "100 m", hasOrigin: false) == "Choose a stop")
    #expect(Wording.next(.place, distance: "100 m north", hasOrigin: false) == "Choose another place")
  }

  @Test func realOriginKeepsNearestCopyEvenWhenPlaceHasNoDistance() {
    #expect(Wording.nearest(.place, distance: "100 m", hasOrigin: true) == "Nearest place · 100 m")
    #expect(Wording.nearest(.place, distance: nil, hasOrigin: true) == "Nearest place")
    #expect(Wording.next(.place, distance: "100 m north", hasOrigin: true) == "Next nearest place · 100 m north")
    #expect(Wording.next(.place, distance: nil, hasOrigin: true) == "Next nearest place")
  }

  @Test func locationNotesExplainManualMapAndListSelection() {
    let benches = Noun(one: "bench", many: "benches")
    #expect(Wording.locationUnavailable(benches, isOff: true)
      == "Location is off. Choose a bench on the map or in the list.")
    #expect(Wording.locationUnavailable(.place, isOff: false)
      == "Your location isn't available yet. Choose a place on the map or in the list.")
  }
}
