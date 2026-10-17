import Foundation
import MapRoulette
import os

/// Public session state; contains no credentials or provider error descriptions.
struct SessionView: Equatable, Sendable {
  var generation = 0
  var signedIn = false
  var userID: Int64?
  /// The OpenStreetMap username, when the server sent one.
  var displayName: String?
  /// Participant-facing status line.
  var message: String
  /// Technical detail (account ids, revocation results), shown only with "Show OSM details".
  var detail: String? = nil
  /// The grant includes `tasks:write`. False for read-only grants and signed-out sessions.
  var canWriteTasks = false
  /// The grant includes `osm:tagfix` (with `tasks:write`): choice answers and deletes may edit OSM.
  var canEditOsm = false
  /// Not signed in, answering as a guest: answers are saved, and put on the map later.
  var guest = false
}

struct SessionFailure: Error {}

/// The SDK client of one session generation, with the deletion setting at creation.
struct SessionClient: Sendable {
  let client: MapRouletteClient
}

/// App-owned sign-in, token storage and refresh. All mutable state is on the main actor.
@MainActor @Observable final class AppSession {
  nonisolated static let readScope = "tasks:read"
  nonisolated static let writeScope = "tasks:write"
  nonisolated static let tagfixScope = "osm:tagfix"
  /// Backends with a known OSM server. Staging edits development OSM, never the real map.
  nonisolated static let osmServers = [
    "https://mr-api.osm.lol": TaskText.devOSM, "https://mr-dev.osm.lol": TaskText.devOSM,
    "https://mr-stage.osm.lol": TaskText.liveOSM, "https://mr-prod.osm.lol": TaskText.liveOSM,
  ]
  /// Deployments that may receive task writes: the dev backend under its current and planned
  /// names, both editing development OSM. Never maproulette.org.
  nonisolated static let writeOrigins: Set<String> = ["https://mr-api.osm.lol", "https://mr-dev.osm.lol"]
  /// Stage and prod edit the real OpenStreetMap; they take writes only in builds that set
  /// MAPROULETTE_ALLOW_LIVE_WRITES (off by default). Never maproulette.org.
  nonisolated static let liveWriteOrigins: Set<String> = ["https://mr-stage.osm.lol", "https://mr-prod.osm.lol"]

  let endpoints: AuthEndpoints
  /// The MapLibre style for task maps.
  let mapStyleURL: URL
  private(set) var view: SessionView
  /// Demo setting (default off): choice "gone" outcomes delete the OSM element. Off, they resolve
  /// as Not an issue. Applies to clients created afterwards; only writable builds can turn it on.
  var allowElementDeletion: Bool {
    get { deletionSetting && writesConfigured }
    set {
      deletionSetting = newValue && writesConfigured
      UserDefaults.standard.set(deletionSetting, forKey: Self.deletionKey)
    }
  }
  private var deletionSetting: Bool

  /// The SDK's sign-in (PKCE, Keychain, refresh, revocation); nil in demo mode.
  @ObservationIgnored private let auth: MobileSignIn?
  /// The signed-in grant's scopes, mirrored from `auth` for messages and the write guard.
  @ObservationIgnored private var scopes: Set<String> = []
  @ObservationIgnored private let log = Logger(subsystem: "lol.osm.maproulette.choice", category: "auth")
  @ObservationIgnored private let demo: (any Transport)?
  /// The claim a phone sign-in just started, followed until it finishes (B5 progress).
  @ObservationIgnored private var startedClaim: Int64?
  @ObservationIgnored private var claimFollower: Task<Void, Never>?
  /// This build lets participants answer before signing in (`MAPROULETTE_GUESTS`).
  let guestsEnabled: Bool
  /// The backend refused guests (e.g. turned off there); this launch falls back to signing in.
  @ObservationIgnored private var guestsRefused = false
  private static let deletionKey = "allowElementDeletion"
  private static let keychainService = "lol.osm.maproulette.choice.auth"

