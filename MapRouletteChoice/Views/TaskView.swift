import AuthenticationServices
import CoreLocation
import MapRoulette
import SwiftUI

/// One place, one question per screen, sized for the street (docs: personas-and-design.md §4).
/// Late locking as in the SDK example (docs/design/mobile-choice-challenges.md §7): viewing never
/// locks; saving locks, submits and releases. OSM detail (tags, ids, changesets) shows only with
/// "Show OSM details".
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
  @AppStorage(SettingsKey.putOnMapCardShown) private var putOnMapCardShown = false
  @State private var showPutOnMap = false

  @State private var taskID: Int64
  /// The campaign's open places, for "Next nearest".
  private let candidates: [LocatedTask]
  private let noun: Noun
  /// The participant's position when the first place was opened from the campaign, for
  /// "130 m northeast of you". Not live: after "Next nearest" they have moved, so it is hidden.
  private let userLocation: CLLocationCoordinate2D?
  private let firstTaskID: Int64
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

  init(taskID: Int64, candidates: [LocatedTask], noun: Noun, userLocation: CLLocationCoordinate2D? = nil) {
    _taskID = State(initialValue: taskID)
    _visited = State(initialValue: [taskID])
    self.candidates = candidates
    self.noun = noun
    self.userLocation = userLocation
    firstTaskID = taskID
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
    .sheet(isPresented: $showPutOnMap) { PutOnMapCard() }
  }

  // MARK: Lifecycle

  private func start() {
    Task {
      // Registering a guest changes the session generation; do it before binding a controller.
      if session.canAnswerAsGuest { _ = await session.ensureGuest() }
      guard controller == nil else { return }
      generation = session.view.generation
      replaceController()
      controller?.load(try! TaskID(taskID))
    }
  }

  /// A controller is bound to one account's clients; results of a replaced one are never shown.
  private func replaceController() {
    let view = session.view
    let writer =
      session.writesConfigured && view.signedIn && view.canWriteTasks
      ? view.userID.map { Writer(me: $0, canEditOsm: view.canEditOsm) }
      : session.writesConfigured && view.guest ? .guestWriter : nil
    controller = TaskWorkController(
      ops: ClientTaskOps(session.newClient().client), writer: writer, noun: noun)
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
  }

  /// The task id once it is finished by this user (saved or recorded, not skipped).
  private var finishedTaskID: Int64? {
    guard case .done(let d) = controller?.state, !d.byOther else { return nil }
    return d.loaded.task.id.value
  }

  private func countFinished() {
    guard let id = finishedTaskID, !counted, case .done(let d) = controller?.state else { return }
    counted = true
    campaigns.recordChecked(d.loaded.challenge.id.value, task: id)
    if d.savedForLater && !putOnMapCardShown {
      // Once, after the first saved answer; later from the campaign's banner.
      putOnMapCardShown = true
      showPutOnMap = true
    }
  }

  /// The current place's position: the loaded task's, else the campaign list's.
  private var here: CLLocationCoordinate2D? {
    if let task = controller?.state.loaded?.task, let c = TaskLocation.coordinate(task) { return c }
    return candidates.first { $0.id == taskID }?.coordinate
  }

  private var nextPlace: LocatedTask? {
    TaskLocation.nearest(from: here, in: candidates, excluding: visited.union(campaigns.justDone))
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
    if let loaded = state.loaded { header(loaded, checked: Self.showsChecked(state)) }
    if let switchNotice, !isLoading(state) { banner(switchNotice) }
    switch state {
    case .loading:
      HStack { ProgressView(); Text("Loading…") }
    case .loadFailed(let message):
      Text(message)
      bigButton("Try again") { c.load(try! TaskID(taskID)) }
      backButton()
    case .notAvailable(_, let reason):
      Text(Wording.cannotAnswer(noun)).font(.headline)
      if showDetails { Text(reason).font(.footnote).foregroundStyle(.secondary) }
      nextButtons()
    case .preview(_, let work):
      preview(work)
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
    case .elementInUse(let loaded, let form, let outcome):
      elementInUse(c, loaded, form, outcome)
    }
  }

  /// The header map shows the place as checked once it no longer needs answering.
  private static func showsChecked(_ state: TaskScreen) -> Bool {
    switch state {
    case .noLongerNeeded, .done: true
    default: state.loaded.map { LocatedTask($0.task).isDone } ?? false
    }
  }

  @ViewBuilder private func header(_ loaded: LoadedTask, checked: Bool) -> some View {
    let task = loaded.task
    if let coordinate = TaskLocation.coordinate(task) {
      TaskMapView(
        styleURL: AppConfig.detailStyle, tasks: [LocatedTask(task)], done: checked ? [task.id.value] : [],
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
    } else if step < questions.count {
      question(c, form, questions[step], index: step, of: questions.count)
    } else {
      review(c, loaded, form)
    }
    problems(c, loaded, form)
  }

  @ViewBuilder private func question(
    _ c: TaskWorkController, _ form: ChoiceForm, _ q: ChoiceQuestion, index: Int, of count: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Question \(index + 1) of \(count)").font(.subheadline).foregroundStyle(.primary)
      ProgressView(value: Double(index + 1), total: Double(count))
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
      bigButton(Wording.done, prominent: true) { c.perform(.answers(form.answers)) }
        .disabled(!c.offers(loaded.task, form, .answers(form.answers)))
      if showDetails {
        Text(TaskText.osmNotice(session.osmServer)).font(.footnote).foregroundStyle(.secondary)
      }
    }
  }

  /// "Something's wrong here": the challenge's outcomes, Too hard to tell, and Skip.
  @ViewBuilder private func problems(_ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm) -> some View {
    let outcomes = form.outcomes.filter { c.offers(loaded.task, form, .outcome($0)) }
    let canSkip = c.offers(loaded.task, form, .skip)
    if !outcomes.isEmpty || canSkip {
      Divider().padding(.vertical, 4)
      Button(Wording.somethingWrong, systemImage: "exclamationmark.bubble") { showProblems = true }
        .frame(maxWidth: .infinity, minHeight: 44)
        .confirmationDialog(Wording.somethingWrong, isPresented: $showProblems, titleVisibility: .visible) {
          // Lightest first: Skip, then "can't check", then the challenge's outcomes.
          if canSkip { Button(Wording.skip(noun)) { c.perform(.skip) } }
          if let tooHard = outcomes.first(where: { $0.id == ChoiceOutcome.tooHardID }) {
            Button(Wording.cantCheck(noun)) { choose(c, loaded, form, .outcome(tooHard)) }
          }
          ForEach(outcomes.filter { $0.id != ChoiceOutcome.tooHardID }) { outcome in
            Button(outcome.label) { choose(c, loaded, form, .outcome(outcome)) }
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text(Wording.problemsMessage(noun, gone: outcomes.first { $0.deletesElement || $0.id == "gone" }?.label))
        }
    }
  }

  /// Outcomes run directly, except a delete, which always confirms.
  private func choose(_ c: TaskWorkController, _ loaded: LoadedTask, _ form: ChoiceForm, _ action: ChoiceAction) {
    switchNotice = nil
    if case .outcome(let outcome) = action, outcome.deletesElement, let me = session.view.userID {
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

  @ViewBuilder private func preview(_ work: ChoiceWork) -> some View {
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
          d.savedForLater
            ? Wording.savedForLater(campaigns.checkedToday(d.loaded.challenge.id.value), noun)
            : Wording.saved(campaigns.checkedToday(d.loaded.challenge.id.value), noun))
      } icon: {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
      }
      .font(.title3.weight(.semibold))
      if d.savedForLater && campaigns.checkedToday(d.loaded.challenge.id.value) <= 3 {
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
    if let next = nextPlace {
      bigButton(
        Wording.next(noun, distance: TaskLocation.directionText(here, next.coordinate)), prominent: prominent
      ) { open(next) }
    } else {
      Text("That was the last \(noun.one) to check. Thank you!").foregroundStyle(.secondary)
    }
    backButton()
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
