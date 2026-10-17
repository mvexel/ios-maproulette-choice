import AuthenticationServices
import CoreLocation
import MapRoulette
import SwiftUI

/// One campaign: progress, the nearest place still to check, and all its places on a map or in a
/// list sorted by distance. Checked places stay visible, greyed out.
/// From a preview link (design/preview-mode.md) a draft opens in preview: a banner, no tally,
/// no sharing, nothing written or remembered. A published campaign opens normally with a note.
struct ChallengeTasksView: View {
  let challengeID: ChallengeID

  @Environment(AppSession.self) private var session
  @Environment(TaskChanges.self) private var changes
  @Environment(CampaignStore.self) private var campaigns
  @Environment(GuestOutbox.self) private var outbox
  @Environment(CampaignCache.self) private var cache
  @Environment(\.webAuthenticationSession) private var webAuth
  @AppStorage(SettingsKey.showOSMDetails) private var showDetails = false

  init(challengeID: ChallengeID, preview: CampaignPreview? = nil) {
    self.challengeID = challengeID
    _preview = State(initialValue: preview)
  }

  /// Set while previewing; cleared when the link turns out to open a published campaign.
  @State private var preview: CampaignPreview?
  /// The preview link opened a published campaign: answers are real (§3.3). For this visit only.
  @State private var publishedNote = false

  enum Mode: String, CaseIterable, Identifiable {
    case map = "Map", list = "List"
    var id: Self { self }
  }

  /// A place to open, with the campaign's places for "next nearest".
  struct Selection: Identifiable, Hashable {
    let id: Int64
    let candidates: [LocatedTask]
    /// The places on the campaign map, for the task screen's close-up map.
    var neighbours: [Neighbour] = []
  }

  @State private var mode = Mode.map
  /// The top section's own height, so its scroll view at accessibility sizes hugs it.
  @State private var summaryHeight: CGFloat?
  @State private var client: SessionClient?
  @State private var challenge: Challenge?
  @State private var tasks: [LocatedTask] = []
  @State private var noun = Noun.place
  /// The campaign's questions (first seen wins), for the welcome card.
  @State private var questions: [ChoiceQuestion] = []
  @State private var hidden = 0
  /// Open tasks held by someone's saved guest answer: shown and counted as checked.
  @State private var held: Set<Int64> = []
  /// Open tasks held by someone's saved report (an outcome that sets status 6): need another look.
  @State private var heldReports: Set<Int64> = []
  /// Open tasks the bounds search offers (fresh, choice, held ones included); nil when it couldn't
  /// be read in full, and then every open task counts.
  @State private var offered: Set<Int64>?
  /// Tasks someone reported as not here or moved. The campaign status read (E1/E2) will fill
  /// this; until then only the demo does.
  @State private var serverReports: [Int64: TaskReport] = [:]
  @State private var truncated = false
  @State private var status = "Loading…"
  @State private var failed = false
  @State private var keptTimer: Task<Void, Never>?
  /// Waiting answers the server turned down since the last campaign screen (offline-copy.md row 17).
  @State private var notNeededLine: String?
  /// Shown from the phone's copy (no connection, O2): when the server last sent it.
  @State private var keptFrom: Date?
  @State private var request: Task<Void, Never>?
  @State private var origin: CLLocationCoordinate2D?
  @State private var locationIsOff = false
  private var locationNote: String? {
    origin == nil ? Wording.locationUnavailable(noun, isOff: locationIsOff) : nil
  }
  @State private var locator = Locator()
  @State private var selected: Selection?
  @State private var sheet: Sheet?

  enum Sheet: String, Identifiable {
    case welcome, share, putOnMap, daySummary
    var id: Self { self }
  }

  /// Pages of 100 to read before stopping: the wizard makes campaigns of up to 2,000 places (L1).
  private static let maxPages = 50

