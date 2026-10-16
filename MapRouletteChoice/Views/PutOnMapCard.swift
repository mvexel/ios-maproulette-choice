import AuthenticationServices
import MapRoulette
import SwiftUI

/// "Your answers are saved": for guests who already map, signing in puts the saved answers on the
/// map (design/handback-copy.md §1). Opened only from the campaign's saved-answers banner.
struct PutOnMapCard: View {
  @Environment(AppSession.self) private var session
  @Environment(\.webAuthenticationSession) private var webAuth
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(Wording.savedForLaterNote)
        }
        Section {
          Button("I already use OpenStreetMap") { signIn() }
        } footer: {
          Text(Wording.signInPutsOnMap)
        }
      }
      .navigationTitle("Your answers are saved")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
      }
    }
    .presentationDetents([.medium, .large])
  }

  private func signIn() {
    Task {
      await session.signIn { url in
        try await webAuth.authenticate(
          using: url, callbackURLScheme: AuthEndpoints.callbackScheme, preferredBrowserSession: .ephemeral)
      }
      if session.view.signedIn { dismiss() }
    }
  }
}
