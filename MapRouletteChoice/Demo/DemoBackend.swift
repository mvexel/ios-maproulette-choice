#if DEBUG
  import Foundation
  import MapRoulette

  /// In-process mock backend for `-demo` (screenshots and design review without sign-in). It
  /// answers the SDK's requests from memory and never touches the network. One published bench
  /// campaign (challenge 3) with eight benches around Library Square, Salt Lake City: 186, 189
  /// and 190 already checked; 191 no longer needs checking (its tags changed on OSM).
  /// `-demoStops` swaps in "SLC Bus Stops" (same ids and states) around 1300 S 900 E, for App
  /// Store screenshots. Guest calls (`-demoGuest`) keep answers in memory. `-demoDraft` serves the
  /// campaign as an unpublished draft (disabled, not tagged `mobile-survey-v1`) for preview mode;
  /// the picker then lists nothing and only the preview link opens it.
  actor DemoBackend: Transport {
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
    let stops: Bool
    let draft: Bool
    private var pending: [Int64: Date] = [:]
    private var email = "none"

    init(stops: Bool = false, draft: Bool = false) {
      self.stops = stops
      self.draft = draft
    }
    private var status: [Int64: Int] = Dictionary(uniqueKeysWithValues: DemoBackend.taskIDs.map { ($0, 0) })
      .merging([186: 1, 189: 1, 190: 1]) { $1 }
    private var completedBy: [Int64: Int64] = [186: 8, 189: 8, 190: 8]
    private var changesets: [Int64: Int64] = [:]
    private var nextChangeset: Int64 = 9001

    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
      try await Task.sleep(for: .milliseconds(250))
      let parts = request.url.path.split(separator: "/").dropFirst(2).map(String.init)  // drop api/v2
      let firstPage = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "page" }?.value ?? "0") == "0"
      switch (request.method, parts) {
      case (.get, ["challenges", "extendedFind"]): return ok(firstPage ? [challenge] : [])
      case (.get, ["challenge", "3"]): return ok(challenge)
      case (.get, ["challenge", "3", "tasks"]): return ok(firstPage ? Self.taskIDs.map { task($0) } : [])
      case (.get, let p) where p.count == 2 && p[0] == "task":
        return id(p[1]).map { ok(task($0)) } ?? notFound
      case (.get, let p) where p.count == 4 && p[2] == "choice" && p[3] == "check":
        switch id(p[1]) {
        case 191?: return ok(["eligible": false, "reason": "key_changed"])
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
        result = outcome == "too-hard" ? 6 : delete ? 1 : 2
        if delete { changeset = nextChangeset }
      }
      if changeset != nil { nextChangeset += 1 }
      status[id] = result
      completedBy[id] = Self.me
      changesets[id] = changeset
      return ok(["status": result, "changesetId": changeset.map { $0 as Any } ?? NSNull()])
    }

    private var guestStatus: [String: Any] {
      [
        "guestId": "demo-guest", "state": "active", "email": email, "pending": pending.count, "published": 0,
        "expiresAt": stamp(Date().addingTimeInterval(14 * 86400)),
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

    /// Spread around Library Square, a few minutes' walk apart.
    private func coordinate(_ id: Int64) -> (Double, Double) {
      let i = Double(id - 184)
      if stops {  // along 900 E and 1300 S, around their corner
        return id.isMultiple(of: 2)
          ? (40.7390 - 0.0018 * (i / 2 - 1), -111.8648) : (40.7393, -111.8648 + 0.0022 * ((i - 1) / 2 - 1.5))
      }
      return (40.7600 + 0.0011 * (i - 3.5), -111.8860 + 0.0016 * (i.truncatingRemainder(dividingBy: 3) - 1))
    }

    private func task(_ id: Int64) -> [String: Any] {
      let (lat, lng) = coordinate(id)
      var properties: [String: Any] = stops ? ["highway": "bus_stop"] : ["amenity": "bench"]
      properties["name"] = (stops ? Self.stopNames : Self.benchNames)[id]
      var o: [String: Any] = [
        "id": id, "parent": Self.challengeID, "name": "node/\(id + 1000)",
        "instruction": "", "status": status[id] ?? 0,
        "geometries": [
          "type": "FeatureCollection",
          "features": [
            [
              "type": "Feature", "id": "node/\(id + 1000)",
              "geometry": ["type": "Point", "coordinates": [lng, lat]],
              "properties": properties,
            ]
          ],
        ],
        "cooperativeWork": stops ? stopPayload(element: id + 1000) : payload(element: id + 1000),
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
        "meta": ["version": 2, "type": 3, "choiceVersion": 1],
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
        "outcomes": [["id": "gone", "label": "Stop is gone", "delete": true]],
      ]
    }

    /// The pilot payload (docs/design/mobile-choice-challenges.md §3 in the SDK repo).
    private func payload(element: Int64) -> [String: Any] {
      func options(_ key: String, _ values: [(String, String)]) -> [[String: Any]] {
        values.map { ["id": $0.0, "label": $0.1, "setTags": [key: $0.0.hasPrefix("c") ? String($0.0.dropFirst()) : $0.0]] }
      }
      return [
        "meta": ["version": 2, "type": 3, "choiceVersion": 1],
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
