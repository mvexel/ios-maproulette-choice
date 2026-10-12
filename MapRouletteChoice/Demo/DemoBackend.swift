#if DEBUG
  import Foundation
  import MapRoulette

  /// In-process mock backend for `-demo` (screenshots and design review without sign-in). It
  /// answers the SDK's requests from memory and never touches the network. One published bench
  /// campaign (challenge 3) with eight benches around Library Square, Salt Lake City: 186, 189
  /// and 190 already checked; 191 no longer needs checking (its tags changed on OSM).
  /// `-demoStops` swaps in "SLC Bus Stops" (same ids and states) around 1300 S 900 E, for App
  /// Store screenshots. Guest calls (`-demoGuest`) keep answers in memory. `-demoClosing` starts
  /// the guest with two saved answers (184, 188) that expire in about 2 days, for the amber banner.
  /// `-demoDraft` serves the campaign as an unpublished draft (disabled, not tagged
  /// `mobile-survey-v1`) for preview mode; the picker then lists nothing and only the preview link opens it.
  /// `-demoReported` starts with 187 reported moved (about 30 m) and 185 reported not here
  /// (design/not-here-moved.md), for the banner and map dot (`seededReports`).
  /// `-demoHeldReport` has another guest holding 188 with a saved report (`heldKind` "report", T-002)
  /// and 184 with a saved answer, for "Needs another look" against "checked".
  /// `-demoClaimed` answers the finish-link request with 409 `guest_claimed`, for the claimed copy.
  /// `-demoWoodbine` serves the first pilot, "Woodbine entrance doors" (design/woodbine-campaign.md),
  /// on eight real entrance nodes around Woodbine Food Hall; 188 already has `door`, so only the
  /// automatic-opening question is asked there (`liveMissingQuestions`).
  actor DemoBackend: Transport {
    enum Campaign: Sendable { case benches, stops, woodbine }

    static let challengeID: Int64 = 3
    static let taskIDs: [Int64] = Array(184...191)
    /// The demo account: MapRoulette user 7, OpenStreetMap username "rosa_slc".
    static let me: Int64 = 7
    static let displayName = "rosa_slc"
    private static let benchNames: [Int64: String] = [
      184: "Library Square bench", 187: "Washington Square bench", 190: "Gallivan Plaza bench",
    ]
    private static let stopNames: [Int64: String] = [
      184: "900 E & 1300 S", 185: "900 E & Kensington Ave", 186: "1300 S & 800 E", 187: "1300 S & 1000 E",
      188: "900 E & Bryan Ave", 189: "Sugar House Park & Ride", 190: "900 E & Emerson Ave", 191: "1100 E & 1300 S",
    ]
    let campaign: Campaign
    private var stops: Bool { campaign == .stops }
    /// The campaign a demo launch asks for.
    static func demoCampaign(_ args: [String]) -> Campaign {
      args.contains("-demoWoodbine") ? .woodbine : args.contains("-demoStops") ? .stops : .benches
    }
    let draft: Bool
    private var pending: [Int64: Date] = [:]
    private var email = "none"
    /// When the guest's saved answers are removed.
    private var expiresAt = Date().addingTimeInterval(14 * 86400)

    /// Places another guest's saved answer or report holds, by `heldKind`.
    private var othersHolds: [Int64: String] = [:]

    init(
      campaign: Campaign = .benches, closing: Bool = false, draft: Bool = false, reported: Bool = false,
      heldReport: Bool = false
    ) {
      self.campaign = campaign
      self.draft = draft
      if heldReport { othersHolds = [184: "answer", 188: "report"] }
      if reported {
        status[185] = 6
        status[187] = 6
      }
      if closing {
        let now = Date()
        pending = [184: now.addingTimeInterval(-12 * 86400), 188: now.addingTimeInterval(-12 * 86400)]
        expiresAt = now.addingTimeInterval(2 * 86400)
      }
    }
    private var status: [Int64: Int] = Dictionary(uniqueKeysWithValues: DemoBackend.taskIDs.map { ($0, 0) })
      .merging([186: 1, 189: 1, 190: 1]) { $1 }
    private var completedBy: [Int64: Int64] = [186: 8, 189: 8, 190: 8]
    private var changesets: [Int64: Int64] = [:]
    private var nextChangeset: Int64 = 9001

    /// `-demoReported`'s reports. The campaign status read (E1) will serve these; until it exists the
    /// campaign screen takes them straight from here.
    static func seededReports(_ campaign: Campaign) -> [Int64: TaskReport] {
      let (lat, lng) = coordinate(187, campaign)
      return [185: .notHere, 187: .moved(latitude: lat + 0.00025, longitude: lng + 0.0001)]
    }

    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
      try await Task.sleep(for: .milliseconds(250))
      let parts = request.url.path.split(separator: "/").dropFirst(2).map(String.init)  // drop api/v2
      let firstPage = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "page" }?.value ?? "0") == "0"
      switch (request.method, parts) {
      case (.get, ["challenges", "extendedFind"]): return ok(firstPage ? [challenge] : [])
      case (.get, ["challenge", "3"]): return ok(challenge)
      case (.get, ["challenge", "3", "tasks"]): return ok(firstPage ? Self.taskIDs.map { task($0) } : [])
      // The bounds search: open tasks not held by a guest, or with `includePending` all open
      // tasks, each saying whether one holds it (backend #16).
      case (.get, let p) where p.count == 6 && p[0] == "tasks" && p[1] == "box":
        let includePending = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
          .contains { $0.name == "includePending" && $0.value == "true" } == true
        func held(_ id: Int64) -> Bool { pending[id] != nil || othersHolds[id] != nil }
        let rows = Self.taskIDs.filter { [0, 3, 6].contains(status[$0] ?? 0) && (includePending || !held($0)) }
          .map { id in
            var row = summary(id)
            if includePending {
              row["pending"] = held(id)
              if held(id) { row["heldKind"] = othersHolds[id] ?? "answer" }
            }
            return row
          }
        return ok(["total": firstPage ? rows.count : 0, "tasks": firstPage ? rows : []])
      case (.get, let p) where p.count == 2 && p[0] == "task":
        return id(p[1]).map { ok(task($0)) } ?? notFound
      case (.get, let p) where p.count == 4 && p[2] == "choice" && p[3] == "check":
        switch id(p[1]) {
        case 191?: return ok(["eligible": false, "reason": "key_changed"])
        case 188? where campaign == .woodbine:
          return ok(["eligible": true, "deleteAllowed": true, "questionIds": ["automatic-opening"]])
        case _?: return ok(["eligible": true, "deleteAllowed": true])
        case nil: return notFound
        }
      // The SDK locks before submitting a choice and releases on failure.
      case (.get, let p) where p.count == 3 && p[2] == "start":
        guard let id = id(p[1]) else { return notFound }
        var body = task(id)
        body["lockPrimaryTaskId"] = id
        body["lockBundledTasks"] = [Int64]()
        return ok(body)
      case (.get, let p) where p.count == 3 && p[2] == "release": return ok([String: Any]())
      case (.post, let p) where p.count == 3 && p[2] == "skip": return ok([String: Any]())
      case (.post, let p) where p.count == 4 && p[2] == "choice" && p[3] == "pending":
        guard let id = id(p[1]) else { return notFound }
        let now = Date()
        pending[id] = now
        return ok([
          "taskId": id, "challengeId": Self.challengeID, "state": "pending", "answeredAt": stamp(now),
          "holdUntil": stamp(now.addingTimeInterval(14 * 86400)),
        ])
      case (.get, ["mobile-guest", "me"]): return ok(guestStatus)
      case (.put, ["mobile-guest", "email"]):
        if ProcessInfo.processInfo.arguments.contains("-demoClaimed") {
          return HTTPResponse(status: 409, body: json(["error": "guest_claimed"]))
        }
        email = "pending"
        return ok(guestStatus)
      case (.delete, ["mobile-guest"]):
        pending = [:]
        email = "none"
        return ok([String: Any]())
      case (.post, let p) where p.count == 3 && p[2] == "choice":
        guard let id = id(p[1]), let body = request.body,
          let o = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return notFound }
        return choice(id, o)
      default: return notFound
      }
    }

    private func choice(_ id: Int64, _ body: [String: Any]) -> HTTPResponse {
      var changeset: Int64?
      let result: Int
      if body["answers"] != nil {
        result = 1
        changeset = nextChangeset
      } else {
        let outcome = body["outcome"] as? String
        let delete = body["delete"] as? Bool == true
        if outcome == "moved" {
          guard let at = body["location"] as? [String: Any], let lat = at["lat"] as? Double,
            let lon = at["lon"] as? Double
          else { return HTTPResponse(status: 422, body: json(["error": "invalid_submission"])) }
          let (mappedLat, mappedLng) = coordinate(id)
          let meters = hypot((lat - mappedLat) * 111_320, (lon - mappedLng) * 111_320 * cos(lat * .pi / 180))
          if meters > 500 { return HTTPResponse(status: 422, body: json(["error": "moved_too_far"])) }
        }
        result = ["too-hard", "not-here", "moved"].contains(outcome) ? 6 : delete ? 1 : outcomeStatus(outcome) ?? 2
        if delete { changeset = nextChangeset }
      }
      if changeset != nil { nextChangeset += 1 }
      status[id] = result
      completedBy[id] = Self.me
      changesets[id] = changeset
      return ok(["status": result, "changesetId": changeset.map { $0 as Any } ?? NSNull()])
    }

    /// The status a campaign outcome declares in the payload, as the server sets it
    /// (Woodbine's "There's no door" is 6).
    private func outcomeStatus(_ id: String?) -> Int? {
      let work: [String: Any] =
        switch campaign {
        case .benches: payload(element: 0)
        case .stops: stopPayload(element: 0)
        case .woodbine: woodbinePayload(element: 0, entrance: "yes")
        }
      return (work["outcomes"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["status"] as? Int
    }

    private var guestStatus: [String: Any] {
      [
        "guestId": "demo-guest", "state": "active", "email": email, "pending": pending.count, "published": 0,
        "expiresAt": stamp(expiresAt),
      ]
    }

    private func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func id(_ text: String) -> Int64? { Int64(text).flatMap { status[$0] != nil ? $0 : nil } }

    private var notFound: HTTPResponse { HTTPResponse(status: 404, body: json(["message": "Not found"])) }
    private func ok(_ value: Any) -> HTTPResponse { HTTPResponse(status: 200, body: json(value)) }
    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    private var challenge: [String: Any] {
      var o = published
      if draft {
        o["enabled"] = false
        o["tags"] = [String]()
      }
      return o
    }

    private var published: [String: Any] {
      if campaign == .woodbine {
        return [
          "id": Self.challengeID, "parent": 1, "name": "Woodbine entrance doors",
          "description":
            "Help map the doors around Woodbine Food Hall. At each entrance, check how the door opens and whether it opens by itself, so people with wheelchairs, strollers or walkers know what to expect.",
          "instruction":
            "Survey the door at the mapped entrance node. Sets door=* and automatic_door=* only when missing. No geometry changes.",
          "enabled": true, "cooperativeType": 3, "tags": ["mobile-survey-v1"],
        ]
      }
      if stops {
        return [
          "id": Self.challengeID, "parent": 1, "name": "SLC Bus Stops",
          "description":
            "Help tally every bus stop in Salt Lake City: is there a shelter, a seat, a light? Each stop takes about a minute.",
          "instruction": "Answer from what you see at the stop in person.",
          "enabled": true, "cooperativeType": 3, "tags": ["mobile-survey-v1"],
        ]
      }
      return [
        "id": Self.challengeID, "parent": 1, "name": "Downtown bench check",
        "description": "Help us find out which downtown benches are comfortable to sit on.",
        "instruction": "Look at the bench and answer what you can see.",
        "enabled": true, "cooperativeType": 3, "tags": ["mobile-survey-v1"],
      ]
    }

    private func coordinate(_ id: Int64) -> (Double, Double) { Self.coordinate(id, campaign) }

    /// Real entrance nodes near Woodbine Food Hall, Salt Lake City (graveyard C-001 inventory):
    /// task id to node id, `entrance` value and position.
    private static let entrances: [Int64: (node: Int64, entrance: String, lat: Double, lng: Double)] = [
      184: (14178183367, "main", 40.7538166, -111.9068120), 185: (14178183369, "yes", 40.7535743, -111.9068124),
      186: (14178183390, "main", 40.7527671, -111.9056331), 187: (10290204107, "yes", 40.7561096, -111.9078998),
      188: (12790552134, "yes", 40.7565212, -111.9015878), 189: (13689903758, "main", 40.7521289, -111.9005183),
      190: (13302228244, "yes", 40.7567798, -111.9015054), 191: (10290204100, "main", 40.7580994, -111.9004649),
    ]

    /// Spread around Library Square, a few minutes' walk apart.
    private static func coordinate(_ id: Int64, _ campaign: Campaign) -> (Double, Double) {
      let i = Double(id - 184)
      if campaign == .woodbine, let e = entrances[id] { return (e.lat, e.lng) }
      if campaign == .stops {  // along 900 E and 1300 S, around their corner
        return id.isMultiple(of: 2)
          ? (40.7390 - 0.0018 * (i / 2 - 1), -111.8648) : (40.7393, -111.8648 + 0.0022 * ((i - 1) / 2 - 1.5))
      }
      return (40.7600 + 0.0011 * (i - 3.5), -111.8860 + 0.0016 * (i.truncatingRemainder(dividingBy: 3) - 1))
    }

    private func elementID(_ id: Int64) -> Int64 {
      campaign == .woodbine ? Self.entrances[id]?.node ?? id + 1000 : id + 1000
    }

    private func summary(_ id: Int64) -> [String: Any] {
      let (lat, lng) = coordinate(id)
      return [
        "id": id, "parentId": Self.challengeID, "title": "node/\(elementID(id))", "status": status[id] ?? 0,
        "point": ["lat": lat, "lng": lng],
      ]
    }

    private func task(_ id: Int64) -> [String: Any] {
      let (lat, lng) = coordinate(id)
      let element = elementID(id)
      var properties: [String: Any]
      let work: [String: Any]
      switch campaign {
      case .benches:
        properties = ["amenity": "bench"]
        properties["name"] = Self.benchNames[id]
        work = payload(element: element)
      case .stops:
        properties = ["highway": "bus_stop"]
        properties["name"] = Self.stopNames[id]
        work = stopPayload(element: element)
      case .woodbine:
        let entrance = Self.entrances[id]?.entrance ?? "yes"
        properties = ["entrance": entrance]
        if id == 188 { properties["door"] = "hinged" }
        work = woodbinePayload(element: element, entrance: entrance)
      }
      var o: [String: Any] = [
        "id": id, "parent": Self.challengeID, "name": "node/\(element)",
        "instruction": "", "status": status[id] ?? 0,
        "geometries": [
          "type": "FeatureCollection",
          "features": [
            [
              "type": "Feature", "id": "node/\(element)",
              "geometry": ["type": "Point", "coordinates": [lng, lat]],
              "properties": properties,
            ]
          ],
        ],
        "cooperativeWork": work,
      ]
      if let by = completedBy[id] { o["completedBy"] = by }
      if let changeset = changesets[id] { o["changesetId"] = changeset }
      return o
    }

    /// Three of the SLC survey's questions (design/slc-bus-stop-survey in the project files).
    private func stopPayload(element: Int64) -> [String: Any] {
      func yesNo(_ key: String, _ prompt: String, _ help: String) -> [String: Any] {
        [
          "id": key, "prompt": prompt, "description": help, "expect": [key: NSNull()],
          "options": [
            ["id": "yes", "label": "Yes", "setTags": [key: "yes"]], ["id": "no", "label": "No", "setTags": [key: "no"]],
          ],
        ]
      }
      return [
        "meta": ["version": 2, "type": 3, "choiceVersion": 1], "liveMissingQuestions": true,
        "element": "node/\(element)", "match": ["highway": "bus_stop"],
        "questions": [
          yesNo(
            "shelter", "Is there a shelter with a roof?",
            "A shelter built for waiting riders. A tree, awning or building overhang doesn't count."),
          yesNo("bench", "Is there a bench or seat?", "Inside or outside the shelter."),
          yesNo(
            "lit", "Is the waiting area lit at night?",
            "A streetlight or shelter light that shines on where people wait. If it's daytime and you can't tell, pick \u{201C}I'm not sure\u{201D}."
          ),
        ],
        // "Stop is gone" is retired: the built-in "It's not here" replaces it (not-here-moved §1).
      ]
    }

    /// The Woodbine pilot (design/woodbine-campaign.md): two questions, asked only where the tag is
    /// missing, and one campaign outcome for open doorways.
    private func woodbinePayload(element: Int64, entrance: String) -> [String: Any] {
      func options(_ key: String, _ values: [(String, String, String)]) -> [[String: Any]] {
        values.map { ["id": $0.0, "label": $0.1, "setTags": [key: $0.2]] }
      }
      return [
        "meta": ["version": 2, "type": 3, "choiceVersion": 1],
        "element": "node/\(element)", "match": ["entrance": entrance], "liveMissingQuestions": true,
        "questions": [
          [
            "id": "door-type", "prompt": "How does this door open?",
            "description": "Look only at the door at this entrance.", "expect": ["door": NSNull()],
            "options": options(
              "door",
              [
                ("hinged", "Swings open", "hinged"), ("sliding", "Slides sideways", "sliding"),
                ("revolving", "Revolves", "revolving"), ("folding", "Folds", "folding"),
              ]),
          ],
          [
            "id": "automatic-opening", "prompt": "Does it open by itself?",
            "description": "A door that's propped open doesn't count.", "expect": ["automatic_door": NSNull()],
            "options": options(
              "automatic_door",
              [
                ("no", "No, you push or pull it", "no"), ("button", "Yes, with a button", "button"),
                ("motion", "Yes, when you walk up", "motion"), ("yes", "Yes, not sure how", "yes"),
              ]),
          ],
        ],
        "outcomes": [
          ["id": "no-door", "label": "There's no door", "description": "It's an open doorway or a gate.", "status": 6]
        ],
      ]
    }

    /// The pilot payload (docs/design/mobile-choice-challenges.md §3 in the SDK repo).
    private func payload(element: Int64) -> [String: Any] {
      func options(_ key: String, _ values: [(String, String)]) -> [[String: Any]] {
        values.map { ["id": $0.0, "label": $0.1, "setTags": [key: $0.0.hasPrefix("c") ? String($0.0.dropFirst()) : $0.0]] }
      }
      return [
        "meta": ["version": 2, "type": 3, "choiceVersion": 1], "liveMissingQuestions": true,
        "element": "node/\(element)", "match": ["amenity": "bench"],
        "questions": [
          [
            "id": "backrest", "prompt": "Does the bench have a backrest?",
            "description": "Look at the seat from the side.", "expect": ["backrest": NSNull()],
            "options": [
              ["id": "yes", "label": "Yes", "description": "Seat has back support.", "setTags": ["backrest": "yes"]],
              ["id": "no", "label": "No", "setTags": ["backrest": "no"]],
            ],
          ],
          [
            "id": "material", "prompt": "What is the seat mainly made of?", "expect": ["material": NSNull()],
            "options": options(
              "material", [("wood", "Wood"), ("metal", "Metal"), ("concrete", "Concrete"), ("stone", "Stone")]),
          ],
          [
            "id": "capacity", "prompt": "How many adults can sit on it?", "expect": ["capacity": NSNull()],
            "options": options("capacity", [("c2", "2"), ("c3", "3"), ("c4", "4")]),
          ],
        ],
        "outcomes": [
          ["id": "not-a-bench", "label": "Not a bench", "description": "Something else is here.", "status": 2],
          ["id": "gone", "label": "Bench is gone", "delete": true],
        ],
      ]
    }
  }
#endif
