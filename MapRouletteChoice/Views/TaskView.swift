import AuthenticationServices
import CoreLocation
import MapRoulette
import SwiftUI

/// One place, one question per screen, sized for the street (docs: personas-and-design.md §4).
/// Late locking as in the SDK example (docs/design/mobile-choice-challenges.md §7): viewing never
/// locks; saving locks, submits and releases. OSM detail (tags, ids, changesets) shows only with
/// "Show OSM details". In campaign preview (design/preview-mode.md) every question is asked and
/// nothing is sent: the saved screen quotes what the real campaign would say.
struct TaskView: View {
  @Environment(AppSession.self) private var session
  @Environment(TaskChanges.self) private var changes
  @Environment(CampaignStore.self) private var campaigns
  @Environment(\.webAuthenticationSession) private var webAuth
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// VoiceOver moves to each new question's prompt.
  @AccessibilityFocusState private var promptFocused: Bool
  @AppStorage(SettingsKey.showOSMDetails) private var showDetails = false

  @State private var taskID: Int64
  /// The campaign's open places, for "Next nearest".
  private let candidates: [LocatedTask]
  /// Places someone reported as not here or moved: never offered as next, and a banner on open.
  private let reports: [Int64: TaskReport]
  /// Open places another guest's pending report holds: kept out of Next nearest.
  private let heldReports: Set<Int64>
  private let noun: Noun
  /// The participant's position when the first place was opened from the campaign, for
  /// "130 m northeast of you". Not live: after "Next nearest" they have moved, so it is hidden.
  private let userLocation: CLLocationCoordinate2D?
  private let firstTaskID: Int64
  /// Set in campaign preview: no writer, no guest, nothing counted or stored.
  private let preview: CampaignPreview?
  /// Places opened in this screen; never offered again as next.
  @State private var visited: Set<Int64>
  @State private var controller: TaskWorkController?
  @State private var generation: Int?
  @State private var confirmation: Confirmation?
  /// Shown above the next screen after an account switch.
  @State private var switchNotice: String?
  @State private var reportedChange = false
  /// The question on screen; `questions.count` is the review step.
  @State private var step = 0
  /// Questions answered "I'm not sure" (as opposed to not reached yet).
  @State private var notSure: Set<String> = []
  @State private var showProblems = false
  @State private var counted = false
  /// "It's not here" or "It's moved", once picked: its review replaces the questions.
  @State private var report: ChoiceAction?
  @State private var pickingSpot = false
  /// The sheet row picked, run once the sheet is gone (an alert or a cover can't open over it).
  @State private var afterProblems: (() -> Void)?

  init(
    taskID: Int64, candidates: [LocatedTask], reports: [Int64: TaskReport] = [:], heldReports: Set<Int64> = [],
    noun: Noun, userLocation: CLLocationCoordinate2D? = nil, preview: CampaignPreview? = nil
  ) {
    _taskID = State(initialValue: taskID)
    _visited = State(initialValue: [taskID])
    self.candidates = candidates
    self.reports = reports
    self.heldReports = heldReports
    self.noun = noun
    self.userLocation = userLocation
    firstTaskID = taskID
    self.preview = preview
  }

