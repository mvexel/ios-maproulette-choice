import AuthenticationServices
import MapRoulette
import SwiftUI

/// Account, the backend's mapping campaigns (multiple-choice challenges), and settings.
struct ChallengePickerView: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.webAuthenticationSession) private var webAuth

  @State private var client: SessionClient?
  @State private var challenges: [Challenge] = []
  @State private var others = 0
  @State private var truncated = false
  @State private var status = "Loading campaigns…"
  @State private var failed = false
  @State private var request: Task<Void, Never>?
  @State private var signingIn = false
  @State private var confirmDelete = false
  @State private var deleteResult: String?
  @State private var search = ""
  @AppStorage(SettingsKey.showOSMDetails) private var showDetails = false

  /// Pages of 100 to read before stopping; enough for a pilot backend.
  private static let maxPages = 5
  /// `challenges.cooperative_type` for multiple-choice challenges.
  static let choiceType = 3
  /// The tag the admin's "Publish" adds (`maproulette-mobile-admin` SurveyBuilder).
  static let publishedTag = "mobile-survey-v1"

  /// Unarchived choice challenges published for mobile (tagged `mobile-survey-v1`). A disabled
  /// one is a draft: left out here even where the server's search still lists it.
  nonisolated static func published(_ all: [Challenge]) -> [Challenge] {
    all.filter {
      $0.cooperativeType == choiceType && $0.archived != true && $0.enabled != false
        && $0.tags?.contains(publishedTag) == true
    }
  }

  var body: some View {
    @Bindable var session = session
    List {
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
                // Two lines keep the list short; at accessibility sizes two lines hold a few words.
                Text(blurb).font(.footnote).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 6 : 2)
              }
            }
          }
        }
      } header: {
        Text("Mapping campaigns")
      } footer: {
        if !challenges.isEmpty && showDetails {
          Text(footer)
        }
      }
      Section {
        Text(session.view.message).font(.subheadline).foregroundStyle(.secondary)
          .accessibilityAddTraits(.updatesFrequently)
        if showDetails, let detail = session.view.detail {
          Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        Button(signInLabel) { accountAction() }
          .disabled(!session.signInAvailable || signingIn)
        if session.signInAvailable && !session.view.signedIn {
          Text(session.accountHint).font(.footnote).foregroundStyle(.secondary)
        }
        if session.view.guest {
          Button(Wording.deleteMyData, role: .destructive) { confirmDelete = true }
        }
        if let deleteResult { Text(deleteResult).font(.footnote) }
      } header: {
        Text("Account")
      }
      .confirmationDialog(Wording.deleteMyData, isPresented: $confirmDelete, titleVisibility: .visible) {
        Button("Delete", role: .destructive) { deleteGuestData() }
      } message: {
        Text(Wording.deleteMyDataExplained)
      }
      Section {
        Toggle(Wording.showDetails, isOn: $showDetails)
        if showDetails && session.writesConfigured {
          Toggle("Allow deleting OSM elements", isOn: $session.allowElementDeletion)
        }
      } header: {
        Text("Settings")
      } footer: {
        if showDetails && session.writesConfigured {
          let server = session.osmServer.map(TaskText.host) ?? "the backend's OpenStreetMap server"
          Text(verbatim: "Off (default): a “gone” answer is recorded as Not an issue. On: it deletes the element on \(server).")
        } else {
          Text(Wording.showDetailsFooter)
        }
      }
    }
    .navigationTitle("Street Tally")
    .searchable(text: $search, prompt: "Find a campaign")
    .refreshable { load(); await request?.value }
    .onAppear {
      if client == nil {
        client = session.newClient()
        load()
      }
    }
    .onChange(of: showDetails) {
      // Deleting is an expert setting: hiding the details turns it off too.
      if !showDetails { session.allowElementDeletion = false }
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
    var parts = ["\(challenges.count) multiple-choice challenges (cooperativeType 3)."]
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
    status = "Loading campaigns…"
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
        let choice = Self.published(all)
        challenges = choice.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        others = all.count - choice.count
        truncated = cursor != nil
        status = choice.isEmpty ? "No campaigns here yet. Got a campaign link or QR code from your organizer? Open it to jump straight in." : ""
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
    if !session.view.signedIn {
      return session.canAnswerAsGuest ? "I already use OpenStreetMap" : "Sign in with OpenStreetMap"
    }
    return needsReconsent ? "Sign in again to save answers" : "Sign out"
  }

  private func deleteGuestData() {
    Task {
      do {
        try await session.deleteGuestData()
        deleteResult = Wording.deleteMyDataDone
      } catch {
        deleteResult = "Couldn't delete right now. Check your connection and try again."
      }
    }
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
    guard let error = error as? MapRouletteError else { return "Couldn't load. Please try again." }
    switch error.kind {
    case .notFound: return "This campaign couldn't be found. It may have ended."
    case .authentication, .permission: return "Please sign in again to do this."
    case .network: return "Couldn't connect. Check your connection and try again."
    case .rateLimit: return "Too many requests right now. Wait a moment and try again."
    default: return "Something went wrong on our side. Please try again."
    }
  }
}
