import Foundation
import MapRoulette
import os

/// The SDK operations the task screen uses; a fake replaces it in unit tests.
protocol TaskOps: Sendable {
  /// Outcomes decoded with the client's deletion setting (the SDK rejects others, except their
  /// `withoutDeletion()` form).
  func choiceOutcomes(_ task: MapRouletteTask) -> [ChoiceOutcome]
  func getTask(_ id: TaskID) async throws -> MapRouletteTask
  func getChallenge(_ task: MapRouletteTask) async throws -> Challenge
  func checkChoice(_ id: TaskID) async throws -> ChoiceEligibility
  func submitChoice(_ task: MapRouletteTask, _ submission: ChoiceSubmission) async throws -> ChoiceResult
  func skipTask(_ id: TaskID) async throws
  /// A guest's answers, stored on the server until the guest puts them on the map.
  func submitPendingChoice(_ task: MapRouletteTask, _ submission: ChoiceSubmission) async throws -> PendingChoice
}

/// Bound to one account's client: a controller never sends through a later account's client.
/// The client's deletion setting is the cap; "gone" without deletion (after `element_in_use`,
/// or when the check disallows deletion) is sent as `outcome.withoutDeletion()`.
struct ClientTaskOps: TaskOps {
  let client: MapRouletteClient

  init(_ client: MapRouletteClient) { self.client = client }

  func choiceOutcomes(_ task: MapRouletteTask) -> [ChoiceOutcome] { client.choiceOutcomes(task) }
  func getTask(_ id: TaskID) async throws -> MapRouletteTask { try await client.getTask(id) }
  func getChallenge(_ task: MapRouletteTask) async throws -> Challenge {
    try await client.getChallenge(task.challengeID)
  }
  func checkChoice(_ id: TaskID) async throws -> ChoiceEligibility { try await client.checkChoice(id) }
  func submitChoice(_ task: MapRouletteTask, _ submission: ChoiceSubmission) async throws -> ChoiceResult {
    try await client.submitChoice(task, submission)
  }
  func skipTask(_ id: TaskID) async throws { try await client.skipTask(id) }
  func submitPendingChoice(_ task: MapRouletteTask, _ submission: ChoiceSubmission) async throws -> PendingChoice {
    try await client.submitPendingChoice(task, submission)
  }
}

/// Preview mode's ops (design/preview-mode.md §2): reads pass through; every write is refused
/// here, before the SDK, so a preview can't lock, skip or answer even if a screen asks it to.
struct PreviewTaskOps: TaskOps {
  let reads: any TaskOps

  func choiceOutcomes(_ task: MapRouletteTask) -> [ChoiceOutcome] { reads.choiceOutcomes(task) }
  func getTask(_ id: TaskID) async throws -> MapRouletteTask { try await reads.getTask(id) }
  func getChallenge(_ task: MapRouletteTask) async throws -> Challenge { try await reads.getChallenge(task) }
  func checkChoice(_ id: TaskID) async throws -> ChoiceEligibility { try await reads.checkChoice(id) }
  func submitChoice(_ task: MapRouletteTask, _ submission: ChoiceSubmission) async throws -> ChoiceResult {
    throw MapRouletteError(.permission)
  }
  func skipTask(_ id: TaskID) async throws { throw MapRouletteError(.permission) }
  func submitPendingChoice(_ task: MapRouletteTask, _ submission: ChoiceSubmission) async throws -> PendingChoice {
    throw MapRouletteError(.permission)
  }
}

enum ChoiceAction: Equatable, Sendable {
  /// Question id → option id; questions left out are "Can't tell".
  case answers([String: String])
  /// A campaign outcome, Too hard, or the built-in "It's not here" (`ChoiceOutcome.notHere`).
  case outcome(ChoiceOutcome)
  /// The built-in "It's moved", with the spot the participant picked.
  case moved(MovedLocation)
  case skip

  /// Whether the action edits OpenStreetMap (needs `osm:tagfix`).
  var editsOsm: Bool {
    switch self {
    case .answers: true
    case .outcome(let outcome): outcome.deletesElement
    case .moved, .skip: false
    }
  }

  /// "It's not here" or "It's moved" (design/not-here-moved.md): a report for the organizer.
  var isReport: Bool {
    switch self {
    case .outcome(let outcome): outcome == .notHere
    case .moved: true
    case .answers, .skip: false
    }
  }

  /// What the SDK sends; nil for a skip.
  var submission: ChoiceSubmission? {
    switch self {
    case .answers(let answers): .answers(answers)
    case .outcome(let outcome): .outcome(outcome)
    case .moved(let location): .moved(location)
    case .skip: nil
    }
  }
}

