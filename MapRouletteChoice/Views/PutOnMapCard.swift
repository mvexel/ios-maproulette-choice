import AuthenticationServices
import MapRoulette
import SwiftUI

/// "Your answers are saved": how a guest puts saved answers on the map (deferred sign-up §1.3).
/// Shown once after the first saved answer and from the campaign's saved-answers banner.
struct PutOnMapCard: View {
  @Environment(AppSession.self) private var session
  @Environment(\.webAuthenticationSession) private var webAuth
  @Environment(\.dismiss) private var dismiss

  @State private var email = ""
  @State private var sending = false
  @State private var sentTo: String?
  @State private var error: String?
  @State private var errorIsInput = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(Wording.putOnMapIntro)
        }
        if let sentTo {
          Section {
            Text(Wording.linkSent(to: sentTo, until: session.guestStatus?.expiresAt))
            Button("Change") { self.sentTo = nil }
          }
        } else {
          Section {
            TextField("Email address", text: $email)
              .keyboardType(.emailAddress)
              .textContentType(.emailAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Button {
              send()
            } label: {
              HStack {
                Text("Send me the link")
                if sending { Spacer(); ProgressView() }
              }
            }
            .disabled(sending || !email.contains("@"))
            if let error { Text(error).foregroundStyle(errorIsInput ? Color.red : Color.secondary) }
          } footer: {
            Text(Wording.emailUse)
          }
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
        ToolbarItem(placement: .cancellationAction) { Button(sentTo == nil ? "Later" : "Done") { dismiss() } }
      }
    }
  }

  private func send() {
    let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
    sending = true
    error = nil
    Task {
      defer { sending = false }
      do {
        try await session.sendFinishLink(to: address)
        sentTo = address
      } catch {
        self.error = Wording.linkFailed(error)
        errorIsInput = Wording.isInputError(error)
      }
    }
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
