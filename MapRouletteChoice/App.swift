import MapRoulette
import SwiftUI

@main
struct MapRouletteChoiceApp: App {
  @State private var session = AppSession(config: .current)
  @State private var refresh = TaskChanges()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(session)
        .environment(refresh)
    }
  }
}

enum Route: Hashable {
  case challenge(ChallengeID)
  /// `order` is the list or map order, used for "Next task".
  case task(id: Int64, order: [Int64])
}

/// Counts task screens that may have changed a task; lists and maps reload when it changes.
@MainActor @Observable final class TaskChanges {
  private(set) var version = 0
  func taskChanged() { version += 1 }
}

struct RootView: View {
  @State private var path: [Route] = []

  var body: some View {
    NavigationStack(path: $path) {
      ChallengePickerView()
        .navigationDestination(for: Route.self) { route in
          switch route {
          case .challenge(let id): ChallengeTasksView(challengeID: id)
          case .task(let id, let order): TaskView(taskID: id, order: order)
          }
        }
    }
  }
}