/// `me` is the signed-in MapRoulette user id; `canEditOsm`: the grant includes `osm:tagfix`.
/// A guest (`me` 0) saves answers on the server; they reach OSM once the guest finishes signing up.
struct Writer: Sendable {
  let me: Int64
  let canEditOsm: Bool
  var guest = false

  static let guestWriter = Writer(me: 0, canEditOsm: true, guest: true)
}

/// The questions of a valid choice task.
struct ChoiceWork: Equatable, Sendable {
  let element: OSMElementRef
  let questions: [ChoiceQuestion]

  init(element: OSMElementRef, questions: [ChoiceQuestion]) {
    self.element = element
    self.questions = questions
  }

  init?(_ work: TaskWork) {
    guard case .choice(let element, _, let questions, _) = work else { return nil }
    self.element = element
    self.questions = questions
  }
}

/// The questions and offered outcomes of an eligible task, plus the user's current answers.
struct ChoiceForm: Equatable, Sendable {
  let work: ChoiceWork
  let outcomes: [ChoiceOutcome]
  var answers: [String: String] = [:]
  /// Ids of delete outcomes offered without deletion because the element cannot be deleted
  /// (it is in a way or relation); they record Not an issue.
  var notDeletable: Set<String> = []
}

/// A task and its challenge, as last read.
struct LoadedTask: Sendable {
  let task: MapRouletteTask
  let challenge: Challenge
}

/// Screen states (docs/design/task-completion.md §11, docs/design/mobile-choice-challenges.md §7 app rules).
enum TaskScreen: Sendable {
  enum Pending: Sendable { case unknown, submissionPending, statusPending }

  /// `task` is the fresh read after the write, or the pre-write task when `readFailed`.
  /// `byOther`: a check found someone else's result; this user's submission was not recorded.
  struct Done: Sendable {
    var loaded: LoadedTask
    var action: ChoiceAction
    var me: Int64
    var changesetID: Int64?
    var readFailed: Bool
    var byOther = false
    var checking = false
    /// A guest's answers: saved on the server, not on the map yet. The task itself is unchanged.
    var savedForLater = false
    /// A guest's answers kept on this phone after a failed save; they send by themselves later
    /// (design/offline-copy.md). Not counted until the server has them.
    var waiting = false

    /// The report this records, for lists and maps: not here, or moved to the picked spot.
    var report: TaskReport? {
      switch action {
      case .outcome(let outcome) where outcome == .notHere: .notHere
      case .moved(let spot): .moved(latitude: spot.latitude, longitude: spot.longitude)
      default: nil
      }
    }
    /// Another outcome that sets status 6 (a campaign's "There's no door", Too hard): needs another
    /// look like a report, but records no report. Status 2 outcomes count as checked.
    var flagged: Bool {
      guard report == nil, case .outcome(let outcome) = action else { return false }
      return outcome.resolution == .tooHard
    }
  }
  /// The submission may still land (unknown outcome, pending submission or status). Never resent
  /// automatically; the user re-reads with Check again. `canResend`: the user may send the
  /// identical submission again (confirmed), which the server resumes without a second upload.
  struct CheckAgain: Sendable {
    var loaded: LoadedTask
    var form: ChoiceForm
    var action: ChoiceAction
    var message: String
    var changesetID: Int64?
    var checking: Bool
    var pending: Pending = .unknown
    var canResend = false
  }

  case loading
  /// `retry` false: trying again won't help (the place is gone).
  case loadFailed(String, retry: Bool = true)
  /// Not a choice task, or nothing left to do: read-only, "Not available on mobile".
  case notAvailable(LoadedTask, reason: String)
  /// Signed out or read-only: the questions without actions. No eligibility check is made.
  case preview(LoadedTask, ChoiceWork)
  /// Campaign preview mode: what would have been sent. Nothing was.
  case previewSaved(LoadedTask, ChoiceForm, ChoiceAction)
  /// Ineligible (stale) at open or submit (`onSave`). No actions.
  case noLongerNeeded(LoadedTask, IneligibleReason?, onSave: Bool = false)
  /// The eligibility check failed (network, OSM unavailable, …): not actionable until a retry succeeds.
  case checkFailed(LoadedTask)
  /// `notice` explains why the user is back here; the answers are kept.
  case answering(LoadedTask, ChoiceForm, notice: String?)
  case submitting(LoadedTask, ChoiceForm, ChoiceAction)
  case done(Done)
  /// A skip leaves the status unchanged. `uncertain`: the outcome is unknown and it was not resent.
  case skipped(LoadedTask, uncertain: Bool)
  case takenByOther(LoadedTask)
  case staleOwnLock(LoadedTask, ChoiceForm, ChoiceAction, lockedTaskID: TaskID)
  case checkAgain(CheckAgain)
  /// OSM re-consent or a missing scope. Nothing was changed.
  case signInRequired(LoadedTask, reason: String)
  /// A guest on a task the server won't hold answers for (no `liveMissingQuestions`, or 422
  /// `unsupported_task` on the pending route): sign in to answer it, or move on.
  case accountNeeded(LoadedTask)
  /// A delete was refused (the node is in a way or relation); the same outcome may be sent without deletion.
  case elementInUse(LoadedTask, ChoiceForm, ChoiceOutcome)
  /// The server has saving switched off (403 mobile_writes_disabled on the choice check): nothing
  /// can be checked; back to the campaign.
  case writesPaused(LoadedTask)

