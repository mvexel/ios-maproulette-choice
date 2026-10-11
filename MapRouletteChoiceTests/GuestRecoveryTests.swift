import Foundation
import MapRoulette
import Testing

@testable import MapRouletteChoice

@MainActor @Suite struct GuestRecoveryTests {
  let challenge: Challenge
  init() async throws { challenge = try await makeChallenge() }
  let guest = Writer(me: 0, canEditOsm: true, guest: true, guestBinding: "backend\nclient\nguest-a")

  func controller(_ ops: FakeOps, _ store: GuestSaveStore, writer: Writer? = nil) async -> TaskWorkController {
    let c = TaskWorkController(ops: ops, writer: writer ?? guest, guestSaves: store)
    c.load(taskID)
    await c.idle()
    return c
  }
  func ops() async throws -> FakeOps {
    let o = FakeOps(challenge: challenge)
    o.reads = [.task(try await makeTask())]
    return o
  }
  func uncertain(_ o: FakeOps, _ store: GuestSaveStore) async -> TaskWorkController {
    o.pending = { _ in throw failure(.network, .outcomeUnknown) }
    let c = await controller(o, store)
    c.perform(.answers(["backrest": "yes"]))
    await c.idle()
    return c
  }

  @Test func lostResponsePersistsBeforeWriteAndNeverUsesOsmRecovery() async throws {
    let store = GuestSaveStore(storage: InMemoryCredentialStore())
    let o = try await ops()
    o.pending = { submission in
      #expect(try store.read()?.answers == ["backrest": "yes"])
      throw failure(.network, .outcomeUnknown)
    }
    let c = await controller(o, store)
    c.perform(.answers(["backrest": "yes"]))
    c.perform(.answers(["backrest": "no"])) // Double-tap ignored.
    await c.idle()
    #expect(try #require(c.state.checkAgain).guest)
    #expect(c.state.done == nil)
    c.recheck(); await c.idle()
    #expect(o.calls == ["get", "challenge", "check", "pending", "receipt"])
    #expect(try store.read()?.answers == ["backrest": "yes"])
  }

  @Test func receiptFromEarlierRevisionCannotConfirmNewAnswers() async throws {
    let store = GuestSaveStore(storage: InMemoryCredentialStore())
    let o = try await ops()
    let c = await uncertain(o, store)
    o.receipt = { _ in PendingChoice(taskID: taskID, state: .pending, answeredAt: .distantPast) }
    c.recheck(); await c.idle()
    #expect(c.state.done == nil)
    #expect(try #require(c.state.checkAgain).message.contains("can't confirm these exact answers"))
    #expect(o.submissions.count == 1)
    o.pending = { _ in PendingChoice(taskID: taskID, state: .pending, answeredAt: Date()) }
    c.resendSame(); await c.idle()
    #expect(try #require(c.state.done).savedForLater)
    #expect(o.submissions == [.answers(["backrest": "yes"]), .answers(["backrest": "yes"])])
    #expect(try store.read() == nil)
  }

  @Test func recreationRestoresIntentWithoutSendingOrRecheckingEligibility() async throws {
    let storage = InMemoryCredentialStore()
    let store = GuestSaveStore(storage: storage)
    _ = await uncertain(try await ops(), store)
    let o = try await ops()
    let relaunched = await controller(o, GuestSaveStore(storage: storage))
    #expect(try #require(relaunched.state.checkAgain).action == .answers(["backrest": "yes"]))
    #expect(o.calls == ["get", "challenge"])
    #expect(o.submissions.isEmpty)
  }

  @Test func otherIdentityCannotReadResendOrReplaceOldIntent() async throws {
    let store = GuestSaveStore(storage: InMemoryCredentialStore())
    _ = await uncertain(try await ops(), store)
    let o = try await ops()
    let otherGuest = Writer(me: 0, canEditOsm: true, guest: true, guestBinding: "backend\nclient\nguest-b")
    let c = await controller(o, store, writer: otherGuest)
    c.resendSame(); await c.idle()
    c.perform(.answers(["backrest": "no"])); await c.idle()
    #expect(o.submissions.isEmpty)
    #expect(try store.read()?.binding == guest.guestBinding)
    #expect(try store.read()?.answers == ["backrest": "yes"])
  }

  @Test func wrongTaskOrNonPendingFreshResponseStaysUnconfirmed() async throws {
    for receipt in [PendingChoice(taskID: try TaskID(99), state: .pending, answeredAt: Date()),
                    PendingChoice(taskID: taskID, state: .published, answeredAt: Date())] {
      let store = GuestSaveStore(storage: InMemoryCredentialStore())
      let o = try await ops()
      o.pending = { _ in receipt }
      let c = await controller(o, store)
      c.perform(.answers(["backrest": "yes"])); await c.idle()
      #expect(c.state.done == nil)
      #expect(try #require(c.state.checkAgain).guest)
      #expect(try store.read() != nil)
    }
  }

