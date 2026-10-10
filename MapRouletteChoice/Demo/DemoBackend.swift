#if DEBUG
  import Foundation
  import MapRoulette

  /// In-process mock backend for `-demo` (screenshots and design review without sign-in). It
  /// answers the SDK's requests from memory and never touches the network. One published bench
  /// campaign (challenge 3) with eight benches around Library Square, Salt Lake City: 186, 189
  /// and 190 already checked; 191 no longer needs checking (its tags changed on OSM).
  actor DemoBackend: Transport {
    static let challengeID: Int64 = 3
    static let taskIDs: [Int64] = Array(184...191)
    private static let me: Int64 = 7
    private static let names: [Int64: String] = [
      184: "Library Square bench", 187: "Washington Square bench", 190: "Gallivan Plaza bench",
    ]
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

    private func id(_ text: String) -> Int64? { Int64(text).flatMap { status[$0] != nil ? $0 : nil } }

    private var notFound: HTTPResponse { HTTPResponse(status: 404, body: json(["message": "Not found"])) }
    private func ok(_ value: Any) -> HTTPResponse { HTTPResponse(status: 200, body: json(value)) }
    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    private var challenge: [String: Any] {
      [
        "id": Self.challengeID, "parent": 1, "name": "Downtown bench check",
        "description": "Help us find out which downtown benches are comfortable to sit on.",
        "instruction": "Look at the bench and answer what you can see.",
        "enabled": true, "cooperativeType": 3, "tags": ["mobile-survey-v1"],
      ]
    }

    /// Spread around Library Square, a few minutes' walk apart.
    private func coordinate(_ id: Int64) -> (Double, Double) {
      let i = Double(id - 184)
      return (40.7600 + 0.0011 * (i - 3.5), -111.8860 + 0.0016 * (i.truncatingRemainder(dividingBy: 3) - 1))
    }

    private func task(_ id: Int64) -> [String: Any] {
      let (lat, lng) = coordinate(id)
      var properties: [String: Any] = ["amenity": "bench"]
      properties["name"] = Self.names[id]
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
        "cooperativeWork": payload(element: id + 1000),
      ]
      if let by = completedBy[id] { o["completedBy"] = by }
      if let changeset = changesets[id] { o["changesetId"] = changeset }
      return o
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