  var loaded: LoadedTask? {
    switch self {
    case .loading, .loadFailed: nil
    case .notAvailable(let l, _), .preview(let l, _), .noLongerNeeded(let l, _, _), .checkFailed(let l),
      .answering(let l, _, _), .submitting(let l, _, _), .skipped(let l, _), .takenByOther(let l),
      .staleOwnLock(let l, _, _, _), .signInRequired(let l, _), .accountNeeded(let l), .elementInUse(let l, _, _),
      .previewSaved(let l, _, _), .writesPaused(let l):
      l
    case .done(let d): d.loaded
    case .checkAgain(let c): c.loaded
    }
  }
}

/// Choice task screen logic with late locking. Opening checks eligibility (read-only for the
/// caller); a submission runs the SDK's start → POST choice → release-on-failure off the main
/// actor. Writes finish even if the controller is cancelled (so the SDK can release its lock), but
/// their results are then discarded. An edit is never resent: uncertain results wait for a manual
/// re-read.
@MainActor @Observable final class TaskWorkController {
  private(set) var state: TaskScreen = .loading
  /// True once a write or a stale finding may have changed the task, so maps and lists should refresh.
  private(set) var changed = false

  @ObservationIgnored private var ops: any TaskOps
  @ObservationIgnored private var writer: Writer?
  /// Campaign preview mode (design/preview-mode.md): every question is asked, with no eligibility
  /// check, and nothing is ever sent. There is no writer and the ops refuse writes.
  @ObservationIgnored let previewing: Bool
  @ObservationIgnored private var job: Task<Void, Never>?
  @ObservationIgnored private var discarded = false
  @ObservationIgnored private let log = Logger(subsystem: "lol.osm.maproulette.choice", category: "task")

  /// What the campaign checks ("stop", "bench"), for participant messages.
  @ObservationIgnored private let noun: Noun
  /// Keeps a guest's answer on this phone when its save fails for lack of connection (O1).
  @ObservationIgnored private let keepOnPhone: (@MainActor (GuestOutbox.Entry) -> Void)?
  /// The phone's copy of a place and its campaign (O2), opened when there is no connection.
  @ObservationIgnored private let kept: (@MainActor (TaskID) -> (MapRouletteTask, Challenge)?)?
  /// This phone could answer as a guest but hasn't registered yet (it had no signal to): in a dead
  /// spot it answers the kept copy as one, and registers when the answers send (Tess, Android #45).
  @ObservationIgnored private var unregisteredGuest: Bool
  /// How long a place may load before a guest gets the phone's copy instead (CampaignCache.slowAfter).
  @ObservationIgnored private let keptAfter: Duration?
  @ObservationIgnored private var keptTimer: Task<Void, Never>?
  /// The save in flight was already shown as waiting on the phone.
  @ObservationIgnored private var keptEarly = false

  init(
    ops: any TaskOps, writer: Writer?, noun: Noun = .place, previewing: Bool = false,
    keepOnPhone: (@MainActor (GuestOutbox.Entry) -> Void)? = nil,
    kept: (@MainActor (TaskID) -> (MapRouletteTask, Challenge)?)? = nil, unregisteredGuest: Bool = false,
    keptAfter: Duration? = nil
  ) {
    self.ops = previewing ? PreviewTaskOps(reads: ops) as any TaskOps : ops
    self.writer = previewing ? nil : writer
    self.noun = noun
    self.previewing = previewing
    self.keepOnPhone = keepOnPhone
    self.kept = kept
    self.unregisteredGuest = unregisteredGuest
    self.keptAfter = keptAfter
  }

  var busy: Bool {
    switch state {
    case .submitting: true
    case .checkAgain(let c): c.checking
    default: false
    }
  }

  /// In preview, as if it could: the organizer sees every answer the campaign offers.
  var canEditOsm: Bool { previewing || writer?.canEditOsm == true }

  /// Waits for the current operation, including a write that outlives `cancel()`. For tests.
  func idle() async { await job?.value }

