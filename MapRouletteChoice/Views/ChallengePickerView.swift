import AuthenticationServices
import MapRoulette
import SwiftUI

/// Account, then the backend's multiple-choice challenges to pick from.
struct ChallengePickerView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.webAuthenticationSession) private var webAuth

  @State private var client: SessionClient?
  @State private var challenges: [Challenge] = []
  @State private var others = 0
  @State private var truncated = false
  @State private var status = "Loading challenges…"
  @State private var failed = false
  @State private var request: Task<Void, Never>?
  @State private var signingIn = false
  @State private var search = ""

  /// Pages of 100 to read before stopping; enough for a pilot backend.
  private static let maxPages = 5
  /// `challenges.cooperative_type` for multiple-choice challenges.
  static let choiceType = 3

  var body: some View {
    @Bindable var session = session
    List {
      Section {
        Text(session.view.message).font(.subheadline).foregroundStyle(.secondary)
          .accessibilityAddTraits(.updatesFrequently)
        Button(signInLabel) { accountAction() }
          .disabled(!session.signInAvailable || signingIn)
        if session.writesConfigured {
          Toggle("Allow deleting OSM elements", isOn: $session.allowElementDeletion)
        }
      } header: {
        Text("Account")
      } footer: {
        if session.writesConfigured {
          let server = session.osmServer.map(TaskText.host) ?? "the backend's OpenStreetMap server"
          Text(verbatim: "Off (default): a “gone” answer is recorded as Not an issue. On: it deletes the element on \(server).")
        }
      }
      Section {
        if challenges.isEmpty {
          HStack {
            if request != nil { ProgressView() }
            Text(status).foregroundStyle(.secondary)
          }
          if failed { Button("Retry") { load() } }
        }
        ForEach(shown) { challenge in
          NavigationLink(value: Route.challenge(challenge.id)) {
            VStack(alignment: .leading, spacing: 2) {
              Text(challenge.name)
              if let blurb = Self.blurb(challenge) {
                Text(blurb).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
              }
            }
          }
        }
      } header: {
        Text("Multiple-choice challenges")
      } footer: {
        if !challenges.isEmpty {
          Text(footer)
        }
      }
    }
    .navigationTitle("MapRoulette Choice")
    .searchable(text: $search, prompt: "Filter challenges")
    .refreshable { load(); await request?.value }
    .onAppear {
      if client == nil {
        client = session.newClient()
        load()
      }
    }
    .onChange(of: session.view.generation) {
      client = session.newClient()
      load()
    }
  }

  private var shown: [Challenge] {
    let q = search.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return challenges }
    return challenges.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  private var footer: String {
    var parts = ["\(challenges.count) multiple-choice challenges."]
    if others > 0 { parts.append("\(others) other challenges are hidden: they cannot be answered here.") }
    if truncated { parts.append("Only the first \(Self.maxPages * 100) challenges were read.") }
    return parts.joined(separator: " ")
  }

  private static func blurb(_ c: Challenge) -> String? {
    let text = (c.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private func load() {
    guard let client = client?.client else { return }
    request?.cancel()
    failed = false
    status = "Loading challenges…"
    request = Task {
      do {
        var all: [Challenge] = []
        var cursor: PageCursor?
        var pages = 0
        repeat {
          let page = try await client.searchChallenges(pageSize: 100, after: cursor)
          all += page.items
          cursor = page.next
          pages += 1
        } while cursor != nil && pages < Self.maxPages
        try Task.checkCancellation()
        let choice = all.filter { $0.cooperativeType == Self.choiceType && $0.archived != true }
        challenges = choice.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        others = all.count - choice.count
        truncated = cursor != nil
        status = choice.isEmpty ? "No multiple-choice challenges on this backend yet." : ""
      } catch is CancellationError {
        return
      } catch {
        challenges = []
        status = Self.errorMessage(error)
        failed = true
      }
      request = nil
    }
  }

  private var needsReconsent: Bool {
    var granted = Set<String>()
    if session.view.canWriteTasks { granted.insert(AppSession.writeScope) }
    if session.view.canEditOsm { granted.insert(AppSession.tagfixScope) }
    return AppSession.needsReconsent(writesConfigured: session.writesConfigured, granted: granted)
  }

  private var signInLabel: String {
    if !session.view.signedIn { return "Sign in with OpenStreetMap" }
    return needsReconsent ? "Sign in again to enable editing" : "Sign out"
  }

  private func accountAction() {
    signingIn = true
    Task {
      defer { signingIn = false }
      if session.view.signedIn && !needsReconsent {
        await session.signOut()
      } else {
        await session.signIn { url in
          try await webAuth.authenticate(
            using: url, callbackURLScheme: AuthEndpoints.callbackScheme, preferredBrowserSession: .ephemeral)
        }
      }
    }
  }

  static func errorMessage(_ error: any Error) -> String {
    guard let error = error as? MapRouletteError else { return "Could not load the data. Please retry." }
    switch error.kind {
    case .notFound: return "Not found."
    case .authentication, .permission: return "This request is not available with the current sign-in."
    case .network: return "Could not connect to MapRoulette. Check your connection and retry."
    case .rateLimit: return "MapRoulette is limiting requests. Wait a moment and retry."
    case .server: return "MapRoulette is temporarily unavailable. Please retry."
    default: return "MapRoulette returned an unexpected response. Please retry."
    }
  }
}
