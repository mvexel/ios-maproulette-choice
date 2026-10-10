import MapRoulette
import SwiftUI

@main
struct MapRouletteChoiceApp: App {
  @State private var session: AppSession = Self.makeSession()
  @State private var refresh = TaskChanges()
  @State private var campaigns: CampaignStore = Self.makeCampaigns()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(session)
        .environment(refresh)
        .environment(campaigns)
    }
  }

  @MainActor private static func makeSession() -> AppSession {
    #if DEBUG
      // `-demo`: an in-process mock campaign for screenshots and design review. No network.
      if ProcessInfo.processInfo.arguments.contains("-demo") { return AppSession(demo: DemoBackend()) }
    #endif
    return AppSession(config: .current)
  }

  @MainActor private static func makeCampaigns() -> CampaignStore {
    #if DEBUG
      // Demo runs start fresh (no last campaign, welcome cards unseen) and leave real state alone.
      if ProcessInfo.processInfo.arguments.contains("-demo"), let demo = UserDefaults(suiteName: "demo") {
        demo.removePersistentDomain(forName: "demo")
        return CampaignStore(defaults: demo)
      }
    #endif
    return CampaignStore()
  }
}

enum Route: Hashable {
  case challenge(ChallengeID)
}

/// Counts task screens that may have changed a task; lists and maps reload when it changes.
@MainActor @Observable final class TaskChanges {
  private(set) var version = 0
  func taskChanged() { version += 1 }
}

struct RootView: View {
  @Environment(CampaignStore.self) private var campaigns
  @State private var path: [Route] = []
  @State private var restored = false

  var body: some View {
    NavigationStack(path: $path) {
      ChallengePickerView()
        .navigationDestination(for: Route.self) { route in
          switch route {
          case .challenge(let id): ChallengeTasksView(challengeID: id)
          }
        }
    }
    .onAppear {
      // Reopen the last campaign once per launch; Back leads to the campaign list.
      guard !restored else { return }
      restored = true
      #if DEBUG
        // Demo screenshot shortcuts open the demo campaign directly (see ChallengeTasksView).
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-demo"), args.contains(where: { ["-demoMap", "-demoList", "-demoTask"].contains($0) }) {
          path = [.challenge(try! ChallengeID(DemoBackend.challengeID))]
          return
        }
      #endif
      if path.isEmpty, let last = campaigns.lastCampaign, let id = try? ChallengeID(last) {
        path = [.challenge(id)]
      }
    }
    .onOpenURL { url in
      guard let value = CampaignLink.challenge(from: url), let id = try? ChallengeID(value) else { return }
      restored = true
      path = [.challenge(id)]
    }
  }
}
