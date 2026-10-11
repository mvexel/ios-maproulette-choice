import MapRoulette
import SwiftUI

/// "Your answers are saved": how a guest puts saved answers on the map (deferred sign-up §1.3).
/// Shown once after the first saved answer and from the campaign's saved-answers banner.
struct PutOnMapCard: View {
  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss

  /// The campaign's noun, for the "answer one first" line.
  var noun: Noun = .place

  @State private var email = ""
  @State private var sending = false
  @State private var sentTo: String?
  @State private var error: String?
  @State private var errorIsInput = false
  @State private var existingAccount = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(Wording.putOnMapIntro)
          if session.guestStatusRefreshFailed {
            Text(Wording.guestStatusUnavailable).foregroundStyle(.secondary)
            Button("Check again") { Task { await session.refreshGuestStatus() } }
              .disabled(session.guestStatusRefreshInProgress)
              .frame(minHeight: 44)
          }
        }
        if let sentTo {
          Section {
            Text(Wording.linkSent(to: sentTo, until: session.guestStatus?.expiresAt))
            Button("Change") { self.sentTo = nil }
          }
        } else {
          Section {
            // An email is on file, but this launch doesn't know it (it isn't stored on the phone).
            if session.guestStatus.map({ $0.email != .none }) == true && session.lastLinkEmail == nil {
              Text(Wording.enterEmailAgain)
            }
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
          Button("I already use OpenStreetMap") { existingAccount = true }
          if existingAccount { Text(Wording.existingAccountFinishLink) }
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
        self.error = Wording.linkFailed(error, noun)
        errorIsInput = Wording.isInputError(error)
      }
    }
  }

}
