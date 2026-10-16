import Foundation
import MapRoulette
import Testing

@testable import MapRouletteChoice

/// A guest's answers kept on the phone until there's signal (BACKLOG O1, design/offline-copy.md).
@MainActor @Suite struct GuestOutboxTests {
  private func entry(_ task: Int64, _ answer: GuestOutbox.Answer = .answers(["backrest": "yes"])) -> GuestOutbox.Entry {
    GuestOutbox.Entry(taskID: task, challengeID: 3, answer: answer, savedAt: Date(timeIntervalSince1970: 1_000))
  }

  private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json")
  }

  @Test func storesWhatWasAnsweredAndRebuildsItFromAFreshRead() async throws {
    let task = try await makeTask()
    let offered = outcomes(task)
    let notABench = try #require(offered.first { $0.id == "not-a-bench" })
    let spot = try MovedLocation(latitude: 40.75, longitude: -111.89, source: .tap)

    #expect(GuestOutbox.Answer(.skip) == nil)
    let answers = try #require(GuestOutbox.Answer(.answers(["backrest": "yes"])))
    #expect(answers.submission(task, outcomes: offered) == .answers(["backrest": "yes"]))
    let outcome = try #require(GuestOutbox.Answer(.outcome(notABench)))
    #expect(outcome.submission(task, outcomes: offered) == .outcome(notABench))
    let notHere = try #require(GuestOutbox.Answer(.outcome(.notHere)))
    #expect(notHere.submission(task, outcomes: []) == .outcome(.notHere))
    let moved = try #require(GuestOutbox.Answer(.moved(spot)))
    #expect(moved.submission(task, outcomes: []) == .moved(spot))
    // The organizer removed the outcome meanwhile: nothing to send.
    #expect(GuestOutbox.Answer.outcome("gone-for-good").submission(task, outcomes: offered) == nil)
  }

  @Test func keepsEntriesAcrossLaunchesOnePerPlace() throws {
    let file = tempFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let outbox = GuestOutbox(file: file)
    outbox.add(entry(1))
    outbox.add(entry(2, .outcome("not-a-bench")))
    outbox.add(entry(1, .answers(["backrest": "no"])))  // a newer answer replaces the older
    #expect(outbox.entries.map(\.taskID) == [2, 1])

    let reopened = GuestOutbox(file: file)
    #expect(reopened.entries == outbox.entries)
    #expect(reopened.waiting(in: 3) == [1, 2])
    #expect(reopened.waiting(in: 4).isEmpty)

    reopened.removeAll()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(GuestOutbox(file: file).isEmpty)
  }

  @Test func sendsInOrderAndStopsWhenThereIsNoSignal() async {
    let outbox = GuestOutbox(file: nil)
    for id in [1, 2, 3, 4, 5] as [Int64] { outbox.add(entry(id)) }
    let results: [Int64: GuestOutbox.Sent] = [1: .sent, 2: .dropped, 3: .later, 4: .keep, 5: .sent]
    var tried: [Int64] = []
    var recorded: [Int64] = []
    await outbox.flush(via: { tried.append($0.taskID); return results[$0.taskID]! }, record: { recorded.append($0.taskID) })
    #expect(tried == [1, 2, 3, 4])
    #expect(recorded == [1])
    #expect(outbox.entries.map(\.taskID) == [3, 4, 5])
    #expect(outbox.sentVersion == 1)
    #expect(!outbox.limitReached)
  }

  @Test func thePendingLimitDropsTheAnswerAndSaysSoOnce() async {
    let outbox = GuestOutbox(file: nil)
    outbox.add(entry(1))
    await outbox.flush(via: { _ in .limit }, record: { _ in Issue.record("not sent") })
    #expect(outbox.isEmpty)
    #expect(outbox.limitReached)
  }

  @Test func goneOrChangedPlacesAreDroppedAndTroubleIsKept() {
    #expect(GuestOutbox.outcome(MapRouletteError(.rateLimit, status: 429, reason: "pending_limit")) == .limit)
    for kept in [
      MapRouletteError(.network), MapRouletteError(.network, problem: .outcomeUnknown), MapRouletteError(.server, status: 503),
      MapRouletteError(.permission, status: 403, problem: .writesPaused), MapRouletteError(.authentication, status: 401),
      MapRouletteError(.rateLimit, status: 429),
    ] {
      #expect(GuestOutbox.outcome(kept) == .keep, "\(kept)")
    }
    for dropped in [
      MapRouletteError(.notFound, status: 404), MapRouletteError(.conflict, status: 409, reason: "task_completed"),
      MapRouletteError(.validation, status: 400), MapRouletteError(.permission, status: 403, reason: "challenge_not_published"),
    ] {
      #expect(GuestOutbox.outcome(dropped) == .dropped, "\(dropped)")
    }
  }

  @Test func waitingPlacesAreNeitherCheckedNorOffered() async throws {
    let tasks = [LocatedTask(try await makeTask(id: 1)), LocatedTask(try await makeTask(id: 2))]
    let p = CampaignProgress(tasks: tasks, justDone: [], held: [], waiting: [2])
    #expect(p.checked == 0)
    #expect(p.total == 2)
    #expect(p.open.map(\.id) == [1])
    #expect(p.shown.map(\.id) == [1, 2])
  }

  @Test func waitingCopy() {
    let stops = Noun.from(match: ["highway": "bus_stop"])
    #expect(Wording.savedOnPhone == "Saved on this phone. It sends by itself when you have signal.")
    #expect(Wording.waitingToSend == "Waiting to send")
    #expect(Wording.waitingForSignal(1) == "1 waiting for signal")
    #expect(Wording.waitingForSignal(4) == "4 waiting for signal")
    #expect(Wording.stillOnPhone(1, stops)
      == "1 stop is still on this phone. It sends by itself when you have signal, so keep Street Tally installed until then.")
    #expect(Wording.stillOnPhone(3, stops)
      == "3 stops are still on this phone. They send by themselves when you have signal, so keep Street Tally installed until then.")
    #expect(Wording.deleteMyDataWaiting == "It also removes answers still waiting on this phone.")
    #expect(TaskMapView.Pin(done: false, pending: false, waiting: true) == .waiting)
    #expect(TaskMapView.Pin(done: false, pending: false, reported: true, waiting: true) == .waiting)
    #expect(!TaskMapView.Pin.waiting.opens)
    #expect(TaskMapView.Pin.waiting.accessibilityValue == "Waiting to send")
  }
}