  private var progress: CampaignProgress {
    // Pending reports, this phone's or another guest's, need another look, not "checked"
    // (not-here-moved.md).
    CampaignProgress(
      tasks: tasks, justDone: campaigns.justDone, held: held.subtracting(lookAgain), waiting: waitingIDs,
      offered: preview == nil ? offered : nil, answerable: answerable)
  }
  /// A guest's answers kept on this phone until there's signal (O1): neither open nor counted.
  private var waitingIDs: Set<Int64> { preview == nil ? outbox.waiting(in: challengeID.value) : [] }
  /// A phone that answered in a dead spot before it could register is a guest too, as far as its
  /// waiting answers go: they register it when they send (Tess, Android #45).
  private var answersAsGuest: Bool {
    session.view.guest || (preview == nil && !outbox.isEmpty && session.canAnswerAsGuest)
  }
  /// A guest's saved answers: checked here, but not on the map until they finish signing up.
  private var pendingIDs: Set<Int64> {
    session.view.guest ? Set(tasks.filter { !$0.isDone && campaigns.justDone.contains($0.id) }.map(\.id)) : []
  }
  /// Open places; in preview also those whose questions don't parse, so the organizer sees why.
  private func answerable(_ task: LocatedTask) -> Bool {
    task.isOpen || (preview != nil && CampaignPreview.invalidSurvey(task.task))
  }
  private var doneIDs: Set<Int64> { progress.done }
  /// Reports from the server, and this device's since launch (design/not-here-moved.md §4).
  private var reports: [Int64: TaskReport] { serverReports.merging(campaigns.justReported) { $1 } }
  private var lookAgain: Set<Int64> { campaigns.lookAgain(reports).union(heldReports) }
  private var open: [LocatedTask] { TaskLocation.sorted(progress.open, from: origin) }
  private var checked: [LocatedTask] {
    let done = doneIDs
    return TaskLocation.sorted(tasks.filter { done.contains($0.id) }, from: origin)
  }
  /// The campaign's size for progress: held places still count (they're answered, just not on the map yet).
  private var total: Int { progress.total }
  /// Open, held and checked places (and, in preview, broken surveys); the rest are left off the map and list.
  private var shown: [LocatedTask] { progress.shown }

