import Foundation
import MapRoulette
import Testing

@testable import MapRouletteChoice

/// Port of the Android demo's TaskWorkControllerTest: same states, same rules. Fake ops only.
@MainActor @Suite struct TaskWorkControllerTests {
  let challenge: Challenge
  init() async throws { challenge = try await makeChallenge() }

  func ops(deletion: Bool = false, _ reads: MapRouletteTask...) -> FakeOps {
    let ops = FakeOps(allowElementDeletion: deletion, challenge: challenge)
    ops.reads = reads.map(Read.task)
    return ops
  }

  func controller(_ ops: FakeOps, writer: Writer? = Writer(me: me, canEditOsm: true)) async -> TaskWorkController {
    let c = TaskWorkController(ops: ops, writer: writer)
    c.load(taskID)
    await c.idle()
    return c
  }

  func form(_ c: TaskWorkController) throws -> ChoiceForm { try #require(c.state.answering).1 }
  func task(_ c: TaskWorkController) throws -> MapRouletteTask { try #require(c.state.answering).0.task }
  func outcome(_ c: TaskWorkController, _ id: String) throws -> ChoiceOutcome {
    try #require(try form(c).outcomes.first { $0.id == id })
  }

  func answered(_ ops: FakeOps) async -> TaskWorkController {
    let c = await controller(ops)
    c.select(question: "backrest", option: "yes")
    c.perform(.answers(["backrest": "yes"]))
    await c.idle()
    return c
  }

  @Test func nonChoiceTasksAreNotAvailableAndNeverChecked() async throws {
    let tagFix: [String: Any] = ["meta": ["version": 2, "type": 1], "operations": [Any]()]
    for t in [
      try await makeTask(payload: nil), try await makeTask(payload: tagFix), try await makeTask(bundleID: 3),
      try await makeTask(status: 1),
    ] {
      let o = ops(t)
      let c = await controller(o)
      guard case .notAvailable(_, let reason) = c.state else { Issue.record("\(c.state.name)"); continue }
      #expect(!reason.isEmpty)
      #expect(o.calls == ["get", "challenge"])
    }
  }

  @Test func withoutWriterPreviewHasNoCheckAndNoWrites() async throws {
    let o = ops(try await makeTask())
    let c = await controller(o, writer: nil)
    guard case .preview = c.state else { Issue.record("\(c.state.name)"); return }
    c.perform(.skip)
    await c.idle()
    #expect(o.calls == ["get", "challenge"])
  }

  @Test func ineligibleAtOpenNoLongerNeedsAnswering() async throws {
    let o = ops(try await makeTask())
    o.check = { ChoiceEligibility(eligible: false, deleteAllowed: false, reason: .keyChanged) }
    let c = await controller(o)
    guard case .noLongerNeeded = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(c.changed, "the server now hides it: refresh the map")
    #expect(o.calls == ["get", "challenge", "check"])
  }

  @Test func failedCheckIsNotActionableUntilARetrySucceeds() async throws {
    let o = ops(try await makeTask(), try await makeTask())
    var checks = 0
    o.check = {
      checks += 1
      if checks == 1 { throw failure(.server, .choice(.osmUnavailable)) }
      return ChoiceEligibility(eligible: true, deleteAllowed: true, reason: nil)
    }
    let c = await controller(o)
    guard case .checkFailed = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(!c.changed, "not stale: the map keeps it")
    c.perform(.outcome(outcomes(try await makeTask())[0]))
    c.perform(.skip)
    await c.idle()
    #expect(o.submissions.isEmpty)
    c.load(taskID)  // Retry
    await c.idle()
    #expect(c.state.answering != nil)
  }

  @Test func deletionOffShowsGoneAsNotAnIssue() async throws {
    let c = await controller(ops(deletion: false, try await makeTask()))
    #expect(try form(c).outcomes.map(\.id) == ["not-a-bench", "gone", "too-hard"])
    let gone = try outcome(c, "gone")
    #expect(!gone.deletesElement)
    #expect(gone.resolution == .notAnIssue)
  }

  @Test func deletionOnShowsDeletingGoneWhenTheCheckAllowsIt() async throws {
    let c = await controller(ops(deletion: true, try await makeTask()))
    #expect(try outcome(c, "gone").deletesElement)
    #expect(try outcome(c, "gone").resolution == .fixed)
    #expect(try form(c).notDeletable.isEmpty)
  }

  @Test func undeletableGoneIsOfferedAsNotAnIssueWithoutDeletion() async throws {
    let inWay = ops(deletion: true, try await makeTask(), try await makeTask(status: 2, completedBy: me))
    inWay.check = { ChoiceEligibility(eligible: true, deleteAllowed: false, reason: nil) }
    inWay.submit = { _ in ChoiceResult(status: TaskStatus(code: 2), changesetID: nil) }
    let c = await controller(inWay)
    #expect(try form(c).outcomes.map(\.id) == ["not-a-bench", "gone", "too-hard"])
    let gone = try outcome(c, "gone")
    #expect(!gone.deletesElement)
    #expect(gone.resolution == .notAnIssue)
    #expect(try form(c).notDeletable == ["gone"])
    c.perform(.outcome(gone))
    await c.idle()
    guard case .outcome(let sent)? = inWay.submissions.first else { Issue.record("no submission"); return }
    #expect(!sent.deletesElement)
    #expect(c.state.done != nil)

    let off = ops(deletion: false, try await makeTask())
    off.check = { ChoiceEligibility(eligible: true, deleteAllowed: false, reason: nil) }
    #expect(try form(await controller(off)).notDeletable.isEmpty, "deletion off: plain Not an issue, nothing blocked")
  }

  @Test func answersAndCantTell() async throws {
    let c = await controller(ops(try await makeTask()))
    #expect(!c.offers(try task(c), try form(c), .answers([:])), "nothing answered")
    c.select(question: "backrest", option: "yes")
    c.select(question: "material", option: "wood")
    c.select(question: "material", option: nil)  // Can't tell
    c.select(question: "material", option: "granite")  // Not an option: ignored
    c.select(question: "color", option: "red")  // Not a question: ignored
    #expect(try form(c).answers == ["backrest": "yes"])
    #expect(c.offers(try task(c), try form(c), .answers(try form(c).answers)))
    #expect(!c.offers(try task(c), try form(c), .answers(["backrest": "maybe"])))
  }

  @Test func withoutOsmScopeEditsAreNotSentButPlainOutcomesAre() async throws {
    let o = ops(deletion: true, try await makeTask(), try await makeTask(status: 2, completedBy: me))
    let c = await controller(o, writer: Writer(me: me, canEditOsm: false))
    c.perform(.answers(["backrest": "yes"]))
    c.perform(.outcome(try outcome(c, "gone")))
    await c.idle()
    #expect(o.submissions.isEmpty)
    c.perform(.outcome(try outcome(c, "not-a-bench")))
    await c.idle()
    #expect(o.submissions.count == 1)
    #expect(c.state.done != nil)
  }

  @Test func submittedAnswersRereadAndReportTheChangeset() async throws {
    let o = ops(try await makeTask(), try await makeTask(status: 1, completedBy: me))
    let c = await controller(o)
    c.select(question: "backrest", option: "yes")
    c.perform(.answers(try form(c).answers))
    guard case .submitting = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(c.busy)
    await c.idle()
    let done = try #require(c.state.done)
    #expect(done.loaded.task.status?.code == 1)
    #expect(done.loaded.task.completedBy == me)
    #expect(done.changesetID == 99)
    #expect(o.submissions == [.answers(["backrest": "yes"])])
    #expect(o.calls == ["get", "challenge", "check", "submit", "get"])
    #expect(c.changed)
  }

  @Test func failedRereadAfterSuccessCanBeRecheckedWithoutResending() async throws {
    let o = ops(try await makeTask())
    o.reads += [.error(failure(.network)), .task(try await makeTask(status: 1, completedBy: me))]
    let c = await answered(o)
    #expect(try #require(c.state.done).readFailed)
    c.recheck()
    #expect(try #require(c.state.done).checking, "shows progress")
    c.recheck()  // Ignored while checking.
    await c.idle()
    let done = try #require(c.state.done)
    #expect(!done.readFailed)
    #expect(done.changesetID == 99)
    #expect(o.calls.filter { $0 == "submit" }.count == 1)
  }

  @Test func ineligibleAtSubmitNoLongerNeedsAnswering() async throws {
    let o = ops(try await makeTask())
    o.submit = { _ in throw failure(.conflict, .choice(.taskIneligible(reason: .keyChanged))) }
    guard case .noLongerNeeded = await answered(o).state else { Issue.record("not noLongerNeeded"); return }
  }

  @Test func uncertainResultsWaitForManualCheckAndAreNeverResent() async throws {
    for error in [
      failure(.network, .outcomeUnknown), failure(.conflict, .choice(.submissionPending)),
      failure(.server, .choice(.statusPending(changesetID: 55))),
    ] {
      let o = ops(try await makeTask(), try await makeTask(status: 1, completedBy: me, changesetID: 55))
      o.submit = { _ in throw error }
      let c = await answered(o)
      let pending = try #require(c.state.checkAgain)
      #expect(!pending.checking)
      #expect(!c.busy)
      #expect(o.calls == ["get", "challenge", "check", "submit"])
      c.perform(.answers(["backrest": "yes"]))  // Not allowed from this state.
      c.recheck()
      await c.idle()
      #expect(try #require(c.state.done).changesetID == 55)
      #expect(o.calls.filter { $0 == "submit" }.count == 1)
    }
  }

  @Test func uncertainEditIsOnlyResentManuallyAndIdentically() async throws {
    let o = ops(
      try await makeTask(), try await makeTask(lockedBy: me), try await makeTask(),
      try await makeTask(status: 1, completedBy: me))
    var attempts = 0
    o.submit = { _ in
      attempts += 1
      if attempts == 1 { throw failure(.network, .outcomeUnknown) }
      return ChoiceResult(status: TaskStatus(code: 1), changesetID: 77)
    }
    let c = await answered(o)
    #expect(try !#require(c.state.checkAgain).canResend, "no resend before a check")
    c.recheck()
    await c.idle()
    let held = try #require(c.state.checkAgain)
    #expect(held.message.contains("Not saved yet") && held.canResend)
    c.recheck()
    await c.idle()
    #expect(try #require(c.state.checkAgain).canResend, "an edit never falls back to editable answers")
    #expect(o.calls.filter { $0 == "submit" }.count == 1)
    c.resendSame()
    await c.idle()
    #expect(try #require(c.state.done).changesetID == 77)
    #expect(o.submissions == [.answers(["backrest": "yes"]), .answers(["backrest": "yes"])])
  }

  @Test func uncertainPlainOutcomeNotAppliedReturnsToAnswering() async throws {
    let o = ops(try await makeTask(), try await makeTask())
    o.submit = { _ in throw failure(.network, .outcomeUnknown) }
    let c = await controller(o)
    c.perform(.outcome(try outcome(c, "not-a-bench")))
    await c.idle()
    c.recheck()
    await c.idle()
    #expect(try #require(c.state.answering?.2).contains("weren't saved"))
  }

  @Test func submissionPendingNeverInvitesAnotherSubmission() async throws {
    let o = ops(try await makeTask(), try await makeTask())
    o.submit = { _ in throw failure(.conflict, .choice(.submissionPending)) }
    let c = await answered(o)
    c.recheck()
    await c.idle()
    let state = try #require(c.state.checkAgain)
    #expect(!state.canResend)
    #expect(state.message.contains("Pick another place"))
    c.resendSame()
    await c.idle()
    #expect(o.calls.filter { $0 == "submit" }.count == 1)
  }

  @Test func statusPendingKeepsTheChangesetAndOffersTheSameSubmission() async throws {
    let o = ops(try await makeTask(), try await makeTask(), try await makeTask(status: 1, completedBy: me))
    var attempts = 0
    o.submit = { _ in
      attempts += 1
      if attempts == 1 { throw failure(.server, .choice(.statusPending(changesetID: 55))) }
      return ChoiceResult(status: TaskStatus(code: 1), changesetID: 55)
    }
    let c = await answered(o)
    #expect(try #require(c.state.checkAgain).canResend)
    c.recheck()
    await c.idle()
    let pending = try #require(c.state.checkAgain)
    #expect(pending.message.contains("changeset 55") && !pending.message.contains("Not saved"))
    #expect(pending.changesetID == 55)
    c.resendSame()
    await c.idle()
    #expect(try #require(c.state.done).changesetID == 55)
  }

  @Test func differentStatusWithoutAnotherCompleterIsNotByOther() async throws {
    let o = ops(try await makeTask(), try await makeTask(status: 2, completedBy: me))
    o.submit = { _ in throw failure(.network, .outcomeUnknown) }
    let c = await answered(o)
    c.recheck()
    await c.idle()
    #expect(try !#require(c.state.done).byOther)
  }

  @Test func failedCheckAgainReadStaysPending() async throws {
    let o = ops(try await makeTask())
    o.reads.append(.error(failure(.network)))
    o.submit = { _ in throw failure(.network, .outcomeUnknown) }
    let c = await answered(o)
    c.recheck()
    await c.idle()
    #expect(try #require(c.state.checkAgain).message.contains("Couldn't check whether"))
  }

  @Test func osmPermissionProblemsAskToSignInAgain() async throws {
    for (problem, kind) in [
      (WriteProblem.choice(.osmReauthRequired), ErrorKind.authentication),
      (.choice(.osmScopeRequired), .permission), (.insufficientScope, .permission),
    ] {
      let o = ops(try await makeTask())
      o.submit = { _ in throw failure(kind, problem) }
      guard case .signInRequired(_, let reason) = await answered(o).state else {
        Issue.record("not signInRequired")
        continue
      }
      #expect(reason.contains("Sign in again"))
    }
  }

  @Test func osmUnavailableExplainsAndKeepsTheAnswers() async throws {
    let o = ops(try await makeTask())
    o.submit = { _ in throw failure(.server, .choice(.osmUnavailable)) }
    let c = await answered(o)
    #expect(try form(c).answers == ["backrest": "yes"])
    #expect(try #require(c.state.answering?.2).contains("Your answers are kept"))
  }

  @Test func elementInUseOffersTheSameOutcomeWithoutDeletion() async throws {
    let o = ops(deletion: true, try await makeTask(), try await makeTask(status: 2, completedBy: me))
    o.submit = { submission in
      if case .outcome(let outcome) = submission, outcome.deletesElement {
        throw failure(.conflict, .choice(.elementInUse))
      }
      return ChoiceResult(status: TaskStatus(code: 2), changesetID: nil)
    }
    let c = await controller(o)
    c.perform(.outcome(try outcome(c, "gone")))
    await c.idle()
    guard case .elementInUse(_, _, let refused) = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(refused.id == "gone")
    c.sendWithoutDeletion()
    await c.idle()
    guard case .outcome(let plain)? = o.submissions.last else { Issue.record("no outcome"); return }
    #expect(plain.id == "gone" && !plain.deletesElement && plain.resolution == .notAnIssue)
    #expect(try #require(c.state.done).changesetID == nil)
    #expect(o.submissions.count == 2)
  }

  @Test func lockedByOtherAtStartIsTakenByOther() async throws {
    let o = ops(try await makeTask())
    o.submit = { _ in throw failure(.permission, .lockedByOtherUser(message: "locked")) }
    guard case .takenByOther = await answered(o).state else { Issue.record("not takenByOther"); return }
  }

  @Test func staleOwnLockOffersUserRetry() async throws {
    let o = ops(try await makeTask(), try await makeTask(status: 1, completedBy: me))
    var attempts = 0
    o.submit = { _ in
      attempts += 1
      if attempts == 1 {
        throw failure(.conflict, .alreadyHoldingTask(lockedTaskID: try TaskID(9), challengeID: nil, challengeName: nil, startedAt: nil))
      }
      return ChoiceResult(status: TaskStatus(code: 1), changesetID: 99)
    }
    let c = await answered(o)
    guard case .staleOwnLock(_, _, let action, let held) = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(held.value == 9)
    c.perform(action)
    await c.idle()
    #expect(c.state.done != nil)
  }

  @Test func definiteFailuresReturnToAnsweringWithANotice() async throws {
    for error in [
      failure(.conflict, .lockLost), failure(.authentication), failure(.rateLimit),
      failure(.http, .choice(.invalidSubmission(detail: nil))), failure(.validation),
    ] {
      let o = ops(try await makeTask())
      o.submit = { _ in throw error }
      let c = await answered(o)
      let notice = try #require(c.state.answering?.2).lowercased()
      #expect(notice.contains("nothing was saved") || notice.contains("wasn't saved"), "\(error)")
      #expect(try form(c).answers == ["backrest": "yes"])
    }
  }

  @Test func invalidTransitionRereadsAndIsNotAvailable() async throws {
    let o = ops(try await makeTask(), try await makeTask(status: 1, completedBy: other))
    o.submit = { _ in throw failure(.conflict, .invalidTransition) }
    guard case .notAvailable(let loaded, let reason) = await answered(o).state else {
      Issue.record("not notAvailable")
      return
    }
    #expect(loaded.task.status?.code == 1)
    #expect(reason.contains("can't be answered right now"))
  }

  @Test func unknownSkipIsNeverResent() async throws {
    let o = ops(try await makeTask())
    o.skip = { throw failure(.network, .outcomeUnknown) }
    let c = await controller(o)
    c.perform(.skip)
    await c.idle()
    guard case .skipped(_, let uncertain) = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(uncertain)
    c.perform(.skip)
    await c.idle()
    #expect(o.calls.filter { $0 == "skip" }.count == 1)
    #expect(c.changed)
  }

  @Test func cancelledControllerLetsTheWriteFinishButDiscardsItsResult() async throws {
    let o = ops(try await makeTask())
    let gate = AsyncStream<Void>.makeStream()
    var finished = false
    o.submit = { _ in
      for await _ in gate.stream { break }
      finished = true
      return ChoiceResult(status: TaskStatus(code: 1), changesetID: 99)
    }
    let c = await controller(o)
    c.select(question: "backrest", option: "no")
    c.perform(.answers(["backrest": "no"]))
    c.cancel()  // Screen closed or account switched while the submission is in flight.
    gate.continuation.yield()
    await c.idle()
    #expect(finished)
    guard case .submitting = c.state else { Issue.record("late result shown: \(c.state.name)"); return }
    #expect(o.calls == ["get", "challenge", "check", "submit"])
  }

  @Test func oneDeletionClientSendsGoneWithAndWithoutDeletion() async throws {
    actor Recorder: Transport {
      var bodies: [String] = []
      func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.method == .post {
          bodies.append(String(decoding: request.body ?? Data(), as: UTF8.self))
          return HTTPResponse(status: 200, body: Data(#"{"status":2,"changesetId":null}"#.utf8))
        }
        return HTTPResponse(
          status: 200,
          body: Data(
            #"{"id":42,"parent":1,"name":"node/123","instruction":"","status":0,"geometries":{"type":"FeatureCollection","features":[]},"lockPrimaryTaskId":42,"lockBundledTasks":[]}"#
              .utf8))
      }
    }
    let recorder = Recorder()
    let clientOps = ClientTaskOps(
      MapRouletteClient(
        environment: .staging, transport: recorder, allowElementDeletion: true, accessToken: { "token" }))
    let t = try await makeTask()
    let gone = try #require(clientOps.choiceOutcomes(t).first { $0.id == "gone" })
    let notABench = try #require(clientOps.choiceOutcomes(t).first { $0.id == "not-a-bench" })
    _ = try await clientOps.submitChoice(t, .outcome(notABench))
    _ = try await clientOps.submitChoice(t, .outcome(try #require(TaskWorkController.withoutDeletion(gone))))
    _ = try await clientOps.submitChoice(t, .outcome(gone))
    _ = try await clientOps.submitChoice(t, .answers(["backrest": "no"]))
    #expect(
      await recorder.bodies == [
        #"{"outcome":"not-a-bench"}"#, #"{"outcome":"gone"}"#, #"{"outcome":"gone","delete":true}"#,
        #"{"answers":{"backrest":"no"}}"#,
      ])
  }

  // MARK: Guests (deferred sign-up)

  @Test func guestAnswersAreSavedForLaterWithoutLocking() async throws {
    let o = ops(try await makeTask())
    let c = await controller(o, writer: .guestWriter)
    c.select(question: "backrest", option: "yes")
    c.perform(.answers(["backrest": "yes"]))
    await c.idle()
    let done = try #require(c.state.done)
    #expect(done.savedForLater && !done.byOther && done.changesetID == nil)
    // Checked like any participant, then one pending write: no start, no status write, no re-read.
    #expect(o.calls == ["get", "challenge", "check", "pending"])
    #expect(o.submissions == [.answers(["backrest": "yes"])])
    #expect(c.changed)
  }

  @Test func guestSkipOnlyMovesOn() async throws {
    let o = ops(try await makeTask())
    let c = await controller(o, writer: .guestWriter)
    c.perform(.skip)
    await c.idle()
    guard case .skipped(_, let uncertain) = c.state, !uncertain else { Issue.record("\(c.state.name)"); return }
    #expect(o.calls == ["get", "challenge", "check"])
  }

  @Test func guestFailuresKeepTheAnswers() async throws {
    let cases: [(MapRouletteError, String)] = [
      (MapRouletteError(.network, problem: .outcomeUnknown), "connect"),
      (MapRouletteError(.rateLimit, status: 429, reason: "pending_limit"), "Finish on a computer"),
      (MapRouletteError(.authentication, status: 401, reason: "invalid_token"), "Try again"),
    ]
    for (error, words) in cases {
      let o = ops(try await makeTask())
      o.pending = { _ in throw error }
      let c = await controller(o, writer: .guestWriter)
      c.select(question: "backrest", option: "yes")
      c.perform(.answers(["backrest": "yes"]))
      await c.idle()
      let notice = try #require(c.state.answering?.2, "\(error)")
      #expect(notice.contains(words), "\(error)")
      #expect(try form(c).answers == ["backrest": "yes"])
    }
  }

  @Test func guestAnswerForACompletedTaskIsNotAvailable() async throws {
    let o = ops(try await makeTask(), try await makeTask(status: 1, completedBy: other))
    o.pending = { _ in throw MapRouletteError(.conflict, status: 409, reason: "task_completed") }
    let c = await controller(o, writer: .guestWriter)
    c.perform(.answers(["backrest": "yes"]))
    await c.idle()
    guard case .notAvailable = c.state else { Issue.record("\(c.state.name)"); return }
  }

  @Test func guestIneligibleAnswerIsNoLongerNeeded() async throws {
    let o = ops(try await makeTask())
    o.pending = { _ in throw MapRouletteError(.conflict, problem: .choice(.taskIneligible(reason: .keyChanged))) }
    let c = await controller(o, writer: .guestWriter)
    c.perform(.answers(["backrest": "yes"]))
    await c.idle()
    guard case .noLongerNeeded = c.state else { Issue.record("\(c.state.name)"); return }
  }

  /// The pending route holds answers only with `liveMissingQuestions` (422 `unsupported_task`).
  @Test func guestsNeedAnAccountWithoutLiveMissingQuestions() async throws {
    var payload = bench
    payload["liveMissingQuestions"] = nil
    let guest = await controller(ops(try await makeTask(payload: payload)), writer: .guestWriter)
    guard case .accountNeeded = guest.state else { Issue.record("\(guest.state.name)"); return }
    #expect(Wording.accountNeededTitle(Noun.place) == "Sign in to check this place")
    #expect(Wording.accountNeeded(Noun.place) == "This place needs an OpenStreetMap account. Any answers you've saved stay saved.")
    // A signed-in participant answers it as before.
    let signedIn = await controller(ops(try await makeTask(payload: payload)))
    #expect(signedIn.state.answering != nil)
  }

  @Test func guestUnsupportedTaskOnSaveNeedsAnAccount() async throws {
    for error in [
      MapRouletteError(.validation, status: 422, reason: "unsupported_task"),
      MapRouletteError(.validation, status: 422, problem: .choice(.unsupportedTask)),
    ] {
      let o = ops(try await makeTask())
      o.pending = { _ in throw error }
      let c = await controller(o, writer: .guestWriter)
      c.perform(.answers(["backrest": "yes"]))
      await c.idle()
      guard case .accountNeeded = c.state else { Issue.record("\(c.state.name)"); continue }
    }
  }

  // MARK: Not here / moved (design/not-here-moved.md)

  @Test func reportsAreOfferedOnEveryChoiceTaskAndNeverEditOsm() async throws {
    let spot = try MovedLocation(latitude: 40.7612, longitude: -111.8902, source: .tap)
    for action in [ChoiceAction.outcome(.notHere), .moved(spot)] {
      let o = ops(try await makeTask(), try await makeTask(status: 6, completedBy: me))
      let c = await controller(o, writer: Writer(me: me, canEditOsm: false))
      #expect(c.offers(try task(c), try form(c), action))
      #expect(!action.editsOsm && action.isReport)
      c.perform(action)
      await c.idle()
      let done = try #require(c.state.done)
      #expect(o.submissions == [action.submission!])
      #expect(o.calls == ["get", "challenge", "check", "submit", "get"])
      #expect(done.report == (action == .outcome(.notHere) ? .notHere : .moved(latitude: 40.7612, longitude: -111.8902)))
    }
  }

  @Test func movedTooFarReturnsToAnsweringWithTheReason() async throws {
    let o = ops(try await makeTask())
    o.submit = { _ in throw MapRouletteError(.validation, problem: .choice(.movedTooFar)) }
    let c = await controller(o)
    c.perform(.moved(try MovedLocation(latitude: 40.8, longitude: -111.8, source: .tap)))
    await c.idle()
    #expect(c.state.answering?.2 == "That's too far to be the same place.")
  }

  @Test func guestReportsAreSavedForLater() async throws {
    let o = ops(try await makeTask())
    let c = await controller(o, writer: .guestWriter)
    c.perform(.outcome(.notHere))
    await c.idle()
    #expect(try #require(c.state.done).savedForLater)
    #expect(o.submissions == [.outcome(.notHere)])
    #expect(o.calls == ["get", "challenge", "check", "pending"])
  }

  @Test func previewReportsSendNothing() async throws {
    let o = ops(try await makeTask())
    let c = TaskWorkController(ops: o, writer: nil, previewing: true)
    c.load(taskID)
    await c.idle()
    c.perform(.moved(try MovedLocation(latitude: 40.7612, longitude: -111.8902, source: .here)))
    await c.idle()
    guard case .previewSaved = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(o.submissions.isEmpty)
  }

  @Test func reportedPlacesCountForThePersonButStayOpen() throws {
    let store = CampaignStore(defaults: UserDefaults(suiteName: "reports-\(UUID())")!)
    store.recordChecked(1, task: 42, report: .notHere)
    store.recordChecked(1, task: 42, report: .notHere)
    #expect(store.checkedToday(1) == 1)
    #expect(store.justReported == [42: .notHere])
    #expect(store.justDone.isEmpty)
  }

  /// not-here-moved.md §3.3: an outcome follows its status. Status 6 (Woodbine's "There's no
  /// door", Too hard) needs another look; status 2 counts as checked.
  @Test func statusSixOutcomesNeedAnotherLook() async throws {
    var seen: Set<TaskResolution> = []
    for id in ["not-a-bench", "too-hard"] {
      let o = ops(try await makeTask(), try await makeTask(status: 6, completedBy: me))
      let c = await controller(o)
      let outcome = try outcome(c, id)
      seen.insert(outcome.resolution)
      c.perform(.outcome(outcome))
      await c.idle()
      let done = try #require(c.state.done)
      #expect(done.report == nil)
      #expect(done.flagged == (outcome.resolution == .tooHard), "\(id)")
    }
    #expect(seen == [.notAnIssue, .tooHard])
  }

  @Test func flaggedPlacesCountForThePersonButStayOpen() throws {
    let store = CampaignStore(defaults: UserDefaults(suiteName: "flagged-\(UUID())")!)
    store.recordChecked(1, task: 42, flagged: true)
    store.recordChecked(1, task: 42, flagged: true)
    store.recordChecked(1, task: 43, report: .notHere)
    #expect(store.checkedToday(1) == 2)
    #expect(store.justFlagged == [42])
    #expect(store.justDone.isEmpty)
    #expect(store.lookAgain(store.justReported) == [42, 43])
  }
}
