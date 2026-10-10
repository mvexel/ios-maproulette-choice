import Foundation
import MapRoulette

/// A draft campaign opened from a preview link (design/preview-mode.md): the organizer tries every
/// question, and nothing is written to the server or remembered on the phone. Lives in memory
/// for the visit only; leaving the campaign ends it.
@MainActor @Observable final class CampaignPreview {
  enum Phase: Equatable, Sendable {
    /// Reading the campaign to tell a draft from a published one.
    case opening
    /// Not signed in with OpenStreetMap (a guest or signed out): drafts need an organizer (§3).
    case signInNeeded
    /// Signed in, but the draft read was refused (403 or 404).
    case noAccess
    case active
    /// A refresh found the campaign published (§5). Preview answers are still never sent.
    case publishedNow
  }

  var phase = Phase.opening
  /// The welcome card was closed in this visit. Never stored: the next visit shows it again.
  var welcomeSeen = false
  /// Places "saved" in this visit, for the count in the real saved line.
  private(set) var saved: Set<Int64> = []

  /// Ends the preview and returns to the campaign picker.
  @ObservationIgnored let exit: () -> Void
  /// Reopens the campaign normally (after it was published).
  @ObservationIgnored let openForReal: () -> Void

  init(exit: @escaping () -> Void, openForReal: @escaping () -> Void) {
    self.exit = exit
    self.openForReal = openForReal
  }

  /// The banner shows once the draft is open (not over the sign-in and no-access cards).
  var showsBanner: Bool { phase == .active || phase == .publishedNow }

  func recordSaved(_ task: Int64) { saved.insert(task) }

  /// "That's N stops today" as the real campaign would count it, including `task`.
  func savedCount(including task: Int64) -> Int { saved.union([task]).count }

  /// Published for participants (§6): enabled and tagged `mobile-survey-v1`. Anything else is a
  /// draft, so an unknown `enabled` never lets a preview write.
  nonisolated static func isPublished(_ challenge: Challenge) -> Bool {
    challenge.enabled == true && challenge.tags?.contains(ChallengePickerView.publishedTag) == true
  }

  /// A draft's read refused (§6: 404 for anyone without organize rights, like an unknown id).
  nonisolated static func refused(_ error: any Error) -> Bool {
    switch (error as? MapRouletteError)?.kind {
    case .notFound?, .permission?, .authentication?: true
    default: false
    }
  }

  /// A task the app would list but can't ask about, because its questions don't parse: shown in
  /// preview so the organizer can open it and see why (§5). Mirrors the SDK's open statuses.
  nonisolated static func invalidSurvey(_ task: MapRouletteTask) -> Bool {
    task.bundleID == nil && [0, 3, 6].contains(task.status?.code ?? 0) && ChoiceWork(task.work()) == nil
  }
}

/// The campaign screens' device state goes through these, so a preview leaves nothing behind
/// (§4.4): no last campaign, no welcome seen, no checked count, no "just done".
extension CampaignStore {
  func opened(_ challenge: Int64, preview: CampaignPreview?) {
    guard preview == nil else { return }
    lastCampaign = challenge
  }

  func hasSeenWelcome(_ challenge: Int64, preview: CampaignPreview?) -> Bool {
    preview?.welcomeSeen ?? hasSeenWelcome(challenge)
  }

  func welcomeClosed(_ challenge: Int64, preview: CampaignPreview?) {
    if let preview { preview.welcomeSeen = true } else { markWelcomeSeen(challenge) }
  }

  /// Counts a finished place once: a real `.done` by this user for today, a preview save only in
  /// `preview`. Returns the `.done` it recorded.
  @discardableResult func finished(_ state: TaskScreen, preview: CampaignPreview?) -> TaskScreen.Done? {
    switch state {
    case .previewSaved(let loaded, _, _):
      preview?.recordSaved(loaded.task.id.value)
      return nil
    case .done(let d) where !d.byOther && preview == nil:
      recordChecked(d.loaded.challenge.id.value, task: d.loaded.task.id.value)
      return d
    default:
      return nil
    }
  }
}