  /// A confirmation bound to the controller that showed it: a dialog left open across an
  /// account switch must not write as the new account.
  private struct Confirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirm: String
    let owner: TaskWorkController
    let run: (TaskWorkController) -> Void
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if let controller {
          content(controller)
        } else {
          ProgressView().frame(maxWidth: .infinity)
        }
      }
      .padding()
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if let preview, preview.showsBanner { PreviewBanner(preview: preview) }
    }
    // The place name heads the screen; a title would repeat it.
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    // Back is blocked while a write is in flight (normally a few seconds).
    .navigationBarBackButtonHidden(controller?.busy == true)
    .alert(
      confirmation?.title ?? "", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
      presenting: confirmation
    ) { c in
      Button(c.confirm) { if controller === c.owner { c.run(c.owner) } }
      Button("Cancel", role: .cancel) {}
    } message: { c in
      Text(c.message)
    }
    .onAppear {
      if controller == nil { start() }
    }
    .onChange(of: session.view.generation) { accountChanged() }
    .onChange(of: controller?.changed) { if controller?.changed == true { reportChange() } }
    .onChange(of: finishedTaskID) { countFinished() }
    .sheet(isPresented: $showProblems, onDismiss: runAfterProblems) {
      if let controller, case .answering(let loaded, let form, _) = controller.state {
        problemsSheet(controller, loaded, form)
      }
    }
    .fullScreenCover(isPresented: $pickingSpot) {
      if let here {
        MovedSpotView(mapped: here, noun: noun) { spot in
          pickingSpot = false
          report = .moved(spot)
        }
      }
    }
  }

  // MARK: Lifecycle

  private func start() {
    Task {
      // Registering a guest changes the session generation; do it before binding a controller.
      // Never in preview: that would leave a guest behind (§2).
      if preview == nil && session.canAnswerAsGuest { _ = await session.ensureGuest() }
      guard controller == nil else { return }
      generation = session.view.generation
      replaceController()
      controller?.load(try! TaskID(taskID))
    }
  }

  /// A controller is bound to one account's clients; results of a replaced one are never shown.
  private func replaceController() {
    let view = session.view
    let writer: Writer? =
      preview != nil ? nil
      : session.writesConfigured && view.signedIn && view.canWriteTasks
        ? view.userID.map { Writer(me: $0, canEditOsm: view.canEditOsm) }
      : session.writesConfigured && view.guest ? .guestWriter : nil
    controller = TaskWorkController(
      ops: ClientTaskOps(session.newClient().client), writer: writer, noun: noun, previewing: preview != nil)
  }

  /// Account switch or sign-out: discard the old account's state and any late result.
  private func accountChanged() {
    guard let old = controller, generation != session.view.generation else { return }
    generation = session.view.generation
    var interrupted = old.busy
    if case .checkAgain = old.state { interrupted = true }
    if interrupted || old.changed { reportChange() }
    old.cancel()
    confirmation = nil
    replaceController()
    switchNotice =
      (interrupted
        ? "Your sign-in changed while your answers were being saved, so we can't tell whether they were. "
        : "") + session.view.message
    resetQuestions()
    controller?.load(try! TaskID(taskID))
  }

  private func reportChange() {
    // Once per place: lists and maps reload.
    if !reportedChange {
      reportedChange = true
      changes.taskChanged()
    }
  }

  private func resetQuestions() {
    step = 0
    notSure = []
    report = nil
  }

  /// The task id once it is finished by this user (saved or recorded, not skipped), or "saved"
  /// in preview.
  private var finishedTaskID: Int64? {
    switch controller?.state {
    case .done(let d)? where !d.byOther: d.loaded.task.id.value
    case .previewSaved(let loaded, _, _)?: loaded.task.id.value
    default: nil
    }
  }

  private func countFinished() {
    guard finishedTaskID != nil, !counted, let state = controller?.state else { return }
    counted = true
    // In preview nothing is stored (§4.2). No sheet after a guest's first save (handback §1):
    // the confirmation and the save note carry the message.
    campaigns.finished(state, preview: preview)
  }

  /// The current place's position: the loaded task's, else the campaign list's.
  private var here: CLLocationCoordinate2D? {
    if let task = controller?.state.loaded?.task, let c = TaskLocation.coordinate(task) { return c }
    return candidates.first { $0.id == taskID }?.coordinate
  }

  /// Reports from the campaign list and this device's since launch.
  private var allReports: [Int64: TaskReport] { reports.merging(campaigns.justReported) { $1 } }

  private var nextPlace: LocatedTask? {
    TaskLocation.nearest(
      from: here, in: candidates, excluding: visited.union(campaigns.justDone).union(campaigns.lookAgain(allReports)).union(heldReports))
  }

  private func open(_ next: LocatedTask) {
    guard let controller, !controller.busy else { return }
    switchNotice = nil
    if controller.changed { reportChange() }
    taskID = next.id
    visited.insert(next.id)
    reportedChange = false
    counted = false
    resetQuestions()
    replaceController()
    self.controller?.load(try! TaskID(taskID))
  }

  private func signIn() {
    Task {
      await session.signIn { url in
        try await webAuth.authenticate(
          using: url, callbackURLScheme: AuthEndpoints.callbackScheme, preferredBrowserSession: .ephemeral)
      }
    }
  }

  // MARK: Content

  @ViewBuilder private func content(_ c: TaskWorkController) -> some View {
    let state = c.state
    if let loaded = state.loaded { header(loaded, checked: Self.showsChecked(state), movedTo: reviewedSpot(state)) }
    if let switchNotice, !isLoading(state) { banner(switchNotice) }
    switch state {
    case .loading:
      HStack { ProgressView(); Text("Loading…") }
    case .loadFailed(let message):
      Text(message)
      bigButton("Try again") { c.load(try! TaskID(taskID)) }
      backButton()
    case .notAvailable(let loaded, let reason):
      Text(Wording.cannotAnswer(noun)).font(.headline)
      if preview != nil && ChoiceWork(loaded.task.work()) == nil {
        // The organizer needs the reason; participants never see a draft (§5).
        Text(Wording.invalidSurvey(Wording.invalidSurveyReason(loaded.task)))
      } else if showDetails {
        Text(reason).font(.footnote).foregroundStyle(.secondary)
      }
      nextButtons()
    case .preview(_, let work):
      readOnly(work)
    case .checkFailed:
      Text(Wording.checkFailed(noun))
      bigButton("Try again") { c.load(try! TaskID(taskID)) }
      nextButtons(prominent: false)
    case .noLongerNeeded:
      Text(Wording.alreadyChecked(noun)).font(.headline)
      nextButtons()
    case .answering(let loaded, let form, let notice):
      if let notice { banner(notice) }
      answering(c, loaded, form)
    case .submitting:
      HStack { ProgressView(); Text("Saving…") }.font(.headline)
    case .done(let d):
      done(c, d)
    case .previewSaved(let loaded, let form, let action):
      previewSaved(loaded, form, action)
    case .skipped(_, let uncertain):
      Text(
        uncertain
          ? "The connection dropped, so we're not sure the skip went through. You don't need to do anything."
          : "Skipped. It stays open for someone else."
      )
      nextButtons()
    case .takenByOther:
      Text(Wording.takenByOther(noun))
      nextButtons()
    case .staleOwnLock(_, _, let action, let held):
      Text("Your last try on this \(noun.one) is still being processed. Wait a moment, then try again. Nothing was changed.")
      if showDetails { Text(verbatim: "Locked task: \(held.value)").font(.footnote).foregroundStyle(.secondary) }
      bigButton("Try again") { c.perform(action) }
      backButton()
    case .checkAgain(let pending):
      checkAgain(c, pending)
    case .signInRequired(_, let reason):
      Text(reason)
      bigButton("Sign in again") { signIn() }
      backButton()
    case .accountNeeded:
      // copy-fixes-2026-10-11.md, "Guest on a task that needs an account": most guests have no
      // account, so Next nearest leads.
      Text(Wording.accountNeededTitle(noun)).font(.headline)
      Text(Wording.accountNeeded(noun))
      // No "That was the last one" here: nothing was checked.
      if nextPlace != nil { nextButton() }
      bigButton("Sign in with OpenStreetMap", prominent: nextPlace == nil) { signIn() }
      Text(session.accountHint).font(.footnote).foregroundStyle(.secondary)
      backButton()
    case .elementInUse(let loaded, let form, let outcome):
      elementInUse(c, loaded, form, outcome)
    case .writesPaused:
      Text(Wording.writesPausedOnOpen(noun))
      bigButton("OK", prominent: true) { dismiss() }
    }
  }

  /// The header map shows the place as checked once it no longer needs answering.
  private static func showsChecked(_ state: TaskScreen) -> Bool {
    switch state {
    // A report leaves the place open: it needs another look.
    case .done(let d) where d.action.isReport || d.flagged: false
    case .noLongerNeeded, .done: true
    default: state.loaded.map { LocatedTask($0.task).isDone } ?? false
    }
  }

  /// The spot being reviewed for "It's moved": the header map then draws it like the moved map.
  private func reviewedSpot(_ state: TaskScreen) -> CLLocationCoordinate2D? {
    guard case .answering = state, case .moved(let spot)? = report else { return nil }
    return CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
  }

  @ViewBuilder private func header(_ loaded: LoadedTask, checked: Bool, movedTo: CLLocationCoordinate2D?) -> some View {
    let task = loaded.task
    if let coordinate = TaskLocation.coordinate(task), let movedTo {
      // "On the map", the navy pin and the dashed line, as on the moved map (§3.2 step 4).
      SpotMapView(mapped: coordinate, spot: movedTo, interactive: false)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of where the map has it and the spot you picked")
        .accessibilityAddTraits(.isImage)
        .id("\(movedTo.latitude),\(movedTo.longitude)")
    } else if let coordinate = TaskLocation.coordinate(task) {
      TaskMapView(
        styleURL: AppConfig.detailStyle, tasks: [LocatedTask(task)], done: checked ? [task.id.value] : [],
        reports: reports[task.id.value].map { [task.id.value: $0] } ?? [:],
        noun: noun, interactive: false, open: { _ in }
      )
      .frame(height: 150)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      // One element: the tiles' street names aren't readable text.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Map of \(Wording.placeName(task, noun))")
      .accessibilityAddTraits(.isImage)
      .id(coordinate.latitude + coordinate.longitude)
    }
    VStack(alignment: .leading, spacing: 4) {
      Text(Wording.placeName(task, noun)).font(.title2.bold())
      if task.id.value == firstTaskID, let whereText = TaskLocation.fromYouText(userLocation, TaskLocation.coordinate(task)) {
        Text(whereText).font(.subheadline).foregroundStyle(.primary)
      }
      if showDetails {
        Text(verbatim: task.name).font(.footnote.monospaced()).foregroundStyle(.secondary)
        let element = ChoiceWork(task.work()).map { " · \(TaskText.element($0.element))" } ?? ""
        Text(verbatim: "Task \(task.id.value) · \(TaskText.status(task.status?.code))\(element)")
          .font(.footnote.monospaced()).foregroundStyle(.secondary)
        Text(verbatim: "Challenge \(loaded.challenge.id.value): \(loaded.challenge.name)")
          .font(.footnote).foregroundStyle(.secondary)
      }
    }
    if let lockedBy = task.lockedBy, lockedBy != session.view.userID {
      banner("Someone else may be checking this \(noun.one) right now. You can still answer.")
    }
    // Someone else's report, from the campaign list (design/not-here-moved.md §4). The reporter
    // sees their own saved line instead.
    if !checked, campaigns.justReported[task.id.value] == nil,
      let text = reportBanner(reports[task.id.value], at: TaskLocation.coordinate(task))
    {
      banner(text)
    }
  }

  private func reportBanner(_ report: TaskReport?, at place: CLLocationCoordinate2D?) -> String? {
    switch report {
    case .notHere?: return Wording.someoneReportedNotHere(noun)
    case .moved(let lat, let lon)?:
      guard let place else { return nil }
      return Wording.someoneReportedMoved(
        TaskLocation.meters(place, CLLocationCoordinate2D(latitude: lat, longitude: lon)), noun)
    case nil: return nil
    }
  }

  private func banner(_ text: String) -> some View {
    Text(text)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(Color.yellow.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityAddTraits(.updatesFrequently)
  }

  private func isLoading(_ state: TaskScreen) -> Bool {
    if case .loading = state { return true }
    return false
  }

  // MARK: Answering

  @ViewBuilder private func answering(_ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm) -> some View {
    let questions = form.work.questions
    if !c.canEditOsm {
      Text("This sign-in can't save answers to OpenStreetMap.")
      bigButton("Sign in again") { signIn() }
    } else if let report {
      reportReview(c, loaded, form, report)
    } else if step < questions.count {
      question(c, form, questions[step], index: step, of: questions.count)
    } else {
      review(c, loaded, form)
    }
    if report == nil { problems(c, loaded, form) }
  }

  /// "Check your report" (§3.1, §3.2 step 4): what will be sent, then Done or Back. For a move,
  /// the header map shows the spot.
  @ViewBuilder private func reportReview(
    _ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm, _ action: ChoiceAction
  ) -> some View {
    Text(Wording.checkReport).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
    VStack(alignment: .leading, spacing: 8) {
      Text(Wording.reporting).font(.headline)
      Text(reportLine(action) ?? "")
    }
    .accessibilityElement(children: .combine)
    Text(action == .outcome(.notHere) ? Wording.reportNotHereNote : Wording.reportMovedNote)
    bigButton(preview != nil ? Wording.donePreview : Wording.done, prominent: true) { c.perform(action) }
      .disabled(!c.offers(loaded.task, form, action))
    bigButton("Back") { report = nil }
  }

  /// "The stop isn't here." / "The stop has moved, about 30 m from where the map has it."
  private func reportLine(_ action: ChoiceAction) -> String? {
    switch action {
    case .outcome(let outcome) where outcome == .notHere: return Wording.reportNotHere(noun)
    case .moved(let spot):
      guard let place = here else { return nil }
      return Wording.reportMoved(
        TaskLocation.meters(place, CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)), noun)
    default: return nil
    }
  }

  /// The saved line for a report, or nil for anything else.
  private func reportedLine(_ action: ChoiceAction) -> String? {
    switch action {
    case .outcome(let outcome) where outcome == .notHere: Wording.reportedNotHere
    case .moved: Wording.reportedMoved
    default: nil
    }
  }

  @ViewBuilder private func question(
    _ c: TaskWorkController, _ form: ChoiceForm, _ q: ChoiceQuestion, index: Int, of count: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Question \(index + 1) of \(count)").font(.subheadline).foregroundStyle(.primary)
      // "Question 1 of 3" says it; the bar would be a separate 4 pt element.
      ProgressView(value: Double(index + 1), total: Double(count)).accessibilityHidden(true)
    }
    .accessibilityElement(children: .combine)
    Text(q.prompt).font(.title2.weight(.semibold))
      .accessibilityAddTraits(.isHeader)
      .accessibilityFocused($promptFocused)
    if let description = q.description, !description.isEmpty {
      Text(description).font(.body).foregroundStyle(.primary)
    }
    ForEach(q.options) { option in
      answerButton(
        option.label, detail: option.description,
        tags: showDetails ? TaskText.tagChange(option) : nil,
        selected: form.answers[q.id] == option.id
      ) {
        c.select(question: q.id, option: option.id)
        notSure.remove(q.id)
        advance()
      }
    }
    answerButton(Wording.notSure, detail: nil, tags: nil, selected: notSure.contains(q.id)) {
      c.select(question: q.id, option: nil)
      notSure.insert(q.id)
      advance()
    }
    if index > 0 {
      Button("Previous question", systemImage: "chevron.left") { step = index - 1 }
        .frame(minHeight: 44)
    }
  }

  private func advance() {
    if reduceMotion {
      step += 1
    } else {
      withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
    }
    promptFocused = true
  }

  @ViewBuilder private func review(_ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm) -> some View {
    Text("Check your answers").font(.title2.weight(.semibold))
    ForEach(Array(form.work.questions.enumerated()), id: \.element.id) { index, q in
      Button {
        step = index
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(q.prompt).foregroundStyle(.primary)
            let answer = q.options.first { $0.id == form.answers[q.id] }
            Text(answer?.label ?? Wording.notSureShort)
              .font(.headline)
              .foregroundStyle(answer == nil ? Color.secondary : Color.accentColor)
            if showDetails, let answer { Text(TaskText.tagChange(answer)).font(.footnote.monospaced()).foregroundStyle(.secondary) }
          }
          Spacer()
          Image(systemName: "pencil").foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
      }
      .buttonStyle(.plain)
      .accessibilityHint("Change this answer")
    }
    if form.answers.isEmpty {
      Text(Wording.nothingAnswered(noun))
      if c.offers(loaded.task, form, .skip) {
        bigButton(Wording.skip(noun)) { c.perform(.skip) }
      }
    } else {
      if form.answers.count < form.work.questions.count {
        Text(Wording.notSureCloses(noun)).font(.footnote).foregroundStyle(.secondary)
      }
      // Answering is the intent: no confirmation dialog for the normal case.
      bigButton(preview != nil ? Wording.donePreview : Wording.done, prominent: true) {
        c.perform(.answers(form.answers))
      }
      .disabled(!c.offers(loaded.task, form, .answers(form.answers)))
      if showDetails && preview == nil {
        Text(TaskText.osmNotice(session.osmServer)).font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  /// The "Something's wrong here" button; the sheet lists the choices.
  @ViewBuilder private func problems(_ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm) -> some View {
    Divider().padding(.vertical, 4)
    Button(Wording.somethingWrong, systemImage: "exclamationmark.bubble") { showProblems = true }
      .frame(maxWidth: .infinity, minHeight: 44)
  }

  private func pick(_ action: @escaping () -> Void) {
    afterProblems = action
    showProblems = false
  }

  private func runAfterProblems() {
    let action = afterProblems
    afterProblems = nil
    action?()
  }

  /// "Something's wrong here" (design/not-here-moved.md §2): least consequence first. Skip, "I
  /// can't check", "It's not here", "It's moved", then the campaign's own outcomes, each with a line
  /// on what it means.
  private func problemsSheet(_ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm) -> some View {
    let outcomes = form.outcomes.filter { c.offers(loaded.task, form, .outcome($0)) }
    let tooHard = outcomes.first { $0.id == ChoiceOutcome.tooHardID }
    let details = showDetails ? Wording.reportDetails : nil
    return NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(Wording.problemsMessage).foregroundStyle(.secondary)
          if c.offers(loaded.task, form, .skip) {
            answerButton(Wording.skip(noun), detail: Wording.skipExplained, tags: nil, selected: false) {
              pick { c.perform(.skip) }
            }
          }
          if let tooHard {
            answerButton(Wording.cantCheck(noun), detail: Wording.cantCheckExplained, tags: nil, selected: false) {
              pick { choose(c, loaded, form, .outcome(tooHard)) }
            }
          }
          answerButton(Wording.notHere, detail: Wording.notHereExplained(noun), tags: details, selected: false) {
            pick {
              switchNotice = nil
              report = .outcome(.notHere)
            }
          }
          if here != nil {
            answerButton(Wording.moved, detail: Wording.movedExplained, tags: details, selected: false) {
              pick {
                switchNotice = nil
                pickingSpot = true
              }
            }
          }
          ForEach(outcomes.filter { $0.id != ChoiceOutcome.tooHardID }) { outcome in
            answerButton(outcome.label, detail: outcome.description, tags: nil, selected: false) {
              pick { choose(c, loaded, form, .outcome(outcome)) }
            }
          }
        }
        .padding()
      }
      .navigationTitle(Wording.somethingWrong)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button(Wording.cancel) { showProblems = false } }
      }
    }
    .presentationDetents([.large])
  }

  /// Outcomes run directly, except a delete, which always confirms (not in preview: nothing is sent).
  private func choose(_ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm, _ action: ChoiceAction) {
    switchNotice = nil
    if preview == nil, case .outcome(let outcome) = action, outcome.deletesElement, let me = session.view.userID {
      confirmation = Confirmation(
        title: "Delete it from OpenStreetMap?",
        message: TaskText.outcomeSummary(
          outcome, element: form.work.element, taskID: loaded.task.id.value, me: me, osmServer: session.osmServer,
          notDeletable: form.notDeletable.contains(outcome.id)),
        confirm: "Delete", owner: c, run: { $0.perform(action) })
    } else {
      c.perform(action)
    }
  }

  /// Signed out or read-only: the questions, and how to sign in to answer them.
  @ViewBuilder private func readOnly(_ work: ChoiceWork) -> some View {
    Text("Sign in to answer").font(.headline)
    Text("You'll be asked \(work.questions.count == 1 ? "one question" : "\(work.questions.count) questions") about this \(noun.one):")
    ForEach(work.questions) { q in
      Label(q.prompt, systemImage: "questionmark.circle")
    }
    if session.writesConfigured {
      bigButton(session.view.signedIn ? "Sign in again to answer" : "Sign in with OpenStreetMap", prominent: true) { signIn() }
      Text(session.accountHint).font(.footnote).foregroundStyle(.secondary)
    }
    backButton()
  }

  // MARK: After saving

  @ViewBuilder private func done(_ c: TaskWorkController, _ d: TaskScreen.Done) -> some View {
    if d.byOther {
      Text(Wording.checkedByOtherFirst(noun)).font(.headline)
    } else {
      Label {
        Text(
          reportedLine(d.action)
            ?? (d.savedForLater
              ? Wording.savedForLater(campaigns.checkedToday(d.loaded.challenge.id.value), noun)
              : Wording.saved(campaigns.checkedToday(d.loaded.challenge.id.value), noun)))
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      .font(.title3.weight(.semibold))
      if d.savedForLater && !d.action.isReport && campaigns.checkedToday(d.loaded.challenge.id.value) <= 3 {
        // Only the first few times: by then the participant knows.
        Text(Wording.savedForLaterNote).font(.footnote).foregroundStyle(.secondary)
      }
    }
    if showDetails {
      Text(doneDetails(d)).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
      if !d.byOther, let id = d.changesetID { changesetLink(id) }
    }
    if d.readFailed && showDetails {
      Button("Check status again") { c.recheck() }.disabled(d.checking)
    }
    nextButtons()
  }

  /// Preview: nothing was sent. The real saved line is quoted so the organizer sees its copy; with
  /// details on, the tag changes it would have made.
  @ViewBuilder private func previewSaved(_ loaded: LoadedTask, _ form: ChoiceForm, _ action: ChoiceAction) -> some View {
    let count = preview?.savedCount(including: loaded.task.id.value) ?? 1
    VStack(alignment: .leading, spacing: 6) {
      Text(Wording.previewNotSaved).font(.title3.weight(.semibold))
      Text(Wording.previewWouldSay(reportedLine(action) ?? Wording.saved(count, noun)))
    }
    if showDetails {
      switch action {
      case .answers(let answers):
        if let tags = TaskText.tagChanges(form, answers) {
          Text(Wording.wouldSet(tags)).font(.footnote.monospaced()).foregroundStyle(.secondary)
        }
      case .outcome(let outcome):
        Text(
          TaskText.outcomeExplanation(
            outcome, element: form.work.element, notDeletable: form.notDeletable.contains(outcome.id))
        )
        .font(.footnote).foregroundStyle(.secondary)
      case .moved:
        Text(Wording.reportDetails).font(.footnote).foregroundStyle(.secondary)
      case .skip:
        EmptyView()
      }
    }
    nextButtons()
  }

  @ViewBuilder private func checkAgain(_ c: TaskWorkController, _ pending: TaskScreen.CheckAgain) -> some View {
    if pending.checking {
      HStack { ProgressView(); Text("Checking…") }
    } else {
      Text("The connection dropped, so we're not sure your answers were saved. Tap Check again to find out. They weren't sent twice.")
      if showDetails {
        Text(pending.message).font(.footnote).foregroundStyle(.secondary)
        if let id = pending.changesetID { changesetLink(id) }
      }
      bigButton("Check again", prominent: true) { c.recheck() }
      if pending.canResend { bigButton("Send the same answers again") { confirmResend(pending) } }
      backButton()
    }
  }

  @ViewBuilder private func elementInUse(
    _ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm, _ outcome: ChoiceOutcome
  ) -> some View {
    Text("OpenStreetMap wouldn't delete this \(noun.one) because something else uses it. Nothing was changed.")
    if let plain = TaskWorkController.withoutDeletion(outcome), let me = session.view.userID {
      bigButton("Record “\(outcome.label)” without deleting") {
        confirmation = Confirmation(
          title: "Record “\(outcome.label)” without deleting?",
          message: TaskText.outcomeSummary(
            plain, element: form.work.element, taskID: loaded.task.id.value, me: me,
            osmServer: session.osmServer, notDeletable: true),
          confirm: "Confirm", owner: c, run: { $0.sendWithoutDeletion() })
      }
    }
    backButton()
  }

  /// Next nearest place (prominent), with distance and direction from this one, then back to the campaign.
  @ViewBuilder private func nextButtons(prominent: Bool = true) -> some View {
    nextButton(prominent: prominent)
    backButton()
  }

  @ViewBuilder private func nextButton(prominent: Bool = true) -> some View {
    if let next = nextPlace {
      bigButton(
        Wording.next(noun, distance: TaskLocation.directionText(here, next.coordinate), hasOrigin: here != nil), prominent: prominent
      ) {
        if here != nil { open(next) }
        else { dismiss() }
      }
    } else {
      Text("That was the last \(noun.one) to check. Thank you!").foregroundStyle(.secondary)
    }
  }

  private func backButton() -> some View {
    Button("Back to all \(noun.many)") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
  }

  // MARK: Controls

  private func bigButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
    Group {
      if prominent {
        Button(action: action) { bigLabel(title) }.buttonStyle(.borderedProminent)
      } else {
        Button(action: action) { bigLabel(title) }.buttonStyle(.bordered)
      }
    }
  }

  private func bigLabel(_ title: String) -> some View {
    Text(title).font(.headline).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 50)
  }

  /// A full-width answer: label, optional help, optional tag change (details only).
  private func answerButton(
    _ title: String, detail: String?, tags: String?, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
          if let detail, !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
          if let tags { Text(tags).font(.footnote.monospaced()).foregroundStyle(.secondary) }
        }
        Spacer(minLength: 0)
        if selected { Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Color.accentColor) }
      }
      .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 14)
          .fill(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
      )
      .overlay(
        // A visible edge even when unselected, so buttons hold up in glare.
        RoundedRectangle(cornerRadius: 14)
          .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 2 : 1.5)
      )
      .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }

  @ViewBuilder private func changesetLink(_ id: Int64) -> some View {
    if let url = TaskText.changesetURL(session.osmServer, id) {
      let where_ = session.osmServer == TaskText.devOSM ? " on development OSM" : ""
      Link(String("View changeset \(id)\(where_)"), destination: url).font(.footnote)
    }
  }

  // MARK: Confirmations and details

  private func confirmResend(_ state: TaskScreen.CheckAgain) {
    guard let me = session.view.userID, let owner = controller else { return }
    let id = state.loaded.task.id.value
    let summary: String
    switch state.action {
    case .answers(let answers):
      var form = state.form
      form.answers = answers
      summary = TaskText.answersSummary(form, taskID: id, me: me, osmServer: session.osmServer)
    case .outcome(let outcome):
      summary = TaskText.outcomeSummary(
        outcome, element: state.form.work.element, taskID: id, me: me, osmServer: session.osmServer,
        notDeletable: state.form.notDeletable.contains(outcome.id))
    case .moved: summary = reportLine(state.action) ?? ""
    case .skip: return
    }
    confirmation = Confirmation(
      title: "Send the same answers again?",
      message: "This finishes your earlier try. Your answers are never saved twice."
        + (showDetails ? "\n\n\(summary)" : ""),
      confirm: "Send again", owner: owner, run: { $0.resendSame() })
  }

  private func doneDetails(_ d: TaskScreen.Done) -> String {
    var lines: [String] = []
    if d.readFailed {
      lines.append("The task could not be re-read to confirm its status.")
    } else {
      lines.append("Status: \(TaskText.status(d.loaded.task.status?.code)).")
      lines.append(TaskText.completedBy(d.loaded.task.completedBy, me: d.me))
      if let review = TaskText.reviewStatus(d.loaded.task.reviewStatus) { lines.append("\(review).") }
    }
    if let id = d.changesetID { lines.append("OpenStreetMap changeset \(id).") }
    return lines.joined(separator: "\n")
  }
}