  var signInAvailable: Bool { endpoints.enabled && demo == nil }
  /// Task writes need sign-in and never target the production MapRoulette deployment.
  var writesConfigured: Bool {
    demo != nil
      || (signInAvailable
        && Self.writesAllowed(
          origin: endpoints.origin, loopbackAllowed: endpoints.loopbackAllowed,
          liveAllowed: endpoints.liveWritesAllowed))
  }
  /// The OSM server this build's backend edits, for confirmations and changeset links.
  var osmServer: String? { demo != nil ? TaskText.devOSM : Self.osmServers[endpoints.origin] }
  /// ASWebAuthenticationSession runs ephemeral: no cookies are shared with Safari, so every
  /// sign-in shows the OSM login and can choose an account.
  var accountHint: String {
    // Demo (screenshots) names the real map, not the dev OSM server its links use.
    let host = demo != nil ? "openstreetmap.org" : osmServer.flatMap { URL(string: $0)?.host() } ?? "openstreetmap.org"
    return "You'll sign in on \(host). No account yet? It's free to create one there."
  }

  init(config: AppConfig) {
    guard
      let endpoints = try? AuthEndpoints(
        baseURL: config.baseURL, clientID: config.clientID, allowLoopback: config.allowLoopback,
        allowLiveWrites: config.allowLiveWrites)
    else { fatalError("Invalid MAPROULETTE_BASE_URL or MAPROULETTE_OAUTH_CLIENT_ID build setting") }
    mapStyleURL = config.mapStyleURL
    self.endpoints = endpoints
    demo = nil
    guestsEnabled = config.guests
    view = SessionView(message: "")
    deletionSetting = UserDefaults.standard.bool(forKey: Self.deletionKey)
    // AuthEndpoints validated the origin and client ID. Same binding and Keychain item as
    // before the SDK helper, so existing sign-ins carry over.
    if endpoints.enabled,
      let configuration = try? MobileSignInConfiguration(
        environment: Self.environment(endpoints, writes: false), clientID: endpoints.clientID,
        redirectURI: URL(string: AuthEndpoints.redirect)!)
    {
      auth = MobileSignIn(
        configuration: configuration,
        store: KeychainCredentialStore(service: Self.keychainService, binding: configuration.storageBinding))
      Task { await restore() }
    } else {
      auth = nil
      publish(signedOutMessage())
    }
  }

  #if DEBUG
    /// Screenshot/demo mode: an in-process mock backend, signed in as user 7 (or a guest). No network.
    init(demo transport: any Transport, guest: Bool = false) {
      endpoints = try! AuthEndpoints(baseURL: "https://demo.invalid", clientID: "", allowLoopback: false)
      mapStyleURL = AppConfig.defaultStyle
      auth = nil
      demo = transport
      guestsEnabled = guest
      view =
        guest
        ? SessionView(message: "Demo campaign. Nothing is saved.", guest: true)
        : SessionView(
          signedIn: true, userID: DemoBackend.me, displayName: DemoBackend.displayName,
          message: Self.demoClaimOutcome().map { Wording.claimMessage($0, name: DemoBackend.displayName) }
            ?? "Demo campaign. Nothing is saved.",
          canWriteTasks: true, canEditOsm: true)
      deletionSetting = false
      // The demo account's grant, so a later status line (claim progress) keeps it writable.
      if !guest { scopes = [Self.readScope, Self.writeScope, Self.tagfixScope] }
      if !guest, Self.demoClaimArgument() == "progress" { followClaim(DemoBackend.claimID) }
    }
  #endif

  #if DEBUG
    /// `-demoClaim started|progress|waiting|gone|reauth|later`: the status line after a phone
    /// sign-in claimed 3 saved answers (B5), for screenshots. `progress` then follows the demo
    /// claim to its result.
    private static func demoClaimArgument() -> String? {
      let args = ProcessInfo.processInfo.arguments
      guard let i = args.firstIndex(of: "-demoClaim"), i + 1 < args.count else { return nil }
      return args[i + 1]
    }

    private static func demoClaimOutcome() -> ClaimOutcome? {
      switch demoClaimArgument() {
      case "started", "progress": return .started(pending: 3, waiting: false)
      case "waiting": return .started(pending: 3, waiting: true)
      case "gone": return .gone
      case "reauth": return .reauth
      case "later": return .later
      default: return nil
      }
    }
  #endif

  private static func environment(_ endpoints: AuthEndpoints, writes: Bool) -> MapRouletteEnvironment {
    try! MapRouletteEnvironment(serviceURL: endpoints.api, allowWrites: writes)
  }

  // MARK: State

