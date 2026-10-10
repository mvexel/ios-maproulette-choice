import Foundation
import MapRoulette
import Testing

@testable import MapRouletteChoice

/// Campaign preview mode (design/preview-mode.md): links, the no-write rule and §4.4 "nothing remains".
@Suite struct PreviewLinkTests {
  @Test func parsesThePreviewFlagOnBothLinkForms() {
    let scheme = URL(string: "mrchoice://challenge/3?preview=1")!
    let web = URL(string: "https://streettally.osm.lol/challenge/3?preview=1")!
    #expect(CampaignLink.challenge(from: scheme) == 3)
    #expect(CampaignLink.isPreview(scheme))
    #expect(CampaignLink.challenge(from: web) == 3)
    #expect(CampaignLink.isPreview(web))
    #expect(CampaignLink.isPreview(URL(string: "mrchoice://challenge/3?utm=qr&preview=1")!))
    #expect(!CampaignLink.isPreview(URL(string: "mrchoice://challenge/3")!))
    #expect(!CampaignLink.isPreview(URL(string: "mrchoice://challenge/3?preview=0")!))
    #expect(!CampaignLink.isPreview(URL(string: "mrchoice://challenge/3?preview")!))
    let made = CampaignLink.url(3, preview: true)
    #expect(made.absoluteString == "mrchoice://challenge/3?preview=1")
    #expect(CampaignLink.challenge(from: made) == 3 && CampaignLink.isPreview(made))
    #expect(!CampaignLink.isPreview(CampaignLink.url(3)))
  }

  @Test func publishedMeansEnabledAndTagged() throws {
    func challenge(enabled: Bool?, tags: [String]?) throws -> Challenge {
      Challenge(id: try ChallengeID(3), projectID: try ProjectID(1), name: "c", tags: tags, enabled: enabled, cooperativeType: 3)
    }
    #expect(CampaignPreview.isPublished(try challenge(enabled: true, tags: ["mobile-survey-v1"])))
    #expect(!CampaignPreview.isPublished(try challenge(enabled: false, tags: ["mobile-survey-v1"])))
    #expect(!CampaignPreview.isPublished(try challenge(enabled: true, tags: nil)))
    #expect(!CampaignPreview.isPublished(try challenge(enabled: nil, tags: ["mobile-survey-v1"])), "unknown is a draft")
  }

  @Test func draftReadRefusalsGateThePreview() {
    #expect(CampaignPreview.refused(MapRouletteError(.notFound)))
    #expect(CampaignPreview.refused(MapRouletteError(.permission)))
    #expect(!CampaignPreview.refused(MapRouletteError(.network)))
  }
}

@MainActor @Suite struct PreviewControllerTests {
  let challenge: Challenge
  init() async throws { challenge = try await makeChallenge() }

  func ops(_ reads: MapRouletteTask...) -> FakeOps {
    let ops = FakeOps(allowElementDeletion: true, challenge: challenge)
    ops.reads = reads.map(Read.task)
    // A preview never checks; if it did, this would hide the task.
    ops.check = { ChoiceEligibility(eligible: false, deleteAllowed: false, reason: .keyChanged) }
    return ops
  }

  /// A preview controller, even with a writer at hand: preview drops it.
  func previewing(_ ops: FakeOps) async -> TaskWorkController {
    let c = TaskWorkController(ops: ops, writer: Writer(me: me, canEditOsm: true), previewing: true)
    c.load(taskID)
    await c.idle()
    return c
  }

  func writes(_ ops: FakeOps) -> [String] { ops.calls.filter { !["get", "challenge"].contains($0) } }

  @Test func answersReachThePreviewSavedScreenWithoutAnyCall() async throws {
    let o = ops(try await makeTask())
    let c = await previewing(o)
    let (loaded, form, _) = try #require(c.state.answering)
    #expect(form.work.questions.map(\.id) == ["backrest", "material"], "every question, no eligibility check")
    #expect(c.canEditOsm)
    c.select(question: "backrest", option: "yes")
    c.select(question: "material", option: "wood")
    let answers = try #require(c.state.answering).1.answers
    #expect(c.offers(loaded.task, form, .answers(answers)))
    c.perform(.answers(answers))
    await c.idle()
    guard case .previewSaved(_, let saved, let action) = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(action == .answers(["backrest": "yes", "material": "wood"]))
    #expect(TaskText.tagChanges(saved, answers) == "backrest=yes, material=wood")
    #expect(Wording.wouldSet("backrest=yes, material=wood") == "Would set: backrest=yes, material=wood")
    #expect(o.calls == ["get", "challenge"])
    #expect(writes(o).isEmpty && o.submissions.isEmpty, "nothing was written")
    #expect(!c.changed, "maps and lists have nothing to reload")
  }

