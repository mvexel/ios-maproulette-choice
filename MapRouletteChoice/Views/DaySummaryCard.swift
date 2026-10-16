import AuthenticationServices
import MapRoulette
import SwiftUI

/// "Nice work today": a guest's end-of-session summary (deferred sign-up §1.4), opened from
/// "I'm done for today" under the saved-answers row. Sign-in is a secondary link (handback §1,
/// parity pick 3).
struct DaySummaryCard: View {
  let checkedToday: Int
  let done: Int
  let total: Int
  let noun: Noun

  @Environment(AppSession.self) private var session
  @Environment(\.webAuthenticationSession) private var webAuth
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text("Nice work today.").font(.title2.weight(.semibold))
        Text(Wording.daySummary(checkedToday, done: done, total: total, noun))
        Text(Wording.daySummarySaved)
        Spacer()
        Button {
          dismiss()
        } label: {
          Text("Done").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        Button("I already use OpenStreetMap") { signIn() }
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .padding()
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
