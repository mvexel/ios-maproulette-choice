import Foundation
import MapRoulette

/// The last campaign opened, kept on the phone so it opens and can be answered in a dead spot
/// (BACKLOG O2, design/offline-copy.md). One campaign only: saving another replaces it, and opening
/// another drops it. Answers made from it go through the guest outbox; the next load with signal
/// replaces the copy with the server's.
@MainActor @Observable final class CampaignCache {
  struct Snapshot: Equatable {
    let challenge: Challenge
    let tasks: [MapRouletteTask]
    let held: Set<Int64>
    let heldReports: Set<Int64>
    let offered: Set<Int64>?
    let truncated: Bool
    /// When the server last sent it.
    let savedAt: Date
  }

  @ObservationIgnored private let file: URL?
  @ObservationIgnored private var cached: Snapshot?
  @ObservationIgnored private var loaded = false

  /// How long a campaign or place may load before the kept copy is shown instead: one bar that
  /// hangs is the usual dead spot, not a clean refusal (Tess, dev). Nil waits for the server
  /// (demo runs, where a cold simulator is slow but never offline).
  @ObservationIgnored let slowAfter: Duration?

  /// `file` nil keeps the copy in memory only (demo runs and tests).
  init(file: URL? = CampaignCache.defaultFile, slowAfter: Duration? = .seconds(6)) {
    self.file = file
    self.slowAfter = slowAfter
  }

  nonisolated static var defaultFile: URL? {
    try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("campaign-cache.json")
  }

  /// The copy of campaign `id`, if that's the one kept.
  func get(_ id: Int64) -> Snapshot? {
    current().flatMap { $0.challenge.id.value == id ? $0 : nil }
  }

  /// The one campaign kept on the phone, for the picker in a dead spot.
  var kept: Snapshot? { current() }

  /// The kept copy's place `id` with its campaign, for opening a place in a dead spot.
  func task(_ id: Int64) -> (MapRouletteTask, Challenge)? {
    guard let s = current(), let task = s.tasks.first(where: { $0.id.value == id }) else { return nil }
    return (task, s.challenge)
  }

  func save(_ snapshot: Snapshot) {
    cached = snapshot
    loaded = true
    guard let file, let data = try? JSONEncoder().encode(Stored(snapshot)) else { return }
    try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// Opening campaign `id`: a copy of any other one is dropped.
  func keepOnly(_ id: Int64) {
    if let kept = current(), kept.challenge.id.value != id { clear() }
  }

  func clear() {
    cached = nil
    loaded = true
    if let file { try? FileManager.default.removeItem(at: file) }
  }

  private func current() -> Snapshot? {
    if !loaded {
      loaded = true
      cached = file.flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }?.snapshot
    }
    return cached
  }

  /// No connection (not a server's refusal): the case for showing the kept copy.
  nonisolated static func isOffline(_ error: any Error) -> Bool {
    if let error = error as? MapRouletteError { return error.kind == .network }
    return error is URLError
  }

  // MARK: Storage

  /// The snapshot as stored. The SDK's models aren't Codable, so the fields the app reads are kept.
  private struct Stored: Codable {
    var savedAt: Date
    var truncated: Bool
    var challenge: StoredChallenge
    var tasks: [StoredTask]
    var held: [Int64]
    var heldReports: [Int64]
    var offered: [Int64]?

    init(_ s: Snapshot) {
      savedAt = s.savedAt
      truncated = s.truncated
      challenge = StoredChallenge(s.challenge)
      tasks = s.tasks.map(StoredTask.init)
      held = s.held.sorted()
      heldReports = s.heldReports.sorted()
      offered = s.offered?.sorted()
    }

    var snapshot: Snapshot? {
      guard let challenge = try? challenge.challenge else { return nil }
      let tasks = self.tasks.compactMap { try? $0.task }
      return Snapshot(
        challenge: challenge, tasks: tasks, held: Set(held), heldReports: Set(heldReports), offered: offered.map(Set.init),
        truncated: truncated, savedAt: savedAt)
    }
  }

  private struct StoredChallenge: Codable {
    var id: Int64, projectID: Int64, name: String
    var instruction: String?, description: String?, tags: [String]?
    var enabled: Bool?, archived: Bool?, requiresLocal: Bool?, cooperativeType: Int?

    init(_ c: Challenge) {
      id = c.id.value
      projectID = c.projectID.value
      name = c.name
      instruction = c.instruction
      description = c.description
      tags = c.tags
      enabled = c.enabled
      archived = c.archived
      requiresLocal = c.requiresLocal
      cooperativeType = c.cooperativeType
    }

    var challenge: Challenge {
      get throws {
        Challenge(
          id: try ChallengeID(id), projectID: try ProjectID(projectID), name: name, instruction: instruction,
          description: description, tags: tags, enabled: enabled, archived: archived, requiresLocal: requiresLocal,
          cooperativeType: cooperativeType)
      }
    }
  }

  private struct StoredTask: Codable {
    var id: Int64, challengeID: Int64, name: String
    var instruction: String?, status: Int?
    var geometry: JSONValue, location: JSONValue?, cooperativeWork: JSONValue?
    var lockedBy: Int64?, completedBy: Int64?, mappedOn: String?, reviewStatus: Int?, bundleID: Int64?
    var changesetID: Int64?

    init(_ t: MapRouletteTask) {
      id = t.id.value
      challengeID = t.challengeID.value
      name = t.name
      instruction = t.instruction
      status = t.status?.code
      geometry = t.geometry
      location = t.location
      cooperativeWork = t.cooperativeWork
      lockedBy = t.lockedBy
      completedBy = t.completedBy
      mappedOn = t.mappedOn
      reviewStatus = t.reviewStatus
      bundleID = t.bundleID
      changesetID = t.changesetID
    }

    var task: MapRouletteTask {
      get throws {
        MapRouletteTask(
          id: try TaskID(id), challengeID: try ChallengeID(challengeID), name: name, instruction: instruction,
          status: status.map(TaskStatus.init(code:)), geometry: geometry, location: location,
          cooperativeWork: cooperativeWork, lockedBy: lockedBy, completedBy: completedBy, mappedOn: mappedOn,
          reviewStatus: reviewStatus, bundleID: bundleID, changesetID: changesetID)
      }
    }
  }
}