  var body: some View {
    GeometryReader { geo in
      VStack(spacing: 8) {
        if let preview, preview.phase == .signInNeeded || preview.phase == .noAccess {
          previewGate(preview)
          Spacer()
        } else {
          if typeSize.isAccessibilitySize {
            // At accessibility sizes the top section can outgrow the screen and push the tally under
            // the navigation bar; it hugs its content up to half the height, then scrolls.
            ScrollView {
              summary.onGeometryChange(for: CGFloat.self, of: \.size.height) { summaryHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Room so the last line clears the pinned button when scrolled to the end.
            .contentMargins(.bottom, 16, for: .scrollContent)
            .frame(height: min(summaryHeight.map { $0 + 16 } ?? geo.size.height / 2, geo.size.height / 2))
          } else {
            summary
          }
          if let locationNote {
            Text(locationNote).font(.subheadline).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal)
          }
          Picker("View", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal)
          switch mode {
          case .map:
            TaskMapView(
              styleURL: session.mapStyleURL, tasks: shown, done: doneIDs, pending: pendingIDs, waiting: waitingIDs,
              reports: reports, flagged: campaigns.justFlagged.union(heldReports), origin: origin, noun: noun
            ) { id in navigate(to: id) }
              .background(Color(.secondarySystemBackground))
              .overlay {
                if tasks.isEmpty && request != nil { ProgressView("Loading…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
              }
              .ignoresSafeArea(edges: .bottom)
          case .list: list
          }
        }
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if let preview, preview.showsBanner { PreviewBanner(preview: preview) }
    }
    .navigationTitle(challenge?.name ?? "Campaign")
    .navigationBarTitleDisplayMode(.inline)
    // The top section's scroll view runs under the bar; an opaque bar (solid, not the system
    // material) keeps scrolled text from showing through it.
    .toolbarBackground(typeSize.isAccessibilitySize ? .visible : .automatic, for: .navigationBar)
    .toolbarBackground(
      typeSize.isAccessibilitySize ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.bar), for: .navigationBar)
    .navigationDestination(item: $selected) { selection in
      TaskView(
        taskID: selection.id, candidates: selection.candidates, reports: reports, heldReports: heldReports,
        noun: noun, userLocation: origin, preview: preview, neighbours: selection.neighbours)
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu("More", systemImage: "ellipsis.circle") {
          Button("About this campaign", systemImage: "info.circle") { sheet = .welcome }
          // A preview link isn't for participants (§4.2).
          if preview == nil { Button("Share campaign", systemImage: "qrcode") { sheet = .share } }
          Button("Update my location", systemImage: "location") { locate() }
        }
      }
    }
    .sheet(item: $sheet) { which in
      switch which {
      case .welcome: welcome
      case .putOnMap: PutOnMapCard()
      case .daySummary:
        DaySummaryCard(
          checkedToday: campaigns.checkedToday(challengeID.value), done: progress.checked, total: total, noun: noun,
          onMap: myAnswers?.onMap ?? 0, pending: myAnswers?.pending ?? 0, waiting: waitingIDs.count)
      case .share: share
      }
    }
    .onAppear {
      campaigns.opened(challengeID.value, preview: preview)
      // One campaign kept (O2): opening another lets the old copy go. Previews keep nothing.
      if preview == nil { cache.keepOnly(challengeID.value) }
      if client == nil {
        client = session.newClient()
        load()
        // First visit: the welcome card explains location before the system asks.
        if campaigns.hasSeenWelcome(challengeID.value, preview: preview) { locate() }
      }
    }
    .onDisappear { locator.stop() }
    .onChange(of: session.view.generation) {
      client = session.newClient()
      load()
    }
    .onChange(of: session.view.userID) {
      // Signing in from the preview's sign-in card (or a restore finishing) may open the draft.
      if preview != nil { load() }
    }
    .onChange(of: changes.version) {
      // A save went through, so there may be signal for the ones waiting.
      outbox.flush(session, campaigns)
      load()
      Task { await session.refreshGuestStatus() }
    }
    .task {
      outbox.flush(session, campaigns)
      await session.refreshGuestStatus()
    }
    .onChange(of: outbox.signalReturns) {
      // Back online while showing the phone's copy (or after failing to load): load the server's,
      // which drops places checked or gone meanwhile.
      if keptFrom != nil || failed { load() }
    }
    .onChange(of: outbox.sentVersion) {
      // A waiting answer reached the server: the tally and "Your answers" catch up.
      load()
      Task { await session.refreshGuestStatus() }
    }
    .alert(Wording.pendingLimit(noun), isPresented: Binding(get: { outbox.limitReached }, set: { outbox.limitReached = $0 })) {
      Button("OK", role: .cancel) {}
    }
    .onChange(of: outbox.notNeeded, initial: true) {
      // Shown once, on this screen, until it closes (offline-copy.md row 17).
      guard preview == nil, outbox.notNeeded > 0 else { return }
      notNeededLine = Wording.waitingNotNeeded(outbox.notNeeded)
      outbox.notNeeded = 0
    }
  }

  #if DEBUG
    /// Screenshot shortcuts, once per launch: `-demoMap` shows the map, `-demoList` the list, and
    /// `-demoTask <id>` opens that place. Each skips the welcome card.
    private static var demoRouted = false
    private func demoRoute() {
      guard !Self.demoRouted else { return }
      Self.demoRouted = true
      let args = ProcessInfo.processInfo.arguments
      if args.contains("-demoReported") { serverReports = DemoBackend.seededReports(DemoBackend.demoCampaign(args)) }
      guard args.contains(where: { ["-demoMap", "-demoList", "-demoTask"].contains($0) }) else { return }
      sheet = nil
      campaigns.welcomeClosed(challengeID.value, preview: preview)
      // Closing the welcome card would have asked for the location; distances need it.
      if origin == nil { locate() }
      if args.contains("-demoList") { mode = .list }
      if let i = args.firstIndex(of: "-demoTask"), i + 1 < args.count, let id = Int64(args[i + 1]) {
        navigate(to: id)
      }
    }
  #endif

  private func navigate(to id: Int64) {
    let done = doneIDs
    let look = lookAgain
    let waiting = waitingIDs
    let neighbours = shown.compactMap { task -> Neighbour? in
      guard let c = task.coordinate else { return nil }
      let state: Neighbour.State =
        done.contains(task.id) || waiting.contains(task.id) ? .checked : look.contains(task.id) ? .look : .open
      return Neighbour(id: task.id, latitude: c.latitude, longitude: c.longitude, state: state)
    }
    selected = Selection(
      id: id, candidates: shown.filter { answerable($0) && !held.contains($0.id) && !waiting.contains($0.id) },
      neighbours: neighbours)
  }

  // MARK: Summary

  @Environment(\.dynamicTypeSize) private var typeSize

  @ViewBuilder private var summary: some View {
    VStack(spacing: 8) {
      if publishedNote {
        Text(Wording.previewAlreadyPublished).font(.subheadline.weight(.semibold))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      // Preview hides the tally: nothing changes it (§4.2).
      if !shown.isEmpty && preview == nil {
        let done = progress.checked
        let today = campaigns.checkedToday(challengeID.value)
        // Side by side until accessibility sizes, then stacked so neither line truncates.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        layout {
          Text(Wording.progress(done: done, total: total, noun)).foregroundStyle(.primary)
          if !typeSize.isAccessibilitySize { Spacer() }
          if today > 0 { Text("You've checked \(today) today").foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.subheadline)
        // The tally above reads the same count; the bar alone is a 4 pt sliver.
        ProgressView(value: Double(done), total: Double(max(total, 1)))
          .accessibilityHidden(true)
      } else if shown.isEmpty {
        HStack {
          if request != nil { ProgressView() }
          Text(status).foregroundStyle(.secondary)
          if failed { Button("Retry") { load() } }
        }
      }
      if let notNeededLine {
        Text(notNeededLine)
          .font(.footnote).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if truncated {
        Text(Wording.notAllShown(Self.maxPages * 100, noun))
          .font(.footnote).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let keptFrom {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(Wording.keptCopy(Wording.keptTime(keptFrom, now: context.date)))
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      if preview == nil, answersAsGuest, (myAnswers.map { $0.pending > 0 || $0.onMap > 0 } ?? false) || !waitingIDs.isEmpty {
        savedBanner(myAnswers ?? .zero, waiting: waitingIDs.count)
        Button(Wording.doneForToday) { sheet = .daySummary }.font(.subheadline).frame(minHeight: 44)
      }
      // Reported places stay open but aren't sent to anyone (design/not-here-moved.md §4).
      if let nearest = open.first(where: { !lookAgain.contains($0.id) }) {
        Button {
          if origin != nil { navigate(to: nearest.id) }
          else { mode = .list }
        } label: {
          // The icon alone reads "Orient To Phone".
          Label {
            Text(Wording.nearest(noun, distance: TaskLocation.distanceText(origin, nearest.coordinate), hasOrigin: origin != nil))
          } icon: {
            Image(systemName: origin != nil ? "location.north.circle.fill" : "list.bullet").accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
      } else if !shown.isEmpty {
        Text("All \(noun.many) are checked. Thank you!").font(.headline)
      }
    }
    .padding(.horizontal)
    .padding(.top, 8)
  }

  /// This guest's answers in this campaign. Before backend H1c there are no per-campaign counts,
  /// so the overall pending count stands in (and nothing shows as on the map).
  private var myAnswers: ChallengeAnswerCounts? {
    guard let saved = session.guestStatus else { return nil }
    return saved.byChallenge.isEmpty
      ? ChallengeAnswerCounts(pending: saved.pendingCount, onMap: 0) : saved.answers(in: challengeID)
  }

  /// "Your answers": a guest's saved answers (handback §1). They are kept until a mapper has
  /// checked them, so there is no deadline. The whole row opens the sheet (Iris's parity pick 1).
  private func savedBanner(_ mine: ChallengeAnswerCounts, waiting: Int) -> some View {
    Button {
      sheet = .putOnMap
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          // First while any wait on the phone; they aren't counted yet (offline-copy.md).
          if waiting > 0 { Text(Wording.waitingForSignal(waiting)) }
          // n counts every answer, so it never drops when one goes on the map (Iris's review).
          if mine.pending + mine.onMap > 0 { Text(Wording.savedNotOnMap(mine.pending + mine.onMap, noun)) }
          if mine.onMap > 0 {
            Text(Wording.onMap(mine.onMap)).accessibilityLabel(Wording.onMapSpoken(mine.onMap))
          }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        Spacer()
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .accessibilityHint("Shows what happens to your answers")
  }

  // MARK: List

  private var list: some View {
    List {
      Section {
        ForEach(open) { task in
          Button {
            navigate(to: task.id)
          } label: {
            row(task, done: false)
          }
        }
      } header: {
        if !open.isEmpty { Text("To check") }
      }
      let waiting = TaskLocation.sorted(tasks.filter { waitingIDs.contains($0.id) }, from: origin)
      if !waiting.isEmpty {
        Section(Wording.waitingToSend) {
          // The heading says it; VoiceOver still reads it per row.
          ForEach(waiting) { task in row(task, done: false, waiting: true) }
        }
      }
      if !checked.isEmpty {
        Section("Already checked") {
          ForEach(checked) { task in row(task, done: true, pending: pendingIDs.contains(task.id)) }
        }
      }
      if showDetails && (hidden > 0 || truncated) {
        Section {
        } footer: {
          Text(detailsFooter)
        }
      }
    }
    .refreshable { load(); await request?.value }
  }

  private func row(_ task: LocatedTask, done: Bool, pending: Bool = false, waiting: Bool = false) -> some View {
    HStack {
      if done {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(Wording.placeName(task.task, noun)).foregroundStyle(done ? Color.secondary : Color.primary)
        if !waiting && !done && !pending && lookAgain.contains(task.id) {
          Text(Wording.needsAnotherLook).font(.footnote).foregroundStyle(Color.secondary)
        }
        if showDetails {
          Text(verbatim: "\(task.task.name) · Task \(task.id) · \(TaskText.status(task.task.status?.code))")
            .font(.footnote).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if let text = TaskLocation.rowText(origin, task.coordinate) {
        // Color.secondary, not .secondary: inside a button label the latter takes the accent tint.
        Text(text).font(.subheadline.monospacedDigit()).foregroundStyle(Color.secondary)
          // "130 m northeast", without VoiceOver reading the separator.
          .accessibilityLabel(text.replacingOccurrences(of: " · ", with: " "))
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(
      waiting ? Wording.waitingToSend : pending ? "Saved, not on the map yet" : done ? "Already checked" : "")
  }

  private var detailsFooter: String {
    var parts: [String] = []
    if hidden > 0 { parts.append("\(hidden) tasks are hidden: locked in a bundle, skipped by status, or not multiple-choice.") }
    if truncated { parts.append("Only the first \(Self.maxPages * 100) tasks were read.") }
    return parts.joined(separator: " ")
  }

  /// Open tasks held by a guest's saved answer until it goes on the map or expires: the bounds
  /// search with `includePending` says so per task (backend #16), and `heldKind` whether the hold
  /// is a report (T-002). A backend without `pending` leaves the held set to what the
  /// `excludePending` search leaves out; without `heldKind`, every hold is an answer. Best effort:
  /// on failure, none; a short read keeps the holds it read (L1). The same search is what the
  /// campaign offers (`offered`, backend #51): nil on failure, a short read or a backend without
  /// `pending`.
  private static func heldTasks(_ tasks: [LocatedTask], in challengeID: ChallengeID, client: MapRouletteClient)
    async -> (answers: Set<Int64>, reports: Set<Int64>, offered: Set<Int64>?)
  {
    let open = tasks.filter(\.isOpen)
    guard let bounds = TaskLocation.bounds(open.compactMap(\.coordinate)) else { return ([], [], nil) }
    let filter = TaskFilter(challengeIDs: [challengeID], bounds: bounds, choiceOnly: true, includePending: true)
    guard case let (rows, complete)? = await boxSearch(filter, client: client) else { return ([], [], nil) }
    if !rows.isEmpty, rows.allSatisfy({ $0.pending != nil }) {
      // A short read still knows its own holds; what it offers is only known in full (L1).
      let holds = rows.filter { $0.pending == true }
      return (
        Set(holds.filter { $0.heldKind != .report }.map(\.id.value)),
        Set(holds.filter { $0.heldKind == .report }.map(\.id.value)),
        complete ? Set(rows.map(\.id.value)) : nil
      )
    }
    let unheld = TaskFilter(challengeIDs: [challengeID], bounds: bounds, choiceOnly: true, excludePending: true)
    guard case let (listed, true)? = await boxSearch(unheld, client: client) else { return ([], [], nil) }
    return (Set(open.map(\.id)).subtracting(listed.map(\.id.value)), [], nil)
  }

  /// The pages of a bounds search, and whether that was all of them; nil on failure.
  private static func boxSearch(_ filter: TaskFilter, client: MapRouletteClient) async
    -> (rows: [TaskSummary], complete: Bool)?
  {
    var rows: [TaskSummary] = []
    var cursor: PageCursor?
    var pages = 0
    do {
      repeat {
        let page = try await client.findTasksInBounds(filter: filter, pageSize: 100, after: cursor)
        rows += page.items
        cursor = page.next
        pages += 1
      } while cursor != nil && pages < maxPages
    } catch {
      return nil
    }
    return (rows, cursor == nil)
  }

  // MARK: Preview

  /// A preview link that can't open the draft yet (§3): sign in, or this account has no access.
  private func previewGate(_ preview: CampaignPreview) -> some View {
    let signIn = preview.phase == .signInNeeded
    return VStack(alignment: .leading, spacing: 16) {
      Text(signIn ? Wording.previewSignInTitle : Wording.previewNoAccessTitle)
        .font(.title2.bold())
        .accessibilityAddTraits(.isHeader)
      Text(signIn ? Wording.previewSignInText : Wording.previewNoAccessText(Wording.account(session.view.userID, displayName: session.view.displayName)))
      Button {
        signInForPreview()
      } label: {
        Text(signIn ? Wording.previewSignIn : Wording.switchAccount)
          .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!session.signInAvailable)
      Button(signIn ? Wording.cancel : Wording.close) { preview.exit() }
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .padding()
  }

  /// Sign-in (or a switch: the session signs out first), for preview and for guests. The new
  /// account reloads the campaign.
  private func signInForPreview() {
    Task {
      await session.signIn { url in
        try await webAuth.authenticate(
          using: url, callbackURLScheme: AuthEndpoints.callbackScheme, preferredBrowserSession: .ephemeral)
      }
    }
  }

  // MARK: Sheets

  private var welcome: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(challenge?.name ?? "Campaign").font(.title.bold())
          if let description = challenge?.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty
          {
            Text(description)
          }
          if !open.isEmpty {
            Label("\(noun.count(open.count)) to check. Each takes about a minute.", systemImage: "checklist")
          }
          if !questions.isEmpty {
            Text("What to look for").font(.headline)
            ForEach(questions) { q in
              VStack(alignment: .leading, spacing: 2) {
                Label(q.prompt, systemImage: "questionmark.circle")
                if let help = q.description, !help.isEmpty {
                  Text(help).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 28)
                }
              }
            }
          }
          // The challenge instruction is written for web mappers ("…in your editor").
          let instruction = (challenge?.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if showDetails && !instruction.isEmpty {
            Text("Instructions for mappers").font(.headline)
            Text(instruction).font(.subheadline).textSelection(.enabled)
          }
          Label(session.canAnswerAsGuest ? Wording.guestAnswersArePublic : Wording.answersArePublic, systemImage: "map")
          Label(Wording.locationStaysOnPhone(noun), systemImage: "location")
          if preview != nil {
            if let account = Wording.account(session.view.userID, displayName: session.view.displayName) {
              Label(Wording.previewingAs(account), systemImage: "person.crop.circle")
            }
          } else if session.canAnswerAsGuest {
            Label(AppSession.noAccountNeeded, systemImage: "person.crop.circle")
          } else if !session.view.signedIn {
            Label(Wording.needsAccount, systemImage: "person.crop.circle")
          }
          Button {
            closeWelcome()
          } label: {
            Text("Let's go").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
          }
          .buttonStyle(.borderedProminent)
        }
        .padding()
      }
      .toolbar {
        Button("Close") { closeWelcome() }
      }
    }
  }

  private var share: some View {
    let url = CampaignLink.webURL(challengeID.value)
    return NavigationStack {
      VStack(spacing: 20) {
        Text("Scan to open this campaign in the app").font(.headline).multilineTextAlignment(.center)
        if let image = CampaignLink.qrCode(url) {
          Image(uiImage: image)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 280)
            .accessibilityLabel("QR code for \(challenge?.name ?? "this campaign")")
        }
        Text(url.absoluteString).font(.footnote.monospaced()).textSelection(.enabled)
        ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
          .buttonStyle(.bordered)
        Text("People need the app installed for the link to open it.")
          .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
      .padding()
      .navigationTitle(challenge?.name ?? "Share")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Done") { sheet = nil } }
    }
  }

  /// Every question asked in the campaign, in first-seen order.
  static func questions(_ tasks: [MapRouletteTask]) -> [ChoiceQuestion] {
    var seen = Set<String>()
    var result: [ChoiceQuestion] = []
    for task in tasks {
      guard case .choice(_, _, let qs, _) = task.work() else { continue }
      for q in qs where seen.insert(q.id).inserted { result.append(q) }
    }
    return result
  }

  private func closeWelcome() {
    let first = !campaigns.hasSeenWelcome(challengeID.value, preview: preview)
    campaigns.welcomeClosed(challengeID.value, preview: preview)
    sheet = nil
    if first || origin == nil { locate() }
  }

  // MARK: Loading

  private func load() {
    guard let client = client?.client else { return }
    request?.cancel()
    failed = false
    if let preview, preview.phase == .signInNeeded || preview.phase == .noAccess { preview.phase = .opening }
    if tasks.isEmpty { status = "Loading…" }
    if keptTimer == nil, preview == nil, let slow = cache.slowAfter, let kept = cache.get(challengeID.value) {
      // One bar that hangs is the usual dead spot: show the phone's copy a few seconds after the
      // first try, even if a reload restarts the request meanwhile (a session refresh does), and
      // swap in the server's list if it still arrives (Tess, dev).
      keptTimer = Task {
        try? await Task.sleep(for: slow)
        defer { keptTimer = nil }
        guard !Task.isCancelled, request != nil, tasks.isEmpty || keptFrom != nil else { return }
        show(kept)
      }
    }
    request = Task {
      do {
        let loadedChallenge = try await client.getChallenge(challengeID)
        if let preview {
          try Task.checkCancellation()
          if CampaignPreview.isPublished(loadedChallenge) {
            if preview.phase == .opening {
              // A preview link to a published campaign opens it normally, with a note (§3.3).
              self.preview = nil
              publishedNote = true
              campaigns.opened(challengeID.value, preview: nil)
            } else {
              preview.phase = .publishedNow
            }
          } else if !session.view.signedIn {
            preview.phase = .signInNeeded
            request = nil
            return
          }
        } else if loadedChallenge.enabled == false {
          // A draft opened without preview (an old link, the last campaign): nothing to answer,
          // even where the server doesn't refuse writes to drafts yet.
          challenge = loadedChallenge
          tasks = []
          status = Wording.notPublished
          request = nil
          return
        }
        var all: [MapRouletteTask] = []
        var cursor: PageCursor?
        var pages = 0
        repeat {
          let page = try await client.listTasks(challengeID, pageSize: 100, after: cursor)
          all += page.items
          cursor = page.next
          pages += 1
        } while cursor != nil && pages < Self.maxPages
        try Task.checkCancellation()
        let located = all.map(LocatedTask.init)
        let heldNow = await Self.heldTasks(located, in: challengeID, client: client)
        try Task.checkCancellation()
        held = heldNow.answers
        heldReports = heldNow.reports
        offered = heldNow.offered
        challenge = loadedChallenge
        tasks = located
        noun = Noun.from(all)
        questions = Self.questions(all)
        hidden = located.filter { !$0.isOpen && !$0.isDone }.count
        truncated = cursor != nil
        keptFrom = nil
        keptTimer?.cancel()
        keptTimer = nil
        if self.preview == nil {
          cache.save(
            .init(
              challenge: loadedChallenge, tasks: all, held: heldNow.answers, heldReports: heldNow.reports,
              offered: heldNow.offered, truncated: truncated, savedAt: Date()))
        }
        if let preview = self.preview, preview.phase == .opening {
          preview.phase = .active
          UIAccessibility.post(notification: .announcement, argument: Wording.previewAnnouncement)
        }
        if self.preview != nil && located.isEmpty {
          // "Pull down to refresh" needs the list.
          status = Wording.previewNoPlaces(noun)
          mode = .list
        } else {
          status =
            located.contains(where: { answerable($0) || $0.isDone }) ? "" : "Nothing to check in this campaign yet."
        }
        if !campaigns.hasSeenWelcome(challengeID.value, preview: self.preview) && sheet == nil { sheet = .welcome }
        #if DEBUG
          demoRoute()
        #endif
      } catch is CancellationError {
        return
      } catch {
        if let preview = self.preview, preview.phase != .active, preview.phase != .publishedNow,
          CampaignPreview.refused(error)
        {
          preview.phase = session.view.signedIn ? .noAccess : .signInNeeded
        } else if self.preview == nil, CampaignCache.isOffline(error), let kept = cache.get(challengeID.value) {
          // A dead spot: the phone's copy, answered through the outbox until the connection is back.
          show(kept)
        } else {
          if tasks.isEmpty {
            status =
              self.preview == nil && CampaignCache.isOffline(error)
              ? Wording.notKeptNoSignal : ChallengePickerView.errorMessage(error)
          }
          failed = true
        }
      }
      request = nil
    }
  }

  /// The phone's copy of this campaign (O2), shown with when it was kept.
  private func show(_ kept: CampaignCache.Snapshot) {
    let located = kept.tasks.map(LocatedTask.init)
    challenge = kept.challenge
    tasks = located
    held = kept.held
    heldReports = kept.heldReports
    offered = kept.offered
    noun = Noun.from(kept.tasks)
    questions = Self.questions(kept.tasks)
    hidden = located.filter { !$0.isOpen && !$0.isDone }.count
    truncated = kept.truncated
    keptFrom = kept.savedAt
    failed = false
    status = ""
    if !campaigns.hasSeenWelcome(challengeID.value, preview: nil) && sheet == nil { sheet = .welcome }
  }

  private func locate() {
    origin = nil
    locationIsOff = false
    locator.locate { result in
      switch result {
      case .found(let coordinate):
        origin = coordinate
      case .denied: locationIsOff = true
      case .unavailable, .timedOut: break
      }
    }
  }
}