  private func restore() async {
    guard let auth else { return }
    let result = await auth.restore()
    await sync(auth)
    switch result {
    case .signedIn:
      // A guest kept from a phone sign-in whose claim didn't finish: try again (same claim).
      publishClaim(await claimKeptGuest(auth))
    case .guest: if !(await upgradeIfClaimed(auth)) { publish(signedOutMessage()) }
    case .signedOut: publish(signedOutMessage())
    case .refreshInterrupted: publish("Please sign in again.", detail: "A previous refresh was interrupted.")
    case .unreadable: publish("Please sign in again.", detail: "Saved sign-in could not be restored.")
    }
  }

  /// Copies the SDK's account and generation into the view state.
  private func sync(_ auth: MobileSignIn) async {
    let account = await auth.account
    view.generation = await auth.generation
    view.userID = account?.userID
    view.displayName = account?.displayName
    scopes = account?.scopes ?? []
    let guest = await auth.guest
    view.guest = account == nil && guest != nil
  }

  nonisolated static let signInDidNotFinish = "Sign-in didn't finish. Please try again."

  private func signedOutMessage() -> String {
    if canAnswerAsGuest { return Self.noAccountNeeded }
    return endpoints.enabled
      ? "You can look around without signing in. Sign in with OpenStreetMap to save answers."
      : "You can look around. Signing in isn't set up in this build."
  }

  private func signedInMessage() -> String {
    let limit =
      !writesConfigured ? ""
      : !scopes.contains(Self.writeScope) || !scopes.contains(Self.tagfixScope) ? " This sign-in can't save answers." : ""
    return Wording.signedIn(view.displayName) + limit
  }

  private func signedInDetail() -> String {
    "MapRoulette user \(view.userID.map(String.init) ?? "?") · scopes: \(scopes.sorted().joined(separator: " "))"
  }

  private func publish(_ message: String, detail: String? = nil) {
    let signedIn = view.userID != nil
    let writable = signedIn && scopes.contains(Self.writeScope)
    view = SessionView(
      generation: view.generation, signedIn: signedIn, userID: view.userID,
      displayName: signedIn ? view.displayName : nil, message: message, detail: detail,
      canWriteTasks: writable, canEditOsm: writable && scopes.contains(Self.tagfixScope),
      guest: !signedIn && view.guest)
  }

  // MARK: Guests

  /// The welcome card and the status line (handback §1).
  nonisolated static let noAccountNeeded = "No account needed. Local mappers check your answers and add them to the map."

  /// Signed out in a build that lets participants answer first, unless the backend refused guests.
  var canAnswerAsGuest: Bool {
    guestsEnabled && writesConfigured && !view.signedIn && !guestsRefused
  }

  /// The guest's saved answers and deadline, as last read; nil when not a guest or not read yet.
  private(set) var guestStatus: GuestStatus?

  /// A guest whose answers were claimed on the web becomes that account (UX §1.5). Checked on
  /// launch. Once claimed the guest token is refused, so a failed status read still tries.
  private func upgradeIfClaimed(_ auth: MobileSignIn) async -> Bool {
    let status = try? await newClient().client.getGuestStatus()
    guard status == nil || status?.state == .claimed else {
      guestStatus = status
      return false
    }
    guard case .signedIn? = try? await auth.upgradeGuest() else { return false }
    guestStatus = nil
    await sync(auth)
    publish(Self.claimedMessage(status), detail: signedInDetail())
    return true
  }

  /// "You're signed in as rosa_slc. Your 12 answers are on the map. …"
  nonisolated static func claimedMessage(_ status: GuestStatus?) -> String {
    let who = status?.claimedAs.map { "You're signed in as \($0.displayName)." } ?? "You're signed in with OpenStreetMap."
    let count = status?.publishedCount ?? 0
    let onMap = count == 0 ? "" : count == 1 ? " Your answer is on the map." : " Your \(count) answers are on the map."
    return who + onMap + " New answers go straight on the map from now on."
  }

  /// What happened to a kept guest's saved answers after a phone sign-in (deferred sign-up B5).
  enum ClaimOutcome: Equatable {
    case started(pending: Int, waiting: Bool)
    /// Unknown, expired, deleted or claimed by another account: the guest is gone.
    case gone
    /// The server's OpenStreetMap permission lapsed: sign in again.
    case reauth
    /// A network or server failure: the guest stays, and the next launch tries again.
    case later
  }

