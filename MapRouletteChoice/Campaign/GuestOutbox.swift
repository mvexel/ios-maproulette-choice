import Foundation
import MapRoulette
import Network

/// A guest's answers whose save failed for lack of connection, kept on this phone and sent later
/// (BACKLOG O1, design/offline-copy.md). Sending again is safe: the server keeps one answer per
/// task. A waiting answer is not counted anywhere until the server has it.
@MainActor @Observable final class GuestOutbox {
  struct Entry: Codable, Equatable, Sendable {
    let taskID: Int64
    let challengeID: Int64
    let answer: Answer
    let savedAt: Date
  }

  /// What was answered, stored without the task: outcomes by id, rebuilt from a fresh read.
  enum Answer: Codable, Equatable, Sendable {
    case answers([String: String])
    case outcome(String)
    case moved(latitude: Double, longitude: Double, source: String)

    init?(_ action: ChoiceAction) {
      switch action {
      case .answers(let answers): self = .answers(answers)
      case .outcome(let outcome): self = .outcome(outcome.id)
      case .moved(let spot): self = .moved(latitude: spot.latitude, longitude: spot.longitude, source: spot.source.rawValue)
      case .skip: return nil
      }
    }

    /// The submission for a fresh read of the task; nil when its outcome no longer exists.
    func submission(_ task: MapRouletteTask, outcomes: [ChoiceOutcome]) -> ChoiceSubmission? {
      switch self {
      case .answers(let answers): return .answers(answers)
      case .outcome(let id) where id == ChoiceOutcome.notHereID: return .outcome(.notHere)
      case .outcome(let id): return outcomes.first { $0.id == id }.map { .outcome($0) }
      case .moved(let latitude, let longitude, let source):
        guard let source = MovedLocation.Source(rawValue: source),
          let spot = try? MovedLocation(latitude: latitude, longitude: longitude, source: source)
        else { return nil }
        return .moved(spot)
      }
    }
  }

  /// What sending one entry came to.
  /// What sending one entry came to. `keep` stops the flush (no signal, server trouble);
  /// `later` keeps the entry but goes on with the rest.
  enum Sent: Equatable { case sent, dropped, limit, keep, later }

  /// Oldest first.
  private(set) var entries: [Entry]
  /// The server refused a waiting answer for the pending limit; shown once, the next time a
  /// campaign is open.
  var limitReached = false
  /// Bumped when an answer is sent, so lists reload and counts go up.
  private(set) var sentVersion = 0

  @ObservationIgnored private let file: URL?
  @ObservationIgnored private var flushing = false
  @ObservationIgnored private var monitor: NWPathMonitor?

  /// `file` nil keeps entries in memory only (demo runs and tests).
  init(file: URL? = GuestOutbox.defaultFile) {
    self.file = file
    entries = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
  }

  nonisolated static var defaultFile: URL? {
    try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("guest-outbox.json")
  }

  /// Task ids waiting in `challenge`.
  func waiting(in challenge: Int64) -> Set<Int64> {
    Set(entries.filter { $0.challengeID == challenge }.map(\.taskID))
  }

  /// Every waiting task id (task ids are unique across campaigns).
  var waitingIDs: Set<Int64> { Set(entries.map(\.taskID)) }

  var isEmpty: Bool { entries.isEmpty }

  /// Keeps an answer whose save failed; a newer answer for the same task replaces it.
  func add(_ entry: Entry) {
    entries.removeAll { $0.taskID == entry.taskID }
    entries.append(entry)
    save()
  }

  /// "Delete my data" and a finished claim: nothing is left waiting.
  func removeAll() {
    entries = []
    save()
  }

  /// Sends what's waiting, oldest first, and stops at the first failure that may pass (no signal,
  /// server trouble). `record` runs for each answer the server took.
  func flush(_ client: MapRouletteClient, record: @escaping @MainActor (Entry) -> Void) async {
    await flush(via: { await Self.send($0, client) }, record: record)
  }

  /// `flush` with the sending step given, for tests.
  func flush(via send: @MainActor (Entry) async -> Sent, record: @MainActor (Entry) -> Void) async {
    guard !flushing, !entries.isEmpty else { return }
    flushing = true
    defer { flushing = false }
    for entry in entries {
      let result = await send(entry)
      switch result {
      case .keep: return
      case .later: continue
      case .sent:
        remove(entry)
        record(entry)
        sentVersion += 1
      case .dropped: remove(entry)
      case .limit:
        remove(entry)
        limitReached = true
      }
    }
  }

  /// Sends what's waiting with the session's guest client; each answer the server takes is done
  /// (it was in today's count already). Nothing for a signed-in session.
  func flush(_ session: AppSession, _ campaigns: CampaignStore) {
    guard session.view.guest, !entries.isEmpty, !flushing else { return }
    let client = session.newClient().client
    Task { await flush(client) { campaigns.sent($0.taskID) } }
  }

  /// Flushes whenever the phone gets a connection while the app runs.
  func watchNetwork(_ onSignal: @escaping @MainActor () -> Void) {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { path in
      guard path.status == .satisfied else { return }
      Task { @MainActor in onSignal() }
    }
    monitor.start(queue: DispatchQueue(label: "guest-outbox.network"))
    self.monitor = monitor
  }

  private func remove(_ entry: Entry) {
    entries.removeAll { $0 == entry }
    save()
  }

  private func save() {
    guard let file else { return }
    if entries.isEmpty {
      try? FileManager.default.removeItem(at: file)
    } else if let data = try? JSONEncoder().encode(entries) {
      try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
  }

  /// One entry: a fresh read, then the same pending call a live save makes.
  nonisolated static func send(_ entry: Entry, _ client: MapRouletteClient) async -> Sent {
    do {
      let task = try await client.getTask(TaskID(entry.taskID))
      guard task.mobileSupport() == .inPlace,
        let submission = entry.answer.submission(task, outcomes: client.choiceOutcomes(task))
      else { return .dropped }
      _ = try await client.submitPendingChoice(task, submission)
      return .sent
    } catch let error as MapRouletteError {
      return outcome(error)
    } catch {
      return .later
    }
  }

  /// Gone, changed or refused places are dropped without a word, like a skipped answer
  /// (offline-copy.md); anything that may pass is kept.
  nonisolated static func outcome(_ error: MapRouletteError) -> Sent {
    if error.kind == .rateLimit, error.reason == "pending_limit" { return .limit }
    if error.problem == .outcomeUnknown || error.problem == .writesPaused { return .keep }
    switch error.kind {
    case .network, .server, .rateLimit, .authentication: return .keep
    case .protocolFailure: return .later
    case .notFound, .conflict, .validation, .permission, .http: return .dropped
    }
  }
}
