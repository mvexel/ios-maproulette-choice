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
  /// Tasks someone reported as not here or moved. The campaign status read (E1/E2) will fill
  /// this; until then only the demo does.
  @State private var serverReports: [Int64: TaskReport] = [:]
  @State private var truncated = false
  @State private var status = "Loading…"
  @State private var failed = false
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

  /// Pages of 100 to read before stopping.
  private static let maxPages = 10

  private var progress: CampaignProgress {
    // Pending reports, this phone's or another guest's, need another look, not "checked"
    // (not-here-moved.md).
    CampaignProgress(
      tasks: tasks, justDone: campaigns.justDone, held: held.subtracting(lookAgain), answerable: answerable)
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
              styleURL: session.mapStyleURL, tasks: shown, done: doneIDs, pending: pendingIDs,
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
        noun: noun, userLocation: origin, preview: preview)
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
      case .putOnMap: PutOnMapCard(noun: noun)
      case .daySummary:
        DaySummaryCard(
          checkedToday: campaigns.checkedToday(challengeID.value), done: progress.checked, total: total, noun: noun)
      case .share: share
      }
    }
    .onAppear {
      campaigns.opened(challengeID.value, preview: preview)
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
      load()
      Task { await session.refreshGuestStatus() }
    }
    .task { await session.refreshGuestStatus() }
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
    selected = Selection(id: id, candidates: tasks.filter { answerable($0) && !held.contains($0.id) })
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
      if preview == nil, session.view.guest, let saved = session.guestStatus {
        if saved.state == .expired {
          Text(Wording.savedExpired).font(.subheadline).foregroundStyle(.secondary)
        } else if saved.pendingCount > 0 {
          savedBanner(saved)
          Button(Wording.doneForToday) { sheet = .daySummary }.font(.subheadline).frame(minHeight: 44)
        }
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

  /// A guest's saved answers that aren't on the map yet (deferred sign-up §1.4); amber in the
  /// last 3 days before they are removed (§1.6).
  private func savedBanner(_ saved: GuestStatus) -> some View {
    let closing = saved.expiresAt.timeIntervalSinceNow < 3 * 86400
    let stacked = typeSize.isAccessibilitySize
    let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
    return layout {
      Text(
        closing
          ? Wording.savedClosing(saved.pendingCount, noun, on: saved.expiresAt)
          : Wording.savedNotOnMap(saved.pendingCount, noun, until: saved.expiresAt)
      )
      .font(.subheadline.weight(.semibold))
      if !stacked { Spacer() }
      Button(saved.email == .none ? "Send me the link" : "Resend the link") { sheet = .putOnMap }
        .font(.subheadline)
        .frame(minHeight: 44)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(
      closing ? AnyShapeStyle(Color.orange.opacity(0.2)) : AnyShapeStyle(Color(.secondarySystemBackground)),
      in: RoundedRectangle(cornerRadius: 10))
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

  private func row(_ task: LocatedTask, done: Bool, pending: Bool = false) -> some View {
    HStack {
      if done {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(Wording.placeName(task.task, noun)).foregroundStyle(done ? Color.secondary : Color.primary)
        if !done && !pending && lookAgain.contains(task.id) {
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
      pending ? "Saved, not on the map yet" : done ? "Already checked" : "")
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
  /// on failure or a short read, none.
  private static func heldTasks(_ tasks: [LocatedTask], in challengeID: ChallengeID, client: MapRouletteClient)
    async -> (answers: Set<Int64>, reports: Set<Int64>)
  {
    let open = tasks.filter(\.isOpen)
    guard let bounds = TaskLocation.bounds(open.compactMap(\.coordinate)) else { return ([], []) }
    let filter = TaskFilter(challengeIDs: [challengeID], bounds: bounds, choiceOnly: true, includePending: true)
    guard let rows = await boxSearch(filter, client: client) else { return ([], []) }
    if !rows.isEmpty, rows.allSatisfy({ $0.pending != nil }) {
      let holds = rows.filter { $0.pending == true }
      return (
        Set(holds.filter { $0.heldKind != .report }.map(\.id.value)),
        Set(holds.filter { $0.heldKind == .report }.map(\.id.value))
      )
    }
    let unheld = TaskFilter(challengeIDs: [challengeID], bounds: bounds, choiceOnly: true, excludePending: true)
    guard let listed = await boxSearch(unheld, client: client) else { return ([], []) }
    return (Set(open.map(\.id)).subtracting(listed.map(\.id.value)), [])
  }

  /// Every page of a bounds search, or nil on failure or a short read.
  private static func boxSearch(_ filter: TaskFilter, client: MapRouletteClient) async -> [TaskSummary]? {
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
    return cursor == nil ? rows : nil
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
            Label(AppSession.noAccountNeeded(noun), systemImage: "person.crop.circle")
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
        challenge = loadedChallenge
        tasks = located
        noun = Noun.from(all)
        questions = Self.questions(all)
        hidden = located.filter { !$0.isOpen && !$0.isDone }.count
        truncated = cursor != nil
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
        } else {
          if tasks.isEmpty { status = ChallengePickerView.errorMessage(error) }
          failed = true
        }
      }
      request = nil
    }
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