  /// `keptWithin` shortens the wait before the kept copy, when part of it was spent already.
  func load(_ id: TaskID, keptWithin: Duration? = nil) {
    if busy || discarded { return }
    job?.cancel()
    keptTimer?.cancel()
    state = .loading
    let job = Task {
      let next: TaskScreen
      do {
        let task = try await ops.getTask(id)
        let challenge = try await ops.getChallenge(task)
        next = await opened(LoadedTask(task: task, challenge: challenge))
      } catch let error as MapRouletteError where error.kind == .notFound {
        // Gone: trying again won't bring it back, and lists and maps drop it (Iris, offline-copy.md).
        if !Task.isCancelled { changed = true }
        next = .loadFailed(Wording.goneOnOpen(noun), retry: false)
      } catch {
        next = openedKept(id, error) ?? .loadFailed(Self.readError(error, noun))
      }
      publish(next)
    }
    self.job = job
    if keptPossible, let delay = keptWithin ?? keptAfter {
      keptTimer = Task {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, !discarded, case .loading = state, let screen = keptScreen(id) else { return }
        // The answer is checked when it's sent, so the slow load isn't needed any more.
        job.cancel()
        state = screen
      }
    }
  }

  /// Opened before this phone's guest registration came back (a dead spot that hangs).
  var awaitsRegistration: Bool { unregisteredGuest && !previewing && (writer == nil || writer?.guest == true) }

  /// The registration landed: carry on with the guest's client instead of starting over, so
  /// answers in progress stay. True when the screen should load again (it had nothing to answer).
  func registered(ops: any TaskOps) -> Bool {
    self.ops = ops
    unregisteredGuest = false
    if writer == nil { writer = .guestWriter }
    switch state {
    case .answering, .submitting, .done: return false
    default: return true
    }
  }

  /// No connection: a guest answers the phone's copy (O2), with no eligibility check (there is
  /// none to reach). The answer waits on the phone, and the server checks it when it's sent.
  private func openedKept(_ id: TaskID, _ error: any Error) -> TaskScreen? {
    CampaignCache.isOffline(error) ? keptScreen(id) : nil
  }

  /// A guest (or a phone that can become one) with the campaign kept on the phone.
  private var keptPossible: Bool {
    !previewing && keepOnPhone != nil && kept != nil && (writer?.guest == true || (writer == nil && unregisteredGuest))
  }

  private func keptScreen(_ id: TaskID) -> TaskScreen? {
    guard keptPossible, let found = kept?(id) else { return nil }
    let task = found.0
    let loaded = LoadedTask(task: task, challenge: found.1)
    guard task.mobileSupport() == .inPlace, let work = ChoiceWork(task.work()) else {
      return .notAvailable(loaded, reason: TaskText.unavailableReason(task))
    }
    writer = .guestWriter
    return .answering(loaded, Self.form(work, outcomes: ops.choiceOutcomes(task), deleteAllowed: false), notice: nil)
  }

  private func publish(_ next: TaskScreen) {
    if Task.isCancelled || discarded { return }
    state = next
  }

  private func opened(_ loaded: LoadedTask) async -> TaskScreen {
    let task = loaded.task
    guard task.mobileSupport() == .inPlace,
      let work = ChoiceWork(task.work())
    else { return .notAvailable(loaded, reason: TaskText.unavailableReason(task)) }
    if previewing {
      // Every question, every outcome: the draft is tried at a desk, not against current OSM.
      return .answering(
        loaded, Self.form(work, outcomes: ops.choiceOutcomes(task), deleteAllowed: true), notice: nil)
    }
    guard let writer else { return .preview(loaded, work) }
    let eligibility: ChoiceEligibility
    do {
      eligibility = try await ops.checkChoice(task.id)
    } catch let error as MapRouletteError where error.problem == .writesPaused {
      return .writesPaused(loaded)
    } catch {
      // Not checked: not offered (spec §5a). Type only: messages may carry server text.
      log.debug("Choice check for task \(task.id.value) failed: \(String(describing: type(of: error)), privacy: .public)")
      return .checkFailed(loaded)
    }
    if !eligibility.eligible {
      if !Task.isCancelled { changed = true }  // The server now hides it from discovery.
      return .noLongerNeeded(loaded, eligibility.reason)
    }
    let current = eligibility.questionIDs.map { ids in
      ChoiceWork(
        element: work.element, questions: work.questions.filter { ids.contains($0.id) })
    } ?? work
    return .answering(
      loaded,
      Self.form(current, outcomes: ops.choiceOutcomes(task), deleteAllowed: eligibility.deleteAllowed),
      notice: nil)
  }

  /// `optionID` nil means "Can't tell": the question is left out of the submission.
  func select(question questionID: String, option optionID: String?) {
    guard case .answering(let loaded, var form, let notice) = state,
      let question = form.work.questions.first(where: { $0.id == questionID })
    else { return }
    if let optionID {
      guard question.options.contains(where: { $0.id == optionID }) else { return }
      form.answers[questionID] = optionID
    } else {
      form.answers[questionID] = nil
    }
    state = .answering(loaded, form, notice: notice)
  }

