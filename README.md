# MapRoulette Choice (iOS)

A small SwiftUI app for answering MapRoulette **multiple-choice challenges** on the
[mobile-enabled MapRoulette backend](https://github.com/mvexel/maproulette-mobile-backend), built
on the [MapRoulette mobile SDK](https://github.com/mvexel/maproulette-mobile-sdk).

- **Pick a challenge**: lists the backend's challenges whose `cooperativeType` is 3 (choice).
- **See its tasks** as a list sorted by distance from you, or on a
  [MapLibre](https://maplibre.org) map with [OpenFreeMap](https://openfreemap.org) tiles.
- **Answer** the challenge's questions. Each option shows its exact tag change; the backend
  checks the element against live OSM, then applies the answers as one changeset.

The sign-in, task-answering screen and their tests are adapted from the SDK's `ios-example`
(Apache 2.0, same author).

## Build and run

Requires Xcode 26+ and iOS 17+. Swift packages (the SDK from `main`, MapLibre Native 6.x) resolve
on first open.

```sh
open MapRouletteChoice.xcodeproj   # run the MapRouletteChoice scheme
# or
xcodebuild -project MapRouletteChoice.xcodeproj -scheme MapRouletteChoice \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

For a physical device, set your team under Signing & Capabilities (keep `DEVELOPMENT_TEAM` local).

## Configuration

`Config/App.xcconfig` (public values, no secrets), overridable on the `xcodebuild` command line:

| Setting | Default | |
| --- | --- | --- |
| `MAPROULETTE_BASE_URL` | `https://mr-api.osm.lol` | Backend API origin. The dev deployment; edits development OSM. Planned rename: `mr-dev.osm.lol` (also allowed). |
| `MAPROULETTE_OAUTH_CLIENT_ID` | `maproulette-ios-example` | Native OAuth client registered on the backend with callback `org.maproulette.example:/oauth2redirect`. |
| `MAP_STYLE_URL` | `https://tiles.openfreemap.org/styles/liberty` | Any MapLibre style URL. |
| `APP_BUNDLE_IDENTIFIER` | `lol.osm.maproulette.choice` | |

Task writes (answers, skips) are sent only to `mr-api.osm.lol` / `mr-dev.osm.lol` (and loopback in
Debug with `MAPROULETTE_ALLOW_LOOPBACK=YES`); other backends are read-only. See
`AppSession.writeOrigins`.
