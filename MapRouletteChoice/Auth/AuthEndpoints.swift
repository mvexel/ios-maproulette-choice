import Foundation

/// Build configuration, read from Info.plist (set by `Config/App.xcconfig`) in every build: this
/// app talks only to the mobile-enabled backend it was built for.
struct AppConfig: Sendable {
  let baseURL: String
  let clientID: String
  let allowLoopback: Bool
  let mapStyleURL: URL

  static let defaultStyle = URL(string: "https://tiles.openfreemap.org/styles/positron")!
  /// The small map above a task: more contrast than the campaign map, so streets read at a glance.
  static let detailStyle: URL = {
    let value = (Bundle.main.infoDictionary?["MRMapDetailStyleURL"] as? String)?.trimmingCharacters(in: .whitespaces)
    return value.flatMap { $0.contains("$(") ? nil : URL(string: $0) }
      ?? URL(string: "https://tiles.openfreemap.org/styles/liberty")!
  }()

  static var current: AppConfig {
    let info = Bundle.main.infoDictionary ?? [:]
    func value(_ key: String) -> String {
      (info[key] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    #if DEBUG
      let loopback = value("MRAllowLoopback") == "YES"
    #else
      let loopback = false
    #endif
    return AppConfig(
      baseURL: value("MRBaseURL"), clientID: value("MROAuthClientID"), allowLoopback: loopback,
      mapStyleURL: URL(string: value("MRMapStyleURL")) ?? defaultStyle)
  }
}

/// One backend origin owns both credentials and SDK data; no discovery or redirect guessing.
struct AuthEndpoints: Sendable {
  struct InvalidConfiguration: Error {}

  /// The native callback registered for `MAPROULETTE_OAUTH_CLIENT_ID` (`MROAuthCallbackScheme`).
  static let callbackScheme: String = {
    let value = (Bundle.main.infoDictionary?["MROAuthCallbackScheme"] as? String)?
      .trimmingCharacters(in: .whitespaces) ?? ""
    return value.isEmpty || value.hasPrefix("$(") ? "lol.osm.maproulette.choice" : value
  }()
  static let redirect = "\(callbackScheme):/oauth2redirect"

  let origin: String
  let clientID: String
  let loopbackAllowed: Bool
  private let scheme: String, host: String, port: Int?

  var enabled: Bool { !clientID.isEmpty }
  var api: URL { URL(string: origin + "/api/v2/")! }
  var authorize: URL { URL(string: origin + "/oauth/mobile/authorize")! }
  var token: URL { URL(string: origin + "/oauth/mobile/token")! }
  var revoke: URL { URL(string: origin + "/oauth/mobile/revoke")! }
  var storageBinding: String { "\(origin)|\(clientID)" }

  init(baseURL: String, clientID: String, allowLoopback: Bool) throws {
    guard let c = URLComponents(string: baseURL), let scheme = c.scheme?.lowercased(),
      let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil,
      c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/"
    else { throw InvalidConfiguration() }
    let loopback = host == "127.0.0.1" || host == "localhost"
    guard scheme == "https" || (allowLoopback && loopback && scheme == "http") else {
      throw InvalidConfiguration()
    }
    guard clientID.isEmpty || clientID.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil
    else { throw InvalidConfiguration() }
    self.scheme = scheme
    self.host = host
    self.port = c.port
    self.clientID = clientID
    self.loopbackAllowed = allowLoopback
    origin = "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
  }

  /// Authentication requests go only to the configured origin.
  func permitsConnection(_ url: URL) -> Bool {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
    return c.scheme?.lowercased() == scheme && c.host?.lowercased() == host && c.port == port
      && c.user == nil && c.password == nil && c.fragment == nil
  }

  /// The browser callback must be exactly the registered redirect (query allowed, no fragment).
  func acceptsCallback(_ url: URL) -> Bool {
    guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let expected = URLComponents(string: Self.redirect)
    else { return false }
    return actual.scheme == expected.scheme && actual.host == expected.host
      && actual.port == expected.port && actual.path == expected.path && actual.fragment == nil
  }
}