  /// Whether `action` may be offered on `form`'s task for this writer.
  func offers(_ task: MapRouletteTask, _ form: ChoiceForm, _ action: ChoiceAction) -> Bool {
    if !previewing {
      guard let writer else { return false }
      if action.editsOsm && !writer.canEditOsm { return false }
    }
    switch action {
    case .answers(let answers):
      return !answers.isEmpty
        && answers.allSatisfy { q, o in
          form.work.questions.contains { $0.id == q && $0.options.contains { $0.id == o } }
        }
    case .outcome(let outcome): return outcome == .notHere || form.outcomes.contains(outcome)
    case .moved: return true
    case .skip: return task.canSkip()
    }
  }

  /// User-confirmed submission, from a screen that offers a fresh attempt.
  func perform(_ action: ChoiceAction) {
    let loaded: LoadedTask, form: ChoiceForm
    switch state {
    case .answering(let l, let f, _): (loaded, form) = (l, f)
    case .staleOwnLock(let l, let f, _, _): (loaded, form) = (l, f)
    default: return
    }
    guard offers(loaded.task, form, action) else { return }
    submit(loaded, form, action)
  }

  /// After `element_in_use`: the same outcome without deletion (Not an issue), once the user confirms.
  func sendWithoutDeletion() {
    guard case .elementInUse(let loaded, let form, let outcome) = state, writer != nil,
      let plain = Self.withoutDeletion(outcome)
    else { return }
    submit(loaded, form, .outcome(plain))
  }

  /// User-confirmed resend of the identical submission from Check again. The server's
  /// idempotency resumes it (for example finishes a pending status) without a second OSM upload.
  func resendSame() {
    guard case .checkAgain(let current) = state, current.canResend, !current.checking, writer != nil else {
      return
    }
    submit(current.loaded, current.form, current.action)
  }

  private func submit(_ loaded: LoadedTask, _ form: ChoiceForm, _ action: ChoiceAction) {
    if previewing {
      // Nothing is sent, and nothing changed for maps and lists. A skip only moves on.
      if !discarded {
        state = action == .skip ? .skipped(loaded, uncertain: false) : .previewSaved(loaded, form, action)
      }
      return
    }
    guard let writer, !discarded else { return }
    if writer.guest {
      saveForLater(loaded, form, action)
      return
    }
    let me = writer.me
    changed = true  // Before publishing: observers read it while rendering Submitting.
    state = .submitting(loaded, form, action)
    let ops = self.ops
    job = Task {
      // Only the write itself outlives cancellation (a detached task); its result is discarded.
      let result = await Task.detached { await Self.send(ops, loaded.task, action) }.value
      if Task.isCancelled || discarded { return }
      let next: TaskScreen
      switch result {
      case .success(let choice):
        next =
          action == .skip
          ? .skipped(loaded, uncertain: false)
          : await reread(loaded, action, me, choice?.changesetID)
      case .failure(let error): next = await failed(loaded, form, action, error)
      }
      publish(next)
    }
  }

  /// A guest's submission: stored as a pending answer (never an OSM edit, never a lock). Skipping
  /// only moves on. Resending after a failure is safe: the server keeps one answer per task.
  private func saveForLater(_ loaded: LoadedTask, _ form: ChoiceForm, _ action: ChoiceAction) {
    if action == .skip {
      state = .skipped(loaded, uncertain: false)
      return
    }
    changed = true
    // No guest yet (its registration hasn't come back): the outbox registers, then sends. A
    // request now would go without a guest and be refused (Tess, AB5).
    if unregisteredGuest, let kept = keep(loaded, action, MapRouletteError(.network)) {
      state = kept
      return
    }
    state = .submitting(loaded, form, action)
    let ops = self.ops
    // One bar that hangs: after a few seconds the answer waits on the phone like a failed save
    // (sending it again is safe), instead of a spinner until the request times out (Tess, dev).
    keptEarly = false
    if let delay = keptAfter, keepOnPhone != nil {
      keptTimer?.cancel()
      keptTimer = Task {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, !discarded, case .submitting = state,
          let kept = keep(loaded, action, MapRouletteError(.network, problem: .outcomeUnknown))
        else { return }
        keptEarly = true
        state = kept
      }
    }
    job = Task {
      let result = await Task.detached { () async -> Result<PendingChoice, any Error> in
        do {
          guard let submission = action.submission else { throw CancellationError() }
          do {
            return .success(try await ops.submitPendingChoice(loaded.task, submission))
          } catch let error as MapRouletteError where GuestOutbox.ineligible(error) {
            // Changed on the map while answering: if every question it asks now was answered,
            // send those, as the outbox does (offline-copy.md row 17; Tess, AB7).
            let open = try await ops.checkChoice(loaded.task.id)
            // Nothing left to ask: every key was filled by someone else (Iris).
            guard open.eligible else { throw AnsweredOnMap(reason: open.reason) }
            guard let rest = GuestOutbox.Answer(action)?.narrowed(to: open.questionIDs) else { throw error }
            return .success(try await ops.submitPendingChoice(loaded.task, rest))
          }
        } catch {
          return .failure(error)
        }
      }.value
      keptTimer?.cancel()
      // Already shown as waiting: a late success leaves the copy to be resent (harmless), and a
      // late failure keeps it.
      if keptEarly {
        if case .failure(let error) = result { _ = keep(loaded, action, error) }
        return
      }
      if case .failure(let error as AnsweredOnMap) = result {
        publish(.noLongerNeeded(loaded, error.reason))
        return
      }
      // Kept on the phone even when the person already left the place.
      if case .failure(let error) = result, let kept = keep(loaded, action, error) {
        if !(Task.isCancelled || discarded) { publish(kept) }
        return
      }
      if Task.isCancelled || discarded { return }
      switch result {
      case .success:
        publish(.done(.init(loaded: loaded, action: action, me: 0, changesetID: nil, readFailed: false, savedForLater: true)))
      case .failure(let error):
        publish(await failedForLater(loaded, form, action, error))
      }
    }
  }

