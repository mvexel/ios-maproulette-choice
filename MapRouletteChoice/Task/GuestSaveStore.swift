import Foundation
import MapRoulette

/// One exact uncertain save, separate from the SDK's credentials. No offline queue or auto-send.
struct GuestSaveIntent: Codable, Equatable, Sendable {
  let binding: String
  let campaignID: Int64
  let taskID: Int64
  var answers: [String: String]?
  var outcomeID: String?
  var latitude: Double?
  var longitude: Double?
  var source: String?

  init(binding: String, campaignID: Int64, taskID: Int64, action: ChoiceAction) {
    self.binding = binding
    self.campaignID = campaignID
    self.taskID = taskID
    switch action {
    case .answers(let values): answers = values
    case .outcome(let outcome): outcomeID = outcome.id
    case .moved(let spot):
      latitude = spot.latitude; longitude = spot.longitude; source = spot.source.rawValue
    case .skip: break
    }
  }

  func action(_ form: ChoiceForm) -> ChoiceAction? {
    if let answers, !answers.isEmpty,
      answers.allSatisfy({ q, o in form.work.questions.contains { $0.id == q && $0.options.contains { $0.id == o } } }) {
      return .answers(answers)
    }
    if let outcomeID {
      if outcomeID == ChoiceOutcome.notHereID { return .outcome(.notHere) }
      if let outcome = form.outcomes.first(where: { $0.id == outcomeID }) { return .outcome(outcome.withoutDeletion()) }
    }
    if let latitude, let longitude, let source, let kind = MovedLocation.Source(rawValue: source),
      let spot = try? MovedLocation(latitude: latitude, longitude: longitude, source: kind) { return .moved(spot) }
    return nil
  }
}

@MainActor final class GuestSaveStore {
  private let storage: any CredentialStore
  init(storage: any CredentialStore) { self.storage = storage }

  func read() throws -> GuestSaveIntent? {
    try storage.read().map { try JSONDecoder().decode(GuestSaveIntent.self, from: $0) }
  }

  /// Refuse to overwrite another task, identity or edited attempt while its outcome is unknown.
  /// Returns true only when this exact intent already had an attempt.
  func keep(_ intent: GuestSaveIntent) throws -> Bool {
    if let earlier = try read() {
      guard earlier == intent else { throw SessionFailure() }
      return true
    }
    try storage.write(JSONEncoder().encode(intent))
    return false
  }

  func clear(_ intent: GuestSaveIntent) throws {
    if try read() == intent { try storage.clear() }
  }
}
