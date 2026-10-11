import Foundation
@_spi(LowLevelTaskLifecycle) import MapRoulette
import Testing

@testable import MapRouletteChoice

/// Real SDK session state with mocked registration/token/status responses. Mac native gate.
actor GuestSessionTransport: Transport {
  var paths: [String] = []
  var registrations = 0
  var refuseToken = false
  var tokenRequests = 0
  var challengeHeaders: [String?] = []
  var failStatus = false
  var failEmail = false
  var emailStored = false
  var heldStatus: CheckedContinuation<HTTPResponse, any Error>?
  var holdNextStatus = false
  func failStatusReads(_ value: Bool) { failStatus = value }
  func failEmailSend(_ value: Bool) { failEmail = value }
  func holdStatusRead() { holdNextStatus = true }
  func statusIsHeld() -> Bool { heldStatus != nil }
  func finishHeldStatus() {
    heldStatus?.resume(returning: HTTPResponse(status: 503, body: Data()))
    heldStatus = nil
  }
  func refuse() { refuseToken = true }
  func allow() { refuseToken = false }
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    paths.append(request.url.path)
    if request.method == .put && request.url.path.hasPrefix("/api/v2/markers/box/") {
      return HTTPResponse(status: 200, body: Data("[]".utf8))
    }
    switch request.url.path {
    case "/oauth/mobile/guest":
      registrations += 1
      return HTTPResponse(status: 201, body: Data(#"{"guestId":"guest-test","guestSecret":"abcdefghijklmnopqrstuvwx"}"#.utf8))
    case "/oauth/mobile/token":
      tokenRequests += 1
      if refuseToken { return HTTPResponse(status: 401, body: Data(#"{"error":"invalid_grant"}"#.utf8)) }
      return HTTPResponse(status: 200, body: Data(#"{"access_token":"abcdefghijklmnopqrstuvwx","token_type":"Bearer","expires_in":3600,"scope":"guest"}"#.utf8))
    case "/api/v2/challenge/1":
      challengeHeaders.append(request.headers["Authorization"])
      return HTTPResponse(status: 200, body: Data(#"{"id":1,"parent":2,"name":"Benches"}"#.utf8))
    case "/api/v2/task/42/choice/pending":
      return HTTPResponse(status: 200, body: Data(#"{"taskId":42,"challengeId":1,"state":"pending","answeredAt":"2026-10-11T00:00:00Z"}"#.utf8))
    case "/api/v2/mobile-guest/pending":
      return HTTPResponse(status: 200, body: Data(#"{"items":[{"taskId":42,"challengeId":1,"state":"pending","answeredAt":"2026-10-11T00:00:00Z"}]}"#.utf8))
    case "/api/v2/mobile-guest/email":
      emailStored = true
      if failEmail { return HTTPResponse(status: 503, body: Data(#"{"error":"email_unavailable"}"#.utf8)) }
      return HTTPResponse(status: 200, body: Data(#"{"guestId":"guest-test","state":"active","emailSet":true,"pending":1}"#.utf8))
    case "/api/v2/mobile-guest/me":
      if holdNextStatus {
        holdNextStatus = false
        return try await withCheckedThrowingContinuation { heldStatus = $0 }
      }
      if failStatus { return HTTPResponse(status: 503, body: Data()) }
      return HTTPResponse(status: 200, body: Data("{\"guestId\":\"guest-test\",\"state\":\"active\",\"email\":\"\(emailStored ? "pending" : "none")\",\"pending\":1,\"expiresAt\":\"2026-12-01T00:00:00Z\"}".utf8))
    default: throw failure(.protocolFailure)
    }
  }
}

@MainActor @Suite struct GuestSessionRecoveryTests {
  let credentials = InMemoryCredentialStore()
  let access = InMemoryCredentialStore()
  let transport = GuestSessionTransport()
  let saves = GuestSaveStore(storage: InMemoryCredentialStore())

  func session(guestAccess: (any CredentialStore)? = nil) throws -> AppSession {
    try AppSession(testConfig: AppConfig(baseURL: "https://mr-dev.osm.lol", clientID: "test-mobile",
      allowLoopback: false, mapStyleURL: AppConfig.defaultStyle, guests: true),
      credentials: credentials, guestAccess: guestAccess ?? access, guestSaves: saves, transport: transport)
  }

  @Test func statusFailureRetainsConfirmedStateAndIntentThenRetryClearsWarning() async throws {
    let app = try session()
    #expect(await app.ensureGuest())
    await app.refreshGuestStatus()
    let deadline = try #require(app.guestStatus?.expiresAt)
    let intent = GuestSaveIntent(binding: try #require(app.guestBinding), campaignID: 1,
      taskID: 42, action: .answers(["backrest": "yes"]))
    _ = try saves.keep(intent)
    await transport.failStatusReads(true)
    await app.refreshGuestStatus()
    #expect(app.guestStatusRefreshFailed && !app.guestStatusRefreshInProgress)
    #expect(app.guestStatus?.pendingCount == 1 && app.guestStatus?.expiresAt == deadline)
    #expect(app.guestStatus?.state == .active && app.uncertainGuestSave == intent)
    #expect(app.view.guest && !app.guestRecoveryUnavailable)
    await transport.failStatusReads(false)
    await app.refreshGuestStatus()
    #expect(!app.guestStatusRefreshFailed && !app.guestStatusRefreshInProgress)
    #expect(app.uncertainGuestSave == intent)
  }

  @Test func newerStatusReadWinsAndIdentityChangeClearsUncertainty() async throws {
    let app = try session()
    #expect(await app.ensureGuest())
    await transport.holdStatusRead()
    let oldRead = Task { await app.refreshGuestStatus() }
    while !(await transport.statusIsHeld()) { await Task.yield() }
    await app.refreshGuestStatus()
    await transport.finishHeldStatus()
    await oldRead.value
    #expect(!app.guestStatusRefreshFailed && app.guestStatus?.pendingCount == 1)
    await transport.failStatusReads(true)
    await app.refreshGuestStatus()
    #expect(app.guestStatusRefreshFailed)
    await app.signOut()
    #expect(!app.guestStatusRefreshFailed && app.guestStatus == nil)
    #expect(app.lastLinkEmail == nil)
  }

  @Test func lateStatusFailureCannotRestoreWarningAfterSignOut() async throws {
    let app = try session()
    #expect(await app.ensureGuest())
    await transport.holdStatusRead()
    let oldRead = Task { await app.refreshGuestStatus() }
    while !(await transport.statusIsHeld()) { await Task.yield() }
    await app.signOut()
    await transport.finishHeldStatus()
    await oldRead.value
    #expect(app.guestStatus == nil && !app.guestStatusRefreshFailed)
    #expect(!app.guestStatusRefreshInProgress)
  }

  @Test func failedEmailResponseCannotConfirmLinkSending() async throws {
    let app = try session()
    #expect(await app.ensureGuest())
    await transport.failEmailSend(true)
    do { try await app.sendFinishLink(to: "a@b.org"); Issue.record("Email service failure reported success") }
    catch { #expect(app.lastLinkEmail == nil) }
    await app.refreshGuestStatus()
    #expect(app.guestStatus?.email == .pending)
    #expect(app.lastLinkEmail == nil)
    let summary = Wording.daySummarySaved(until: app.guestStatus?.expiresAt)
    #expect(summary.contains("If you received a finish link"))
  }

  @Test func restoredGuestStatusFailureIsVisibleWithoutReplacement() async throws {
    let first = try session()
    #expect(await first.ensureGuest())
    await transport.failStatusReads(true)
    let relaunched = try session()
    #expect(await relaunched.ensureGuest())
    #expect(relaunched.guestStatusRefreshFailed && relaunched.guestStatus == nil)
    #expect(relaunched.guestBinding == first.guestBinding)
    #expect(await transport.registrations == 1)
  }

  @Test func concurrentGuestStartAndRelaunchKeepOneIdentity() async throws {
    let first = try session()
    async let a = first.ensureGuest()
    async let b = first.ensureGuest()
    let (one, two) = await (a, b)
    #expect(one && two)
    let relaunched = try session()
    #expect(await relaunched.ensureGuest())
    #expect(relaunched.guestBinding == first.guestBinding)
    #expect(await transport.registrations == 1)
  }

  @Test func refusedTokenDoesNotRegisterReplacementAfterRelaunch() async throws {
    let first = try session()
    #expect(await first.ensureGuest())
    await transport.refuse()
    await first.refreshGuestStatus()
    #expect(first.guestRecoveryUnavailable)
    #expect(!first.canAnswerAsGuest)
    let relaunched = try session()
    #expect(await relaunched.ensureGuest() == false)
    #expect(relaunched.guestRecoveryUnavailable)
    #expect(relaunched.view.message.contains("Don't assume your earlier answers were removed"))
    #expect(await transport.registrations == 1)
  }

  @Test func canceledPendingTokenRefusalStillProtectsGuestOnRelaunch() async throws {
    let first = try session()
    #expect(await first.ensureGuest())
    let task = try await makeTask()
    let o = FakeOps(challenge: try await makeChallenge())
    o.reads = [.task(task)]
    let client = first.newClient().client
    o.pending = { submission in try await client.submitPendingChoice(task, submission) }
    await transport.refuse()
    let c = TaskWorkController(ops: o,
      writer: Writer(me: 0, canEditOsm: true, guest: true, guestBinding: first.guestBinding), guestSaves: saves)
    c.load(taskID); await c.idle()
    c.perform(.answers(["backrest": "yes"]))
    c.cancel(); await c.idle()
    #expect(try saves.read() == nil, "A first definite refusal releases the intent slot")
    let relaunched = try session()
    #expect(await relaunched.ensureGuest() == false)
    #expect(relaunched.guestRecoveryUnavailable)
    #expect(await transport.registrations == 1)
  }

  @Test func transientMarkerFailureKeepsDiscoveryAnonymousAndRetriesSameGuest() async throws {
    final class FlakyEvidence: CredentialStore, @unchecked Sendable {
      var failing = true
      private let storage = InMemoryCredentialStore()
      func read() throws -> Data? { try storage.read() }
      func write(_ data: Data) throws {
        if failing { throw SessionFailure() }
        try storage.write(data)
      }
      func clear() throws { try storage.clear() }
    }
    let evidence = FlakyEvidence()
    let first = try session(guestAccess: evidence)
    #expect(await first.ensureGuest() == false)
    #expect(first.guestRecoveryUnavailable)
    let binding = first.guestBinding
    await transport.refuse()
    _ = try await first.newClient().client.getChallenge(ChallengeID(1))
    #expect(await transport.tokenRequests == 0)
    #expect(await transport.challengeHeaders == [nil])
    // Restore also must not attempt a raw guest_claim upgrade while evidence is unavailable.
    let relaunched = try session(guestAccess: evidence)
    #expect(await relaunched.ensureGuest() == false)
    #expect(await transport.tokenRequests == 0)
    _ = try await relaunched.newClient().client.getChallenge(ChallengeID(1))
    #expect(await transport.challengeHeaders == [nil, nil])
    evidence.failing = false
    #expect(await relaunched.ensureGuest())
    #expect(relaunched.guestBinding == binding)
    #expect(!relaunched.guestRecoveryUnavailable)
    #expect(await transport.registrations == 1)
    await transport.allow()
    _ = try await relaunched.newClient().client.getChallenge(ChallengeID(1))
    #expect(await transport.tokenRequests == 1)
    #expect(await transport.challengeHeaders.last! != nil)
  }

  @Test func unreadableCredentialsPreventReplacementRegistration() async throws {
    try credentials.write(Data("unreadable credentials".utf8))
    let app = try session()
    #expect(await app.ensureGuest() == false)
    #expect(app.guestRecoveryUnavailable)
    let relaunched = try session()
    #expect(await relaunched.ensureGuest() == false)
    #expect(await transport.registrations == 0)
  }
}

@MainActor @Suite struct StageGuestGateTests {
  func session(origin: String = "https://mr-stage.osm.lol", guests: Bool = true,
    live: Bool = false, credentials: any CredentialStore = InMemoryCredentialStore(),
    transport: GuestSessionTransport) throws -> AppSession {
    try AppSession(testConfig: AppConfig(baseURL: origin, clientID: "test-mobile",
      allowLoopback: false, allowLiveWrites: live, mapStyleURL: AppConfig.defaultStyle, guests: guests),
      credentials: credentials, guestAccess: InMemoryCredentialStore(),
      guestSaves: GuestSaveStore(storage: InMemoryCredentialStore()), transport: transport)
  }

  @Test func stageGuestCanSaveAndReadRecoveryWithoutAuthenticatedWrites() async throws {
    let transport = GuestSessionTransport()
    let app = try session(transport: transport)
    #expect(await app.ensureGuest())
    #expect(app.guestOperationsConfigured && !app.writesConfigured)
    #expect(!app.view.canWriteTasks && !app.view.canEditOsm && !app.allowElementDeletion)
    #expect(AppSession.requestedScope(writesConfigured: app.writesConfigured) == "tasks:read")
    let client = app.newClient().client
    let markers = try await client.findTaskMarkers(filter: TaskFilter(
      bounds: Bounds(west: -112, south: 40, east: -111, north: 41)))
    #expect(markers.isEmpty)
    #expect(await transport.paths.contains { $0.hasPrefix("/api/v2/markers/box/") })
    let task = try await makeTask()
    let saved = try await client.submitPendingChoice(task, .answers(["backrest": "yes"]))
    #expect(saved.state == .pending)
    let page = try await client.listPendingChoices()
    #expect(page.items.first?.taskID == taskID)
    await app.refreshGuestStatus()
    #expect(app.guestStatus?.pendingCount == 1)
    do { try await client.skipTask(taskID); Issue.record("Guest lifecycle write escaped guard") }
    catch let error as MapRouletteError { #expect(error.kind == .permission) }
    do { _ = try await client.submitChoice(task, .answers(["backrest": "yes"]))
      Issue.record("Guest OSM choice escaped guard") }
    catch let error as MapRouletteError { #expect(error.kind == .permission) }
    do { _ = try await client.startTask(taskID); Issue.record("Guest start escaped guard") }
    catch let error as MapRouletteError { #expect(error.kind == .permission) }
    do { try await client.releaseTask(taskID); Issue.record("Guest release escaped guard") }
    catch let error as MapRouletteError { #expect(error.kind == .permission) }
    #expect(await transport.paths.filter { $0.hasPrefix("/api/v2/task/") } == ["/api/v2/task/42/choice/pending"])
  }

  @Test(arguments: ["https://mr-prod.osm.lol", "https://unknown.example", "https://mr-stage.osm.lol:443", "https://mr-stage.osm.lol."])
  func ineligibleOriginCannotBecomeGuestEvenWithLiveFlag(origin: String) async throws {
    let transport = GuestSessionTransport()
    let app = try session(origin: origin, live: true, transport: transport)
    #expect(!app.guestOperationsConfigured)
    #expect(await app.ensureGuest() == false)
    #expect(await transport.paths.isEmpty)
  }

  @Test func guestFlagDefaultsOffAndDevRemainsWritable() async throws {
    let config = AppConfig(baseURL: "https://mr-stage.osm.lol", clientID: "test-mobile",
      allowLoopback: false, mapStyleURL: AppConfig.defaultStyle)
    #expect(!config.guests && !config.allowLiveWrites)
    let transport = GuestSessionTransport()
    let app = try session(guests: false, transport: transport)
    #expect(await app.ensureGuest() == false)
    #expect(await transport.paths.isEmpty)
    for origin in ["https://mr-dev.osm.lol", "https://mr-api.osm.lol"] {
      let dev = try session(origin: origin, transport: GuestSessionTransport())
      #expect(dev.writesConfigured && dev.guestOperationsConfigured)
      #expect(await dev.ensureGuest())
    }
  }

  @Test func restoredSignedInWriteGrantCannotMutateStageWhenLiveDisabled() async throws {
    let transport = GuestSessionTransport()
    let saved: [String: Any] = ["binding": "https://mr-stage.osm.lol|test-mobile", "userID": 7,
      "refreshPending": false, "grant": ["accessToken": "abcdefghijklmnopqrstuvwx",
      "refreshToken": "abcdefghijklmnopqrstuvwx", "expiresAt": Date().addingTimeInterval(3600).timeIntervalSinceReferenceDate,
      "scopes": ["tasks:read", "tasks:write", "osm:tagfix"]]]
    let store = InMemoryCredentialStore(try JSONSerialization.data(withJSONObject: saved))
    let app = try session(credentials: store, transport: transport)
    #expect(await app.ensureGuest() == false) // Waits for restoration.
    #expect(app.view.signedIn && !app.view.guest)
    #expect(!app.writesConfigured && !app.view.canWriteTasks && !app.view.canEditOsm)
    let client = app.newClient().client
    do { try await client.skipTask(taskID); Issue.record("Signed-in lifecycle write escaped SDK gate") }
    catch let error as MapRouletteError { #expect(error.kind == .validation) }
    do { _ = try await client.submitChoice(try await makeTask(), .answers(["backrest": "yes"]))
      Issue.record("Signed-in OSM write escaped SDK gate") }
    catch let error as MapRouletteError { #expect(error.kind == .validation) }
    do { _ = try await client.getGuestStatus(); Issue.record("Signed-in session used guest endpoint") }
    catch let error as MapRouletteError { #expect(error.kind == .permission) }
    #expect(await transport.paths.isEmpty)
  }
}

@MainActor @Suite struct DisabledGuestGateTests {
  @Test(arguments: ["https://mr-stage.osm.lol", "https://mr-dev.osm.lol", "https://mr-prod.osm.lol", "https://unknown.example"])
  func restoredGuestCannotUsePendingOrStatusWhenGuestFlagOff(origin: String) async throws {
    let saved: [String: Any] = ["binding": origin + "|test-mobile", "refreshPending": false,
      "guest": ["id": "guest-test", "secret": "abcdefghijklmnopqrstuvwx"]]
    let transport = GuestSessionTransport()
    let app = try StageGuestGateTests().session(origin: origin, guests: false, live: true,
      credentials: InMemoryCredentialStore(try JSONSerialization.data(withJSONObject: saved)), transport: transport)
    #expect(await app.ensureGuest() == false)
    #expect(!app.guestOperationsConfigured && !app.canAnswerAsGuest)
    let client = app.newClient().client
    do { _ = try await client.submitPendingChoice(try await makeTask(), .answers(["backrest": "yes"]))
      Issue.record("Disabled guest pending escaped guard") }
    catch let error as MapRouletteError { #expect(error.kind == .permission || error.kind == .validation) }
    do { _ = try await client.listPendingChoices(); Issue.record("Disabled guest recovery escaped guard") }
    catch let error as MapRouletteError { #expect(error.kind == .permission) }
    do { _ = try await client.getGuestStatus(); Issue.record("Disabled guest status escaped guard") }
    catch let error as MapRouletteError { #expect(error.kind == .permission) }
    #expect(await transport.paths.isEmpty)
  }
}