  /// A refused guest save whose place now asks nothing: the answers were filled in on the map.
  private struct AnsweredOnMap: Error {
    let reason: IneligibleReason?
  }

  /// A save that failed for lack of connection (or may not have arrived) goes to the phone's
  /// outbox; sending it again later is safe because the server keeps one answer per task.
  private func keep(_ loaded: LoadedTask, _ action: ChoiceAction, _ error: any Error) -> TaskScreen? {
    guard let keepOnPhone, let answer = GuestOutbox.Answer(action) else { return nil }
    if let error = error as? MapRouletteError {
      guard error.problem == .outcomeUnknown || error.kind == .network else { return nil }
    } else if !(error is URLError) {
      return nil
    }
    keepOnPhone(
      .init(taskID: loaded.task.id.value, challengeID: loaded.challenge.id.value, answer: answer, savedAt: Date()))
    return .done(
      .init(loaded: loaded, action: action, me: 0, changesetID: nil, readFailed: false, savedForLater: true, waiting: true))
  }

  private func failedForLater(_ loaded: LoadedTask, _ form: ChoiceForm, _ action: ChoiceAction, _ error: any Error)
    async -> TaskScreen
  {
    guard let error = error as? MapRouletteError else {
      return .answering(loaded, form, notice: "Couldn't save your answers. Try again.")
    }
    if case .choice(.unsupportedTask)? = error.problem { return .accountNeeded(loaded) }
    switch (error.kind, error.reason) {
    case (_, "task_completed"?): return await notAccepted(loaded)
    case (_, "unsupported_task"?): return .accountNeeded(loaded)
    case (.rateLimit, "pending_limit"?):
      return .answering(loaded, form, notice: Wording.pendingLimit(noun))
    case (.permission, "challenge_not_published"?):
      return .notAvailable(loaded, reason: "This campaign isn't open for answers yet.")
    case (.authentication, _):
      return .answering(loaded, form, notice: "Couldn't save your answers. Try again in a moment.")
    default: break
    }
    // The network may have dropped after the server stored it; sending again replaces it.
    if error.problem == .outcomeUnknown || error.kind == .network {
      return .answering(loaded, form, notice: "Couldn't connect. Check your connection and try again.")
    }
    return await failed(loaded, form, action, error)
  }

  /// Manual re-check after an uncertain result or a failed post-write read. Never resends.
  func recheck() {
    guard let me = writer?.me else { return }
    switch state {
    case .checkAgain(let current) where !current.checking:
      job = Task { await verify(current, me) }
    case .done(var current) where current.readFailed && !current.checking:
      current.checking = true
      state = .done(current)
      job = Task { publish(await reread(current.loaded, current.action, me, current.changesetID)) }
    default: break
    }
  }

  /// Cancels reads and discards all later results. A write already sent still finishes.
  func cancel() {
    discarded = true
    job?.cancel()
    keptTimer?.cancel()
  }

  private nonisolated static func send(_ ops: any TaskOps, _ task: MapRouletteTask, _ action: ChoiceAction) async
    -> Result<ChoiceResult?, any Error>
  {
    do {
      guard let submission = action.submission else {
        try await ops.skipTask(task.id)
        return .success(nil)
      }
      return .success(try await ops.submitChoice(task, submission))
    } catch {
      return .failure(error)
    }
  }