  /// After a phone sign-in, puts the kept guest's saved answers on the map with this account.
  /// Nil when there is nothing to claim or this sign-in can't edit OSM. Also run on launch for a
  /// guest kept from a claim that didn't finish; the backend returns the same claim.
  private func claimKeptGuest(_ auth: MobileSignIn) async -> ClaimOutcome? {
    guard writesConfigured, await auth.guest != nil, await auth.account?.canEditOsm == true else { return nil }
    let expected = view.generation
    let transport = GuardedTransport(session: self, expected: expected, inner: URLSessionTransport())
    defer { guestStatus = nil }
    do {
      let claim = try await auth.claimGuest(environment: Self.environment(endpoints, writes: true), transport: transport)
      startedClaim = claim.claimID
      return .started(pending: claim.pendingCount, waiting: claim.state == .waiting)
    } catch let error as MapRouletteError where error.reason == "not_found" || error.reason == "guest_claimed" {
      return .gone
    } catch let error as MapRouletteError where error.reason == "osm_reauth_required" {
      return .reauth
    } catch {
      log.debug("Claim failed: \(String(describing: type(of: error)), privacy: .public)")
      return .later
    }
  }

  /// Publishes what a phone sign-in's claim did, then follows a claim that is putting answers on
  /// the map until it finishes.
  private func publishClaim(_ claimed: ClaimOutcome?) {
    publish(claimed.map { Wording.claimMessage($0, name: view.displayName) } ?? signedInMessage(), detail: signedInDetail())
    defer { startedClaim = nil }
    guard case .started(pending: let pending, waiting: false)? = claimed, pending > 0, let id = startedClaim else { return }
    followClaim(id)
  }

  nonisolated static let claimPolls = 40
  nonisolated static let claimPollInterval = Duration.seconds(3)

  /// Reads the claim's progress every few seconds (`getClaimStatus`) and shows it on the status
  /// line, until it is done or failed, the session changes, or about two minutes pass; then it
  /// says the claim finishes on its own. A failed read just waits for the next one.
  private func followClaim(_ id: Int64) {
    claimFollower?.cancel()
    let generation = view.generation
    let detail = view.detail
    claimFollower = Task { [weak self] in
      for _ in 0..<Self.claimPolls {
        try? await Task.sleep(for: Self.claimPollInterval)
        guard let self, !Task.isCancelled, self.view.generation == generation, self.view.signedIn else { return }
        guard let status = try? await self.newClient().client.getClaimStatus(id) else { continue }
        // Publishing turned off meanwhile: stop, and the line already shown stays.
        guard !Task.isCancelled, self.view.generation == generation, status.state != .waiting else { return }
        self.publish(Wording.claimProgress(status), detail: detail)
        if status.state == .done || status.state == .failed { return }
      }
      guard let self, !Task.isCancelled, self.view.generation == generation else { return }
      self.publish(Wording.claimStillGoing, detail: detail)
    }
  }

  /// Re-reads the guest's status (saved count, email state, deadline). Failures keep the last one.
  func refreshGuestStatus() async {
    guard view.guest else {
      guestStatus = nil
      return
    }
    // Reads can overlap (a campaign loading while waiting answers send): one started earlier never
    // replaces a later one's count, so an answer sent in between stays shown (Tess, Android #45).
    statusReads += 1
    let read = statusReads
    let client = newClient().client
    if let status = try? await client.getGuestStatus(), view.guest, read > statusLanded {
      statusLanded = read
      guestStatus = status
    }
  }
  @ObservationIgnored private var statusReads = 0
  @ObservationIgnored private var statusLanded = 0

  /// Deletes the guest's saved answers on the server, then forgets the guest here.
  /// Answers already on the map stay.
  func deleteGuestData() async throws {
    guard view.guest, let auth else { return }
    try await newClient().client.deleteGuest()
    try? await auth.forgetGuest()
    guestStatus = nil
    await sync(auth)
    publish(signedOutMessage())
  }

  /// Makes this phone a guest before its first answer (registering once; later launches restore it).
  /// False when signed in, when this build or backend has no guests, or when registering failed.
  func ensureGuest() async -> Bool {
    guard canAnswerAsGuest else { return false }
    if view.guest { return true }
    guard let auth else { return false }
    do {
      _ = try await auth.startGuest()
      await sync(auth)
      publish(signedOutMessage())
      return view.guest
    } catch let error as MapRouletteError where error.kind == .notFound || error.kind == .authentication {
      // Guests are off on this backend, or this client may not use them: sign in instead.
      guestsRefused = true
      await sync(auth)
      publish(signedOutMessage())
      return false
    } catch {
      log.debug("Guest start failed: \(String(describing: type(of: error)), privacy: .public)")
      return false
    }
  }

