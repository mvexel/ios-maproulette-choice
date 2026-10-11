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
  /// Backends with a known OSM server; stage and prod target the real map.
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
  @ObservationIgnored private var transport: any Transport = URLSessionTransport()
  @ObservationIgnored private let demo: (any Transport)?
  /// This build lets participants answer before signing in (`MAPROULETTE_GUESTS`).
  let guestsEnabled: Bool
  /// The backend refused guests (e.g. turned off there); this launch falls back to signing in.
  @ObservationIgnored private var guestsRefused = false
  @ObservationIgnored private var restoration: Task<Void, Never>?
  @ObservationIgnored private var registration: Task<Bool, Never>?
  @ObservationIgnored private var guestAccess: (any CredentialStore)?
  @ObservationIgnored private(set) var guestSaves = GuestSaveStore(storage: InMemoryCredentialStore())
  private(set) var guestBinding: String?
  private(set) var guestRecoveryUnavailable = false
  nonisolated static let guestAccessUnavailable = "We couldn't restore this phone's saved-answer access. If you received a finish link, open it on a computer. Don't assume your earlier answers were removed."

  var uncertainGuestSave: GuestSaveIntent? {
    guard view.guest, let guestBinding, let intent = try? guestSaves.read(), intent.binding == guestBinding else { return nil }
    return intent
  }

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
  /// Pending guest operations are independent of authenticated task/OSM writes.
  var guestOperationsConfigured: Bool {
    demo != nil ? guestsEnabled : guestsEnabled && signInAvailable
      && Self.guestOperationsAllowed(origin: endpoints.origin)
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
      guestSaves = GuestSaveStore(storage: KeychainCredentialStore(
        service: "lol.osm.maproulette.choice.guest-save", binding: configuration.storageBinding))
      guestAccess = KeychainCredentialStore(service: "lol.osm.maproulette.choice.guest-access", binding: configuration.storageBinding)
      restoration = Task { await restore() }
    } else {
      auth = nil
      publish(signedOutMessage())
    }
  }

  #if DEBUG
    /// In-process session tests exercise the real SDK without Keychain or network.
    init(testConfig config: AppConfig, credentials: any CredentialStore,
      guestAccess: any CredentialStore, guestSaves: GuestSaveStore, transport: any Transport) throws {
      endpoints = try AuthEndpoints(baseURL: config.baseURL, clientID: config.clientID,
        allowLoopback: config.allowLoopback, allowLiveWrites: config.allowLiveWrites)
      mapStyleURL = config.mapStyleURL
      demo = nil
      guestsEnabled = config.guests
      view = SessionView(message: "")
      deletionSetting = false
      self.transport = transport
      self.guestAccess = guestAccess
      self.guestSaves = guestSaves
      let configuration = try MobileSignInConfiguration(environment: Self.environment(endpoints, writes: false),
        clientID: endpoints.clientID, redirectURI: URL(string: AuthEndpoints.redirect)!)
      auth = MobileSignIn(configuration: configuration, store: credentials, transport: transport)
      restoration = Task { await restore() }
    }

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
          message: "Demo campaign. Nothing is saved.",
          canWriteTasks: true, canEditOsm: true)
      deletionSetting = false
      if guest { guestBinding = "demo-guest" }
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
    case .signedIn: publish(signedInMessage(), detail: signedInDetail())
    case .guest: if !(await upgradeIfClaimed(auth)) { publish(signedOutMessage()) }
    case .signedOut: publish(signedOutMessage())
    case .refreshInterrupted: publish("Please sign in again.", detail: "A previous refresh was interrupted.")
    case .unreadable:
      try? guestAccess?.write(Data("unreadable".utf8))
      guestRecoveryUnavailable = true
      publish(Self.guestAccessUnavailable, detail: "Saved sign-in could not be restored.")
    }
  }

  /// Copies the SDK's account and generation into the view state.
  private func sync(_ auth: MobileSignIn) async {
    let previousGeneration = view.generation
    let previousBinding = guestBinding
    let account = await auth.account
    view.generation = await auth.generation
    view.userID = account?.userID
    view.displayName = account?.displayName
    scopes = account?.scopes ?? []
    let guest = await auth.guest
    guestBinding = guest.map { endpoints.origin + "\n" + endpoints.clientID + "\n" + $0.guestID }
    do {
      if let guest { try guestAccess?.write(Data(guest.guestID.utf8)) }
      let evidence = try guestAccess?.read()
      guestRecoveryUnavailable = account == nil && (guest.map { evidence != Data($0.guestID.utf8) } ?? (evidence != nil))
    } catch { guestRecoveryUnavailable = true }
    view.guest = account == nil && guest != nil && !guestRecoveryUnavailable
    if previousGeneration != view.generation || previousBinding != guestBinding || !view.guest {
      guestStatus = nil
      guestStatusRefreshFailed = false
      guestStatusRefreshInProgress = false
      guestStatusRequest += 1
      lastLinkEmail = nil
    }
  }

  nonisolated static let signInDidNotFinish = "Sign-in didn't finish. Please try again."

  private func signedOutMessage() -> String {
    if guestRecoveryUnavailable { return Self.guestAccessUnavailable }
    if canAnswerAsGuest { return Self.noAccountNeeded() }
    return endpoints.enabled
      ? "You can look around without signing in. Sign in with OpenStreetMap to save answers."
      : "You can look around. Signing in isn't set up in this build."
  }

  private func signedInMessage() -> String {
    let limit =
      !writesConfigured ? ""
      : !scopes.contains(Self.writeScope) || !scopes.contains(Self.tagfixScope) ? ". This sign-in can't save answers." : ""
    return "Signed in with OpenStreetMap\(limit)"
  }

  private func signedInDetail() -> String {
    "MapRoulette user \(view.userID.map(String.init) ?? "?") · scopes: \(scopes.sorted().joined(separator: " "))"
  }

  private func publish(_ message: String, detail: String? = nil) {
    let signedIn = view.userID != nil
    let writable = signedIn && writesConfigured && scopes.contains(Self.writeScope)
    view = SessionView(
      generation: view.generation, signedIn: signedIn, userID: view.userID,
      displayName: signedIn ? view.displayName : nil, message: message, detail: detail,
      canWriteTasks: writable, canEditOsm: writable && scopes.contains(Self.tagfixScope),
      guest: !signedIn && view.guest)
  }

  // MARK: Guests

  /// Without a campaign (the status line), its places are "places".
  nonisolated static func noAccountNeeded(_ noun: Noun = .place) -> String {
    "No account needed to start. Answer a few \(noun.many) first, and we'll help you put them on the map afterwards."
  }

  /// Signed out in a build that lets participants answer first, unless the backend refused guests.
  var canAnswerAsGuest: Bool {
    guestOperationsConfigured && !view.signedIn && !guestsRefused && !guestRecoveryUnavailable
  }

  /// The guest's saved answers and deadline, as last read; nil when not a guest or not read yet.
  private(set) var guestStatus: GuestStatus?
  private(set) var guestStatusRefreshFailed = false
  private(set) var guestStatusRefreshInProgress = false
  @ObservationIgnored private var guestStatusRequest = 0

  /// A guest whose answers were claimed on the web becomes that account (UX §1.5). Checked on
  /// launch. Once claimed the guest token is refused, so a failed status read still tries.
  private func upgradeIfClaimed(_ auth: MobileSignIn) async -> Bool {
    guard guestOperationsConfigured, view.guest, !guestRecoveryUnavailable else { return false }
    let generation = view.generation
    let binding = guestBinding
    await refreshGuestStatus()
    guard generation == view.generation, binding == guestBinding, view.guest else { return false }
    let status = guestStatus
    guard status == nil || status?.state == .claimed else {
      guestStatus = status
      return false
    }
    guard !guestRecoveryUnavailable, case .signedIn? = try? await auth.upgradeGuest() else { return false }
    guestStatus = nil
    await sync(auth)
    publish(Self.claimedMessage(status, canEditOsm: writesConfigured && scopes.contains(Self.writeScope) && scopes.contains(Self.tagfixScope)), detail: signedInDetail())
    return true
  }

  /// "You're signed in as rosa_slc. Your 12 answers are on the map. …"
  nonisolated static func claimedMessage(_ status: GuestStatus?, canEditOsm: Bool = true) -> String {
    let who = status?.claimedAs.map { "You're signed in as \($0.displayName)." } ?? "You're signed in with OpenStreetMap."
    let count = status?.publishedCount ?? 0
    let onMap = count == 0 ? "" : count == 1 ? " Your answer is on the map." : " Your \(count) answers are on the map."
    return who + onMap + (canEditOsm ? " New answers go straight on the map from now on." : " This app can't put new answers on the map in this build.")
  }

  /// Keep the last confirmed count/deadline on failure, visibly marked as stale.
  /// Only the latest read for this exact guest session can update the UI.
  func refreshGuestStatus() async {
    guard guestOperationsConfigured, view.guest else {
      guestStatus = nil
      guestStatusRefreshFailed = false
      guestStatusRefreshInProgress = false
      guestStatusRequest += 1
      return
    }
    guestStatusRequest += 1
    let request = guestStatusRequest
    let generation = view.generation
    let binding = guestBinding
    guestStatusRefreshInProgress = true
    defer {
      if request == guestStatusRequest { guestStatusRefreshInProgress = false }
    }
    do {
      let status = try await newClient().client.getGuestStatus()
      guard request == guestStatusRequest, generation == view.generation,
        binding == guestBinding, view.guest else { return }
      guestStatus = status
      guestStatusRefreshFailed = false
    } catch {
      guard request == guestStatusRequest, generation == view.generation,
        binding == guestBinding, view.guest else { return }
      guestStatusRefreshFailed = true
    }
  }

  /// Sends the "finish on a computer" link to `email` (again, to correct it). Throws for the
  /// card to show a plain message.
  func sendFinishLink(to email: String) async throws {
    let generation = view.generation
    let binding = guestBinding
    let status = try await newClient().client.setGuestEmail(email)
    guard generation == view.generation, binding == guestBinding, view.guest else { throw CancellationError() }
    if view.guest {
      guestStatusRequest += 1
      guestStatusRefreshFailed = false
      guestStatusRefreshInProgress = false
      guestStatus = status
      lastLinkEmail = email
    }
  }

  /// The address the link went to in this launch, for "Resend the link". Kept in memory only.
  private(set) var lastLinkEmail: String?

  /// Deletes the guest's email and saved answers on the server, then forgets the guest here.
  /// Answers already on the map stay.
  func deleteGuestData() async throws {
    guard view.guest, let auth else { return }
    try await newClient().client.deleteGuest()
    try? await auth.forgetGuest()
    if let intent = try guestSaves.read() { try guestSaves.clear(intent) }
    try guestAccess?.clear()
    guestStatus = nil
    lastLinkEmail = nil
    await sync(auth)
    publish(signedOutMessage())
  }

  /// Makes this phone a guest before its first answer (registering once; later launches restore it).
  /// False when signed in, when this build or backend has no guests, or when registering failed.
  func ensureGuest() async -> Bool {
    await restoration?.value
    if let registration { return await registration.value }
    let job = Task { await registerGuest() }
    registration = job
    let result = await job.value
    registration = nil
    return result
  }

  private func registerGuest() async -> Bool {
    guard let auth, guestOperationsConfigured, !view.signedIn else { return false }
    if await auth.guest != nil {
      // A failed marker write must retry the same retained identity, never register another.
      await sync(auth)
      publish(signedOutMessage())
      return view.guest
    }
    guard canAnswerAsGuest else { return false }
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
  func signIn(authenticate: @escaping @MainActor @Sendable (URL) async throws -> URL) async {
    guard signInAvailable, let auth else { return }
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
      publish(signedInMessage(), detail: signedInDetail())
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
    publish(guestRecoveryUnavailable ? Self.guestAccessUnavailable : "Please sign in again.", detail: "Refresh could not complete safely.")
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
    let transport = GuardedTransport(session: self, expected: expected, inner: transport)
    // The pinned SDK shares a mutation gate. Enable it for an eligible current guest only;
    // GuardedTransport still refuses every authenticated lifecycle/OSM route for that guest.
    let environment = Self.environment(endpoints,
      writes: writesConfigured || (guestOperationsConfigured && view.guest && !guestRecoveryUnavailable))
    return SessionClient(
      client: MapRouletteClient(
        environment: environment, transport: transport, allowElementDeletion: deletion,
        accessToken: { [weak self, auth] in
          guard let auth else { return nil }
          if await auth.account == nil, let guest = await auth.guest,
            await self?.guestAccessMatches(guest.guestID, expected) != true { return nil }
          do {
            return try await auth.accessToken(generation: expected)
          } catch let error as MapRouletteError {
            await self?.refreshFailed(expected)
            throw error
          }
        }))
  }

  /// Discovery clients also stay anonymous until this exact guest has durable evidence.
  private func guestAccessMatches(_ guestID: String, _ expected: Int) -> Bool {
    guard expected == view.generation, guestOperationsConfigured, view.guest, !guestRecoveryUnavailable else { return false }
    do {
      guard try guestAccess?.read() == Data(guestID.utf8) else { throw SessionFailure() }
      return true
    } catch {
      guestRecoveryUnavailable = true
      view.guest = false
      publish(Self.guestAccessUnavailable)
      return false
    }
  }

  /// Enforced below the UI: a lifecycle write leaves the device only for an allowlisted backend
  /// and a grant that includes `tasks:write`. Everything else is refused unsent.
  fileprivate func admit(_ request: HTTPRequest, _ expected: Int) throws {
    if expected != view.generation { throw CancellationError() }
    let markerRead = Self.isMarkerRead(request)
    if !view.signedIn, guestRecoveryUnavailable, request.method != .get, !markerRead {
      throw MapRouletteError(.permission)
    }
    if Self.isGuestOperation(request.url) {
      guard guestOperationsConfigured, view.guest, !view.signedIn, !guestRecoveryUnavailable,
        endpoints.permitsConnection(request.url), Self.guestRequestAllowed(request),
        let guestBinding, let guestID = guestBinding.split(separator: "\n").last,
        guestAccessMatches(String(guestID), expected) else { throw MapRouletteError(.permission) }
    } else if view.guest && request.method != .get && !markerRead {
      throw MapRouletteError(.permission)
    }
    if Self.isTaskWrite(request.url), !(view.signedIn && writesConfigured && scopes.contains(Self.writeScope)) {
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

  /// Guest eligibility is an exact allowlist, unaffected by the live OSM flag.
  nonisolated static func guestOperationsAllowed(origin: String) -> Bool {
    writeOrigins.contains(origin) || origin == "https://mr-stage.osm.lol"
  }

  nonisolated static func isGuestOperation(_ url: URL) -> Bool {
    let path = url.path
    return path == "/api/v2/mobile-guest" || path.hasPrefix("/api/v2/mobile-guest/")
      || path.range(of: #"^/api/v2/task/\d+/choice/pending/?$"#, options: .regularExpression) != nil
  }

  /// The pinned SDK's bounded map discovery is read-only despite using PUT.
  nonisolated static func isMarkerRead(_ request: HTTPRequest) -> Bool {
    let parts = request.url.path.split(separator: "/")
    return request.method == .put && parts.count == 8
      && parts.prefix(4).map(String.init) == ["api", "v2", "markers", "box"]
      && parts.suffix(4).allSatisfy { Double($0)?.isFinite == true }
  }

  /// Only the pinned SDK's guest endpoints/methods may use the shared mutation gate.
  nonisolated static func guestRequestAllowed(_ request: HTTPRequest) -> Bool {
    switch (request.method, request.url.path) {
    case (.get, "/api/v2/mobile-guest/me"), (.get, "/api/v2/mobile-guest/pending"),
      (.put, "/api/v2/mobile-guest/email"), (.delete, "/api/v2/mobile-guest"):
      return true
    default:
      return (request.method == .post || request.method == .delete)
        && request.url.path.range(of: #"^/api/v2/task/\d+/choice/pending$"#, options: .regularExpression) != nil
    }
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
  let inner: any Transport

  func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
    try await session.admit(request, expected)
    let response = try await inner.execute(request)
    try await session.received(request, response, expected)
    return response
  }
}
