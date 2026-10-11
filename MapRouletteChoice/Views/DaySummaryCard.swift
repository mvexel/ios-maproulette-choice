import MapRoulette
import SwiftUI

/// "Nice work today": a guest's end-of-session summary (deferred sign-up §1.4), opened from
/// "I'm done for today" under the saved-answers banner. Without an email yet, it shows the
/// "put them on the map" card instead.
struct DaySummaryCard: View {
  let checkedToday: Int
  let done: Int
  let total: Int
  let noun: Noun

  @Environment(AppSession.self) private var session
  @Environment(\.dismiss) private var dismiss
  @State private var sending = false
  @State private var note: String?
  @State private var enterEmail = false

  var body: some View {
    if session.guestStatus?.email == GuestEmailState.none || enterEmail {
      PutOnMapCard(noun: noun)
    } else {
      NavigationStack {
        VStack(alignment: .leading, spacing: 16) {
          Text("Nice work today.").font(.title2.weight(.semibold))
          Text(Wording.daySummary(checkedToday, done: done, total: total, noun))
          Text(Wording.daySummarySaved(until: session.guestStatus?.expiresAt))
          if session.guestStatusRefreshFailed {
            Text(Wording.guestStatusUnavailable).foregroundStyle(.secondary)
            Button("Check again") { Task { await session.refreshGuestStatus() } }
              .disabled(session.guestStatusRefreshInProgress)
              .frame(minHeight: 44)
          }
          if let note { Text(note).foregroundStyle(.secondary) }
          Spacer()
          Button {
            resend()
          } label: {
            HStack {
              Text("Resend the link").font(.headline)
              if sending { ProgressView() }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
          }
          .buttonStyle(.borderedProminent)
          .disabled(sending)
          Button("Done") { dismiss() }.frame(maxWidth: .infinity, minHeight: 44)
        }
        .padding()
      }
      .presentationDetents([.medium, .large])
    }
  }

  /// Resends to the address given in this launch; otherwise asks for it again (it isn't stored).
  private func resend() {
    guard let address = session.lastLinkEmail else {
      enterEmail = true
      return
    }
    sending = true
    Task {
      defer { sending = false }
      do {
        try await session.sendFinishLink(to: address)
        note = Wording.linkSent(to: address, until: session.guestStatus?.expiresAt)
      } catch {
        note = Wording.linkFailed(error)
      }
    }
  }
}