  @Test func firstRefusalClearsSlotButRefusedResendRetainsUnknownAttempt() async throws {
    let store = GuestSaveStore(storage: InMemoryCredentialStore())
    let o = try await ops()
    o.pending = { _ in throw MapRouletteError(.rateLimit, reason: "pending_limit") }
    let c = await controller(o, store)
    c.perform(.answers(["backrest": "yes"])); await c.idle()
    #expect(c.state.answering != nil)
    #expect(try store.read() == nil)
    o.pending = { _ in throw failure(.network, .outcomeUnknown) }
    c.perform(.answers(["backrest": "no"])); await c.idle()
    o.pending = { _ in throw MapRouletteError(.rateLimit, reason: "pending_limit") }
    c.resendSame(); await c.idle()
    #expect(try #require(c.state.checkAgain).canResend == false)
    #expect(try store.read()?.answers == ["backrest": "no"])
  }

  @Test func cancellationDiscardsLateUiButRetainsUnknownIntent() async throws {
    let store = GuestSaveStore(storage: InMemoryCredentialStore())
    let o = try await ops()
    let gate = AsyncStream<Void>.makeStream()
    o.pending = { _ in
      for await _ in gate.stream { break }
      throw failure(.network, .outcomeUnknown)
    }
    let c = await controller(o, store)
    c.perform(.answers(["backrest": "yes"]))
    c.cancel(); gate.continuation.yield(); await c.idle()
    guard case .submitting = c.state else { Issue.record("Late result shown"); return }
    #expect(try store.read()?.answers == ["backrest": "yes"])
  }

  @Test func storageFailureStopsBeforePostAndReportsRecovery() async throws {
    struct BrokenStore: CredentialStore {
      func read() throws -> Data? { nil }
      func write(_ data: Data) throws { throw SessionFailure() }
      func clear() throws {}
    }
    let o = try await ops()
    let c = await controller(o, GuestSaveStore(storage: BrokenStore()))
    c.perform(.answers(["backrest": "yes"])); await c.idle()
    #expect(o.submissions.isEmpty)
    #expect(try #require(c.state.answering?.2).contains("No answers were sent"))
  }

  @Test func skipDoesNotOccupyDurableSlot() async throws {
    let store = GuestSaveStore(storage: InMemoryCredentialStore())
    let o = try await ops()
    let c = await controller(o, store)
    c.perform(.skip); await c.idle()
    #expect(try store.read() == nil)
    #expect(o.calls == ["get", "challenge", "check"])
  }

  @Test func pendingLookupWalksAllPagesBeforeReportingAbsence() async throws {
    actor Pages: Transport {
      var queries: [String?] = []
      let match: Bool
      init(match: Bool) { self.match = match }
      func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        let after = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }?.value
        queries.append(after)
        let task = after == nil || !match ? 99 : 42
        let next = after == nil ? #","next":"page-two""# : ""
        let body = "{\"items\":[{\"taskId\":\(task),\"state\":\"pending\",\"answeredAt\":\"2026-10-11T12:00:00Z\"}]\(next)}"
        return HTTPResponse(status: 200, body: Data(body.utf8))
      }
    }
    for match in [false, true] {
      let pages = Pages(match: match)
      let ops = ClientTaskOps(MapRouletteClient(transport: pages, accessToken: { "guest-token" }))
      let receipt = try await ops.pendingReceipt(taskID)
      #expect((receipt != nil) == match)
      #expect(await pages.queries == [nil, "page-two"])
    }
  }

  @Test func rateLimitBlocksResendUntilServerDelay() async throws {
    let store = GuestSaveStore(storage: InMemoryCredentialStore())
    let o = try await ops()
    o.pending = { _ in throw MapRouletteError(.rateLimit, retryAfter: "3600") }
    let c = await controller(o, store)
    c.perform(.answers(["backrest": "yes"])); await c.idle()
    #expect(try #require(c.state.checkAgain).canResend == false)
    c.recheck(); await c.idle()
    c.resendSame(); await c.idle()
    #expect(o.submissions.count == 1)
    #expect(try store.read() != nil)
  }

  #if canImport(Security)
  @Test func keychainIntentSurvivesStoreRecreationAndIsolatesBackendClient() throws {
    let service = "lol.osm.maproulette.choice.tests.guest-save." + UUID().uuidString
    let storage = KeychainCredentialStore(service: service, binding: "backend-a|client-a")
    let store = GuestSaveStore(storage: storage)
    let save = GuestSaveIntent(binding: "backend-a|client-a|guest-a", campaignID: 1, taskID: 42,
      action: .answers(["backrest": "yes"]))
    defer { try? store.clear(save) }
    #expect(try store.keep(save) == false)
    let recreated = GuestSaveStore(storage: KeychainCredentialStore(service: service, binding: "backend-a|client-a"))
    #expect(try recreated.read() == save)
    let otherClient = GuestSaveStore(storage: KeychainCredentialStore(service: service, binding: "backend-a|client-b"))
    let otherBackend = GuestSaveStore(storage: KeychainCredentialStore(service: service, binding: "backend-b|client-a"))
    #expect(try otherClient.read() == nil)
    #expect(try otherBackend.read() == nil)
  }
  #endif

  @Test func movedIntentSurvivesCodingWithExactCoordinatesAndSource() throws {
    let action = ChoiceAction.moved(try MovedLocation(latitude: 40.76123456, longitude: -111.89123456, source: .tap))
    let intent = GuestSaveIntent(binding: "guest", campaignID: 1, taskID: 42, action: action)
    let decoded = try JSONDecoder().decode(GuestSaveIntent.self, from: JSONEncoder().encode(intent))
    #expect(decoded == intent)
    #expect(decoded.latitude == 40.76123456)
    #expect(decoded.source == "tap")
  }
}