  private func failed(_ loaded: LoadedTask, _ form: ChoiceForm, _ action: ChoiceAction, _ error: any Error) async
    -> TaskScreen
  {
    func answering(_ notice: String) -> TaskScreen { .answering(loaded, form, notice: notice) }
    func checkAgain(_ message: String, _ pending: TaskScreen.Pending, _ changesetID: Int64? = nil) -> TaskScreen {
      .checkAgain(
        .init(
          loaded: loaded, form: form, action: action, message: message, changesetID: changesetID,
          checking: false, pending: pending, canResend: pending == .statusPending))
    }
    guard let error = error as? MapRouletteError else {
      // Credential failures (for example a refresh that could not complete) happen before sending.
      return answering("Couldn't send your answers. Nothing was saved. Try again.")
    }
    if error.kind == .validation, error.problem == nil {
      // The SDK checks the submission against the payload before sending anything.
      return answering("Something went wrong. Nothing was saved. Try again.")
    }
    switch error.problem {
    case .choice(.taskIneligible(let reason))?: return .noLongerNeeded(loaded, reason, onSave: true)
    case .choice(.elementInUse)?:
      if case .outcome(let outcome) = action, Self.withoutDeletion(outcome) != nil {
        return .elementInUse(loaded, form, outcome)
      }
      return answering("The map wouldn't accept this change. Nothing was saved.")
    case .choice(.osmReauthRequired)?:
      return .signInRequired(
        loaded,
        reason: "Your sign-in has expired. Sign in again to save answers. Nothing was saved.")
    case .choice(.osmScopeRequired)?:
      return .signInRequired(
        loaded, reason: "This sign-in can't save answers. Sign in again. Nothing was saved.")
    case .insufficientScope?:
      return .signInRequired(
        loaded, reason: "This sign-in can't save answers. Sign in again. Nothing was saved.")
    case .choice(.osmUnavailable)?:
      return answering(
        "Saving is paused right now. Your answers are kept. Try again in a bit.")
    case .writesPaused?:
      return answering(Wording.writesPaused)
    case .choice(.submissionPending)?:
      return checkAgain(
        "Your last answers for this \(noun.one) are still being saved. Wait a moment, then try again.", .submissionPending)
    case .choice(.statusPending(let changeset))?:
      return checkAgain(
        "The edit reached OpenStreetMap, but MapRoulette has not recorded the result yet. It was not sent again. "
          + "Sending the same submission again finishes it without a second upload.", .statusPending, changeset)
    case .outcomeUnknown?:
      if action == .skip { return .skipped(loaded, uncertain: true) }
      return checkAgain("The connection failed before MapRoulette confirmed the result. It was not sent again.", .unknown)
    case .choice(.invalidSubmission)?:
      return answering("Your answers weren't accepted. Nothing was saved. Try again, or skip this \(noun.one).")
    case .choice(.movedTooFar)?:
      return answering(Wording.movedTooFar(noun))
    case .choice(.unsupportedTask)?:
      return .notAvailable(
        loaded, reason: "MapRoulette cannot process this task's questions. Complete it on the MapRoulette website.")
    case .lockedByOtherUser?: return .takenByOther(loaded)
    case .alreadyHoldingTask(let held, _, _, _)?: return .staleOwnLock(loaded, form, action, lockedTaskID: held)
    case .lockLost?:
      return answering("That took too long and wasn't saved. Please answer again.")
    case .invalidTransition?: return await notAccepted(loaded)
    case nil:
      switch error.kind {
      case .authentication:
        return answering(
          "Your sign-in wasn't accepted, so nothing was saved. Try again. If it keeps happening, sign in again.")
      case .notFound: return .noLongerNeeded(loaded, .elementGone, onSave: true)
      default:
        if error.kind == .http { log.info("Write refused: HTTP \(error.status ?? 0, privacy: .public)") }
        return answering(Self.writeError(error, noun))
      }
    }
  }

  private func notAccepted(_ loaded: LoadedTask) async -> TaskScreen {
    let fresh = (try? await ops.getTask(loaded.task.id)) ?? loaded.task
    return .notAvailable(
      LoadedTask(task: fresh, challenge: loaded.challenge),
      reason: "This \(noun.one) can't be answered right now. Someone may have just checked it, or the campaign is paused.")
  }

  private func reread(_ loaded: LoadedTask, _ action: ChoiceAction, _ me: Int64, _ changesetID: Int64?) async
    -> TaskScreen
  {
    do {
      let fresh = try await ops.getTask(loaded.task.id)
      return .done(
        .init(
          loaded: LoadedTask(task: fresh, challenge: loaded.challenge), action: action, me: me,
          changesetID: changesetID ?? fresh.changesetID, readFailed: false))
    } catch {
      return .done(.init(loaded: loaded, action: action, me: me, changesetID: changesetID, readFailed: true))
    }
  }

