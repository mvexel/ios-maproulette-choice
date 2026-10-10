import Foundation

/// A campaign's progress from its tasks: what counts toward "N of M", what goes on the map and
/// list, and what is still to check.
///
/// Held places (open tasks someone's saved guest answer holds) still count toward the total:
/// they are answered, just not on the map yet. They are neither shown nor offered.
struct CampaignProgress {
  /// Checked: done on the server, or finished on this device since launch.
  let done: Set<Int64>
  /// The campaign's size: open places (held ones included) and checked ones.
  let total: Int
  /// Open places that are not held, and checked ones; the rest are left off the map and list.
  let shown: [LocatedTask]
  /// Still to check: open, not finished here, not held. In task order.
  let open: [LocatedTask]

  /// `answerable` widens what can be opened beyond open tasks (preview lists broken surveys too);
  /// it never changes the total.
  init(
    tasks: [LocatedTask], justDone: Set<Int64>, held: Set<Int64>,
    answerable: (LocatedTask) -> Bool = { $0.isOpen }
  ) {
    let done = Set(tasks.filter { $0.isDone || justDone.contains($0.id) }.map(\.id))
    self.done = done
    total = tasks.filter { $0.isOpen || done.contains($0.id) }.count
    shown = tasks.filter { (answerable($0) && !held.contains($0.id)) || done.contains($0.id) }
    open = tasks.filter { answerable($0) && !justDone.contains($0.id) && !held.contains($0.id) }
  }
}
