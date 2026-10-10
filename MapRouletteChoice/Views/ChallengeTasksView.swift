import CoreLocation
import MapRoulette
import SwiftUI

/// One challenge's open multiple-choice tasks, as a list sorted by distance or on a map.
struct ChallengeTasksView: View {
  let challengeID: ChallengeID

  @Environment(AppSession.self) private var session
  @Environment(TaskChanges.self) private var changes

  enum Mode: String, CaseIterable, Identifiable {
    case list = "List", map = "Map"
    var id: Self { self }
  }

  @State private var mode = Mode.list
  @State private var client: SessionClient?
  @State private var challenge: Challenge?
  @State private var tasks: [LocatedTask] = []
  @State private var hidden = 0
  @State private var truncated = false
  @State private var status = "Loading tasks…"
  @State private var failed = false
  @State private var request: Task<Void, Never>?
  @State private var origin: CLLocationCoordinate2D?
  @State private var locationNote: String?
  @State private var locator = Locator()
  @State private var showInstructions = false

  /// Pages of 100 to read before stopping.
  private static let maxPages = 10

  private var sorted: [LocatedTask] { TaskLocation.sorted(tasks, from: origin) }

  var body: some View {
    VStack(spacing: 0) {
      Picker("View", selection: $mode) {
        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)
      switch mode {
      case .list: list
      case .map:
        TaskMapView(styleURL: session.mapStyleURL, tasks: tasks) { id in
          navigate(to: id)
        }
        .ignoresSafeArea(edges: .bottom)
      }
    }
    .navigationTitle(challenge?.name ?? "Challenge \(challengeID.value)")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(item: $selected) { selection in
      TaskView(taskID: selection.id, order: selection.order)
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Instructions", systemImage: "info.circle") { showInstructions = true }
          .disabled(challenge == nil)
      }
    }
    .sheet(isPresented: $showInstructions) { instructions }
    .onAppear {
      if client == nil {
        client = session.newClient()
        load()
        locate()
      }
    }
    .onDisappear { locator.stop() }
    .onChange(of: session.view.generation) {
      client = session.newClient()
      load()
    }
    .onChange(of: changes.version) { load() }
  }

  private struct Selection: Identifiable, Hashable {
    let id: Int64
    let order: [Int64]
  }
  @State private var selected: Selection?

  private func navigate(to id: Int64) {
    selected = Selection(id: id, order: sorted.map(\.id))
  }

  private var list: some View {
    List {
      Section {
        if tasks.isEmpty {
          HStack {
            if request != nil { ProgressView() }
            Text(status).foregroundStyle(.secondary)
          }
          if failed { Button("Retry") { load() } }
        }
        ForEach(sorted) { task in
          Button {
            navigate(to: task.id)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(task.task.name).foregroundStyle(.primary)
                Text(verbatim: "Task \(task.id) · \(TaskText.status(task.task.status?.code))")
                  .font(.footnote).foregroundStyle(.secondary)
              }
              Spacer()
              if let text = distance(task) {
                Text(text).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
              }
            }
          }
        }
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          if let locationNote { Text(locationNote) }
          if !tasks.isEmpty { Text(summary) }
        }
      }
    }
    .refreshable { load(); await request?.value }
    .toolbar {
      ToolbarItem(placement: .bottomBar) {
        Button("Sort by my location", systemImage: "location") { locate() }
      }
    }
  }

  private var instructions: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if let description = challenge?.description, !description.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(description)
          }
          let text = (challenge?.instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          Text(text.isEmpty ? "No challenge instructions." : text).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .navigationTitle(challenge?.name ?? "Instructions")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Done") { showInstructions = false } }
    }
  }

  private var summary: String {
    var parts = ["\(tasks.count) open tasks."]
    if hidden > 0 { parts.append("\(hidden) others are hidden: answered, locked in a bundle or not multiple-choice.") }
    if truncated { parts.append("Only the first \(Self.maxPages * 100) tasks were read.") }
    return parts.joined(separator: " ")
  }

  private func distance(_ task: LocatedTask) -> String? {
    guard let origin, let c = task.coordinate else { return nil }
    let meters = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
      .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
    return TaskLocation.distance(meters)
  }

  private func load() {
    guard let client = client?.client else { return }
    request?.cancel()
    failed = false
    status = "Loading tasks…"
    request = Task {
      do {
        let loadedChallenge = try await client.getChallenge(challengeID)
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
        // Only tasks this app can complete in place: valid, open, unbundled choice tasks.
        let open = all.filter { $0.mobileSupport() == .inPlace }
        challenge = loadedChallenge
        tasks = open.map(LocatedTask.init)
        hidden = all.count - open.count
        truncated = cursor != nil
        status = open.isEmpty ? "No open multiple-choice tasks in this challenge." : ""
      } catch is CancellationError {
        return
      } catch {
        tasks = []
        status = ChallengePickerView.errorMessage(error)
        failed = true
      }
      request = nil
    }
  }

  private func locate() {
    locationNote = "Finding your location…"
    locator.locate { result in
      switch result {
      case .found(let coordinate):
        origin = coordinate
        locationNote = "Sorted by distance from you."
      case .denied: locationNote = "Location permission declined, so tasks are in id order."
      case .unavailable: locationNote = "Location is unavailable, so tasks are in id order."
      case .timedOut: locationNote = "No location received, so tasks are in id order."
      }
    }
  }
}