  // MARK: Sign-in

  /// Browser sign-in through the SDK (authorization code with S256 PKCE). `authenticate` opens
  /// the URL in an ephemeral web authentication session and returns the callback URL. A current
  /// session (e.g. a read-only one) is signed out and revoked first.
  /// Sends a guest's answers still waiting on the phone, so the sign-in's claim takes them along
  /// (offline-copy.md: "the waiting answers go with the sign-in").
  @ObservationIgnored var beforeSignIn: (@MainActor (MapRouletteClient) async -> Void)?

  func signIn(authenticate: @escaping @MainActor @Sendable (URL) async throws -> URL) async {
    guard signInAvailable, let auth else { return }
    if view.guest { await beforeSignIn?(newClient().client) }
    // Keep the revocation result visible: the old grant may still be valid on the server.
    let revocation = view.signedIn ? await signOut() : nil
    view.userID = nil
    view.displayName = nil
    scopes = []
    publish("Opening OpenStreetMap sign-in…", detail: revocation)
    do {
      _ = try await auth.signIn(scopes: Self.scopes(Self.requestedScope(writesConfigured: writesConfigured))) {
        try await authenticate($0)
      }
      await sync(auth)
      publishClaim(await claimKeptGuest(auth))
    } catch SignInFailure.superseded {
      return  // A newer sign-in or sign-out owns the view.
    } catch {
      // Failure case only; never token content or server text.
      log.debug("Sign-in failed: \(String(describing: error), privacy: .public)")
      await sync(auth)
      switch error as? SignInFailure {
      case .canceled?: publish(Self.signInDidNotFinish, detail: "Canceled or could not complete.")
      case .denied?: publish("Sign-in was canceled on OpenStreetMap.", detail: "OAuth error: access_denied")
      case .providerError(let code)?: publish(Self.signInDidNotFinish, detail: "OAuth error: \(code)")
      case .callbackMismatch?:
        publish(Self.signInDidNotFinish, detail: "Sign-in callback did not match this app's pending request.")
      case .tokenExchange?: publish(Self.signInDidNotFinish, detail: "Sign-in failed during token exchange.")
      case .accountLookup?: publish(Self.signInDidNotFinish, detail: "Sign-in failed during account lookup.")
      default: publish(Self.signInDidNotFinish, detail: "Sign-in failed during secure storage.")
      }
    }
  }

  /// Clears locally before contacting the server; old requests cannot acquire new tokens.
  @discardableResult
  func signOut() async -> String {
    guard let auth else { return "" }
    view.userID = nil
    view.displayName = nil
    scopes = []
    publish("Signing out…")
    let result = await auth.signOut()
    await sync(auth)
    let message =
      !result.localCleared
      ? "Signed out in memory, but secure storage could not be cleared. Server revocation \(result.revocationConfirmed ? "confirmed" : "unconfirmed")."
      : result.revocationConfirmed ? "Signed out. Server revocation confirmed."
      : "Signed out locally. Server revocation could not be confirmed."
    publish("Signed out.", detail: message)
    return message
  }

  /// After a failed refresh the SDK has signed out; show it, unless a newer session took over.
  fileprivate func refreshFailed(_ expected: Int) async {
    guard let auth, view.generation == expected, await auth.account == nil else { return }
    await sync(auth)
    publish("Please sign in again.", detail: "Refresh could not complete safely.")
  }

  // MARK: Clients

  /// SDK clients bound to the current generation. After sign-out or an account switch their
  /// requests fail before sending.
  func newClient() -> SessionClient {
    let expected = view.generation
    let deletion = allowElementDeletion
    #if DEBUG
      if let demo {
        // The in-process mock never leaves the device; the staging environment only lets the
        // SDK send its writes to it.
        return SessionClient(
          client: MapRouletteClient(
            environment: .staging, transport: demo, allowElementDeletion: deletion,
            accessToken: { "demo" }))
      }
    #endif
    let transport = GuardedTransport(session: self, expected: expected, inner: URLSessionTransport())
    // The SDK sends writes only where this app's allowlist does (`writesConfigured`).
    let environment = Self.environment(endpoints, writes: writesConfigured)
    return SessionClient(
      client: MapRouletteClient(
        environment: environment, transport: transport, allowElementDeletion: deletion,
        accessToken: { [weak self, auth] in
          guard let auth else { return nil }
          do {
            return try await auth.accessToken(generation: expected)
          } catch let error as MapRouletteError {
            await self?.refreshFailed(expected)
            throw error
          }
        }))
  }

