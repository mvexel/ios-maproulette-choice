import MapRoulette
import Testing

@testable import MapRouletteChoice

/// "N of M" progress (design rule H1): held places count toward M but stay off the map and list.
@Suite struct CampaignProgressTests {
  private func open(_ id: Int64) async throws -> LocatedTask { LocatedTask(try await makeTask(id: id)) }
  private func done(_ id: Int64, status: Int = 1) async throws -> LocatedTask {
    LocatedTask(try await makeTask(id: id, status: status))
  }

  @Test func heldPlacesCountInTotalButAreNotShown() async throws {
    let tasks = [try await open(1), try await open(2), try await open(3)]
    let p = CampaignProgress(tasks: tasks, justDone: [], held: [2])
    #expect(p.total == 3)
    #expect(p.checked == 1)
    #expect(p.done.isEmpty)
    #expect(p.shown.map(\.id) == [1, 3])
    #expect(p.open.map(\.id) == [1, 3])
  }

  @Test func doneAndJustDoneCount() async throws {
    let tasks = [
      try await open(1), try await open(2), try await done(3), try await done(4, status: 2),
      try await done(5, status: 5),
    ]
    let p = CampaignProgress(tasks: tasks, justDone: [2], held: [])
    #expect(p.done == [2, 3, 4, 5])
    #expect(p.total == 5)
    #expect(p.shown.map(\.id) == [1, 2, 3, 4, 5])
    #expect(p.open.map(\.id) == [1])
  }

  @Test func neitherOpenNorDoneIsLeftOut() async throws {
    let tasks = [
      try await open(1),
      LocatedTask(try await makeTask(id: 2, payload: nil)),  // not a choice task
      LocatedTask(try await makeTask(id: 3, bundleID: 9)),  // bundled
      LocatedTask(try await makeTask(id: 4, status: 4)),  // deleted
      try await done(5),
    ]
    let p = CampaignProgress(tasks: tasks, justDone: [], held: [])
    #expect(p.total == 2)
    #expect(p.checked == 1)
    #expect(p.done == [5])
    #expect(p.shown.map(\.id) == [1, 5])
    #expect(p.open.map(\.id) == [1])
  }

  @Test func heldAndCheckedTogether() async throws {
    let tasks = [try await open(1), try await open(2), try await open(3), try await done(4)]
    let p = CampaignProgress(tasks: tasks, justDone: [3], held: [2])
    #expect(p.total == 4)
    #expect(p.checked == 3)
    #expect(p.done == [3, 4])
    #expect(p.shown.map(\.id) == [1, 3, 4])
    #expect(p.open.map(\.id) == [1])
  }
}
