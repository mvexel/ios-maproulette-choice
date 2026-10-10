# Street Tally (iOS)

Street Tally (repo and bundle keep the MapRoulette Choice name) is a small SwiftUI app for answering MapRoulette **multiple-choice challenges** on the
[mobile-enabled MapRoulette backend](https://github.com/mvexel/maproulette-mobile-backend), built
on the [MapRoulette mobile SDK](https://github.com/mvexel/maproulette-mobile-sdk).

- **Pick a campaign**: lists the backend's choice challenges (`cooperativeType` 3) published for
  mobile (tag `mobile-survey-v1`, added by the admin's Publish), or
  open one directly with `https://streettally.osm.lol/challenge/<id>` (a universal link; Share
  campaign shows it as a QR code) or `mrchoice://challenge/<id>`. The host is
  `CAMPAIGN_LINK_HOST` in `Config/App.xcconfig` and must serve `apple-app-site-association`. The
  app reopens the last campaign on launch; a welcome card explains each campaign once.
- **See its places** on a [MapLibre](https://maplibre.org) map with
  [OpenFreeMap](https://openfreemap.org) tiles or in a list sorted by distance, with checked places
  greyed out, campaign progress, today's count, and the nearest place one tap away.
- **Answer** one question per screen with large buttons and "I'm not sure", review, then Done.
  The backend checks the element against live OSM and applies the answers as one changeset.
  "Something's wrong here" holds the challenge's outcomes, "Too hard to tell" and Skip.
- **Show OSM details** (Settings, off by default) reveals tag changes, task and element ids,
  changeset links and the "Allow deleting OSM elements" setting.

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

Demo mode (Debug builds): launch with `-demo` to use an in-process mock campaign of eight
downtown Salt Lake City benches, signed in, with no network. Every screen, including questions,
review and "Saved", is reachable without an account:

```sh
xcrun simctl launch booted lol.osm.maproulette.choice -demo
xcrun simctl openurl booted mrchoice://challenge/3              # the demo campaign
xcrun simctl launch booted lol.osm.maproulette.choice -demo -demoMap         # its map
xcrun simctl launch booted lol.osm.maproulette.choice -demo -demoList        # its list
xcrun simctl launch booted lol.osm.maproulette.choice -demo -demoTask 185    # a place's first question
```

`-demoMap`, `-demoList` and `-demoTask` apply when the demo campaign opens (the app reopens the last
campaign) and skip its welcome card.

## Configuration

`Config/App.xcconfig` (public values, no secrets), overridable on the `xcodebuild` command line:

| Setting | Default | |
| --- | --- | --- |
| `MAPROULETTE_BASE_URL` | `https://mr-api.osm.lol` | Backend API origin. The dev deployment; edits development OSM. Planned rename: `mr-dev.osm.lol` (also allowed). |
| `MAPROULETTE_OAUTH_CLIENT_ID` | `maproulette-ios-choice` | Native OAuth client registered on the backend (scopes `tasks:read tasks:write osm:tagfix`). Registered on dev; stage/prod need it too. |
| `MAPROULETTE_OAUTH_CALLBACK_SCHEME` | `lol.osm.maproulette.choice` | Callback is `<scheme>:/oauth2redirect`. |
| `MAP_STYLE_URL` | `https://tiles.openfreemap.org/styles/liberty` | Any MapLibre style URL. |
| `APP_BUNDLE_IDENTIFIER` | `lol.osm.maproulette.choice` | |

Task writes (answers, skips) are sent only to `mr-api.osm.lol` / `mr-dev.osm.lol` (and loopback in
Debug with `MAPROULETTE_ALLOW_LOOPBACK=YES`); other backends are read-only. See
`AppSession.writeOrigins`.