  /// Applies docs/design/task-completion.md §5 to a fresh read. Never resends and never releases: an
  /// edit may still be uploading.
  private func verify(_ pending: TaskScreen.CheckAgain, _ me: Int64) async {
    var checking = pending
    checking.checking = true
    state = .checkAgain(checking)
    let fresh: MapRouletteTask
    do {
      fresh = try await ops.getTask(pending.loaded.task.id)
    } catch {
      var failed = pending
      failed.message = "Couldn't check whether your answers were saved. Check your connection and try again."
      publish(.checkAgain(failed))
      return
    }
    let loaded = LoadedTask(task: fresh, challenge: pending.loaded.challenge)
    let target: TaskResolution
    switch pending.action {
    case .answers: target = .fixed
    case .outcome(let outcome): target = outcome.resolution
    case .moved: target = .tooHard
    case .skip:  // Not reached: an uncertain skip goes straight to Skipped.
      publish(.skipped(loaded, uncertain: true))
      return
    }
    let check = fresh.verifyResolution(target: target, me: me)
    let inOsm = pending.changesetID  // Known only after status_pending: the edit is in OSM.
    var next = pending
    next.loaded = loaded
    next.checking = false
    let result: TaskScreen
    if check == .applied {
      result = .done(
        .init(loaded: loaded, action: pending.action, me: me, changesetID: fresh.changesetID ?? inOsm, readFailed: false))
    } else if let inOsm {
      // Our edit is in OSM but MapRoulette has no status for it: never call it "not recorded".
      next.canResend = check == .notAppliedLockHeld || check == .notAppliedUnlocked
      next.message =
        "Your edit is in OpenStreetMap changeset \(inOsm), but MapRoulette has not recorded the result "
        + "(task status: \(TaskText.status(fresh.status?.code).lowercased()))."
      result = .checkAgain(next)
    } else if check == .resolvedByOther {
      result = .done(
        .init(
          loaded: loaded, action: pending.action, me: me, changesetID: fresh.changesetID, readFailed: false,
          byOther: fresh.completedBy != nil && fresh.completedBy != me))
    } else if check == .lockedByOther {
      result = .takenByOther(loaded)
    } else if pending.pending == .submissionPending {
      // Another submission is unfinished; resubmitting would only be refused again.
      next.message =
        "Someone's answers for this \(noun.one) are still being saved. Pick another \(noun.one) for now."
      result = .checkAgain(next)
    } else if check == .notAppliedLockHeld {
      next.canResend = true
      next.message =
        "Not saved yet. Check again in a minute, or send the same answers again."
      result = .checkAgain(next)
    } else if pending.action.editsOsm {
      // An edit may have reached OSM: only the identical submission can be resumed.
      next.canResend = true
      next.message = "Not saved. You can send the same answers again. They're never saved twice."
      result = .checkAgain(next)
    } else {
      result = .answering(loaded, pending.form, notice: "Your earlier answers weren't saved. You can send them again.")
    }
    publish(result)
  }

  private static func readError(_ error: any Error, _ noun: Noun) -> String {
    guard let error = error as? MapRouletteError else { return "Couldn't load this \(noun.one). Try again." }
    switch error.kind {
    case .notFound: return "This \(noun.one) is no longer in the campaign."
    case .network: return "Couldn't connect. Check your connection and try again."
    case .authentication: return "Your sign-in has expired. Sign in again."
    default: return "Couldn't load this \(noun.one). Try again."
    }
  }

  private static func writeError(_ error: MapRouletteError, _ noun: Noun) -> String {
    switch error.kind {
    case .network: "Couldn't connect, so nothing was saved. Check your connection and try again."
    case .rateLimit: "Too many tries at once. Nothing was saved. Wait a moment and try again."
    case .http: "This campaign may be paused. Nothing was saved. Ask your organizer."
    case .permission: "This couldn't be saved. Nothing was changed. Try again later."
    default: "Something went wrong on our side. Nothing was saved. Try again."
    }
  }

  /// The form for an eligible task: `outcomes` are the client's (declared plus Too hard, decoded
  /// with the deletion setting). When the check does not allow deletion (the node is in a way or
  /// relation), a delete outcome is offered without deletion instead (Not an issue) and listed in
  /// `notDeletable`.
  nonisolated static func form(_ work: ChoiceWork, outcomes: [ChoiceOutcome], deleteAllowed: Bool) -> ChoiceForm {
    let blocked = deleteAllowed ? [] : Set(outcomes.filter(\.deletesElement).map(\.id))
    return ChoiceForm(
      work: work, outcomes: outcomes.map { deleteAllowed ? $0 : $0.withoutDeletion() },
      notDeletable: blocked)
  }

  /// The deleting `outcome` without deletion (Not an issue), or nil if it is not a delete.
  nonisolated static func withoutDeletion(_ outcome: ChoiceOutcome) -> ChoiceOutcome? {
    outcome.deletesElement ? outcome.withoutDeletion() : nil
  }
}