  @Test func everyOutcomeAndSkipNeverWrite() async throws {
    let first = await previewing(ops(try await makeTask()))
    let outcomeIDs = try #require(first.state.answering?.1.outcomes.map(\.id))
    #expect(outcomeIDs == ["not-a-bench", "gone", "too-hard"])
    for id in outcomeIDs {
      let o = ops(try await makeTask())
      let c = await previewing(o)
      let outcome = try #require(c.state.answering?.1.outcomes.first { $0.id == id })
      c.perform(.outcome(outcome))
      await c.idle()
      guard case .previewSaved = c.state else { Issue.record("\(id): \(c.state.name)"); continue }
      #expect(writes(o).isEmpty && o.submissions.isEmpty)
    }
    let o = ops(try await makeTask())
    let c = await previewing(o)
    c.perform(.skip)
    await c.idle()
    guard case .skipped(_, let uncertain) = c.state, !uncertain else { Issue.record("\(c.state.name)"); return }
    #expect(writes(o).isEmpty)
  }

  @Test func previewOpsRefuseWritesBeforeTheyReachTheClient() async throws {
    let o = ops(try await makeTask())
    let preview = PreviewTaskOps(reads: o)
    let task = try await makeTask()
    await #expect(throws: MapRouletteError.self) { try await preview.submitChoice(task, .answers(["backrest": "yes"])) }
    await #expect(throws: MapRouletteError.self) { try await preview.skipTask(taskID) }
    await #expect(throws: MapRouletteError.self) {
      try await preview.submitPendingChoice(task, .answers(["backrest": "yes"]))
    }
    #expect(o.calls.isEmpty)
  }

  @Test func invalidSurveyIsNotAvailableWithAReason() async throws {
    let broken: [String: Any] = ["meta": ["version": 2, "type": 3, "choiceVersion": 1], "questions": [Any]()]
    let t = try await makeTask(payload: broken)
    #expect(CampaignPreview.invalidSurvey(t))
    #expect(!CampaignPreview.invalidSurvey(try await makeTask()))
    let c = await previewing(ops(t))
    guard case .notAvailable = c.state else { Issue.record("\(c.state.name)"); return }
    #expect(Wording.invalidSurvey(Wording.invalidSurveyReason(t)).hasPrefix("This question set can't be shown: "))
  }

  @Test func nothingRemainsInTheCampaignStore() async throws {
    let suite = "PreviewTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CampaignStore(defaults: defaults)
    var exited = false
    let preview = CampaignPreview(exit: { exited = true }, openForReal: {})

    // Open the campaign, close the welcome card, answer a place twice and another once.
    store.opened(challenge.id.value, preview: preview)
    #expect(!store.hasSeenWelcome(challenge.id.value, preview: preview))
    store.welcomeClosed(challenge.id.value, preview: preview)
    #expect(store.hasSeenWelcome(challenge.id.value, preview: preview))
    for _ in 0..<2 {
      let c = await previewing(ops(try await makeTask()))
      c.perform(.answers(["backrest": "no"]))
      await c.idle()
      #expect(store.finished(c.state, preview: preview) == nil)
    }
    #expect(preview.savedCount(including: 42) == 1, "the same place counts once")
    #expect(preview.savedCount(including: 43) == 2)
    preview.exit()
    #expect(exited)

    #expect(store.lastCampaign == nil)
    #expect(!store.hasSeenWelcome(challenge.id.value))
    #expect(store.checkedToday(challenge.id.value) == 0)
    #expect(store.justDone.isEmpty)
    #expect(defaults.persistentDomain(forName: suite)?.isEmpty ?? true, "nothing written to UserDefaults")

    // The same calls outside preview do store state (the guard is the preview, not the calls).
    store.opened(challenge.id.value, preview: nil)
    #expect(store.lastCampaign == challenge.id.value)
  }
}