  /// Enforced below the UI: a lifecycle write leaves the device only for an allowlisted backend
  /// and a grant that includes `tasks:write`. Everything else is refused unsent.
  fileprivate func admit(_ request: HTTPRequest, _ expected: Int) throws {
    if expected != view.generation { throw CancellationError() }
    if Self.isTaskWrite(request.url), !(writesConfigured && scopes.contains(Self.writeScope)) {
      throw MapRouletteError(.permission)
    }
  }

  fileprivate func received(_ request: HTTPRequest, _ response: HTTPResponse, _ expected: Int) async throws {
    if expected != view.generation { throw CancellationError() }
    // The rejected request is never resent: the SDK reports authentication to the caller.
    // osm_reauth_required concerns the server's OSM token, not this MapRoulette token: no refresh.
    if response.status == 401, !Self.isOsmReauth(response.body), let header = request.headers["Authorization"],
      let auth
    {
      await auth.renewAfterRejection(generation: expected, usedHeader: header)
      await refreshFailed(expected)
    }
  }

  // MARK: Rules (unit-tested)

  /// Writes and OSM edits are requested only for an allowlisted backend.
  nonisolated static func requestedScope(writesConfigured: Bool) -> String {
    writesConfigured ? "\(readScope) \(writeScope) \(tagfixScope)" : readScope
  }

  /// A new grant: read plus a subset of what was requested; `osm:tagfix` only with `tasks:write`.
  nonisolated static func acceptableGrant(_ granted: Set<String>, requested: String) -> Bool {
    MobileSignIn.acceptableGrant(granted, requested: scopes(requested))
  }

  /// A writable build whose grant lacks task writes or OSM editing: "Sign in again to save answers".
  nonisolated static func needsReconsent(writesConfigured: Bool, granted: Set<String>) -> Bool {
    writesConfigured && !(granted.contains(writeScope) && granted.contains(tagfixScope))
  }

  /// Exact origin allowlist; stage and prod only when the build enables live writes; loopback
  /// only in a debug build that enabled it for local testing.
  nonisolated static func writesAllowed(origin: String, loopbackAllowed: Bool, liveAllowed: Bool = false) -> Bool {
    guard let c = URLComponents(string: origin), c.user == nil, c.password == nil, c.path.isEmpty,
      c.query == nil, c.fragment == nil
    else { return false }
    if writeOrigins.contains(origin) || (liveAllowed && liveWriteOrigins.contains(origin)) { return true }
    return loopbackAllowed && c.scheme == "http" && (c.host == "127.0.0.1" || c.host == "localhost")
  }

  /// Any task lifecycle write (start, refreshLock, release, skip, choice or status), whatever
  /// the method. The read-only `choice/check` is not one. Unparseable URLs count as writes.
  nonisolated static func isTaskWrite(_ url: URL) -> Bool {
    guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
      return true
    }
    return path.range(
      of: #"/task/\d+/(start|refreshLock|release|skip|choice|\d+)/?$"#, options: .regularExpression)
      != nil
  }

  /// A 401 from the choice route that asks for OSM re-consent; the MapRoulette grant is still valid.
  nonisolated static func isOsmReauth(_ body: Data) -> Bool {
    ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? String
      == "osm_reauth_required"
  }

  nonisolated static func scopes(_ value: String?) -> Set<String> {
    Set((value ?? "").split(separator: " ").map(String.init))
  }

  nonisolated static func challenge(_ verifier: String) -> String { MobileSignIn.challenge(verifier) }
}

/// Binds an SDK transport to one session generation and enforces the write allowlist.
private struct GuardedTransport: Transport {
  let session: AppSession
  let expected: Int
  let inner: URLSessionTransport

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try await session.admit(request, expected)
    let response = try await inner.execute(request)
    try await session.received(request, response, expected)
    return response
  }
}
