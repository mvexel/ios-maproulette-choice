import Foundation
import MapRoulette
import Testing

@testable import MapRouletteChoice

/// Real SDK session state with mocked registration/token/status responses. Mac native gate.
actor GuestSessionTransport: Transport {
  var registrations = 0
  var refuseToken = false
  func refuse() { refuseToken = true }
  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    switch request.url.path {
    case "/oauth/mobile/guest":
      registrations += 1
      return HTTPResponse(status: 201, body: Data(#"{"guestId":"guest-test","guestSecret":"abcdefghijklmnopqrstuvwx"}"#.utf8))
    case "/oauth/mobile/token":
      if refuseToken { return HTTPResponse(status: 401, body: Data(#"{"error":"invalid_grant"}"#.utf8)) }
      return HTTPResponse(status: 200, body: Data(#"{"access_token":"abcdefghijklmnopqrstuvwx","token_type":"Bearer","expires_in":3600,"scope":"guest"}"#.utf8))
    case "/api/v2/mobile-guest/me":
      return HTTPResponse(status: 200, body: Data(#"{"guestId":"guest-test","state":"active","pending":1,"expiresAt":"2026-12-01T00:00:00Z"}"#.utf8))
    default: throw failure(.protocolFailure)
    }
  }
}

@MainActor @Suite struct GuestSessionRecoveryTests {
  let credentials = InMemoryCredentialStore()
  let access = InMemoryCredentialStore()
  let transport = GuestSessionTransport()
  let saves = GuestSaveStore(storage: InMemoryCredentialStore())

  func session() throws -> AppSession {
    try AppSession(testConfig: AppConfig(baseURL: "https://mr-dev.osm.lol", clientID: "test-mobile",
      allowLoopback: false, mapStyleURL: AppConfig.defaultStyle, guests: true),
      credentials: credentials, guestAccess: access, guestSaves: saves, transport: transport)
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
