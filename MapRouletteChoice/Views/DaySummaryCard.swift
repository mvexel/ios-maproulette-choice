import MapRoulette
import SwiftUI

/// "Nice work today": a guest's end-of-session summary (deferred sign-up §1.4), opened from
/// "I'm done for today" under the saved-answers banner.
struct DaySummaryCard: View {
  let checkedToday: Int
  let done: Int
  let total: Int
  let noun: Noun

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
      }
      .padding()
    }
    .presentationDetents([.medium, .large])
  }
}
