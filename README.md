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
review and "Saved", is reachable without an account. Each demo launch starts fresh (no last
campaign, welcome card unseen) and leaves the real app state alone.

```sh
xcrun simctl launch booted lol.osm.maproulette.choice -demo                  # campaign picker
xcrun simctl launch booted lol.osm.maproulette.choice -demo -demoMap         # campaign map
xcrun simctl launch booted lol.osm.maproulette.choice -demo -demoList        # campaign list
xcrun simctl launch booted lol.osm.maproulette.choice -demo -demoTask 185    # a place's first question
```

`-demoStops` swaps in the bus stop campaign and `-demoGuest` answers as a guest. Campaign preview
(design/preview-mode.md): `-demoDraft` serves the demo campaign as an unpublished draft (disabled,
not tagged `mobile-survey-v1`), so the picker lists nothing and only a preview link opens it.
`-demoPreview` opens it as the link would. With `-demoGuest` too, preview asks to sign in.

```sh
xcrun simctl launch booted lol.osm.maproulette.choice -demo -demoStops -demoDraft
xcrun simctl openurl booted "mrchoice://challenge/3?preview=1"                       # preview the draft
xcrun simctl launch booted lol.osm.maproulette.choice -demo -demoStops -demoDraft -demoPreview
```

Without `-demoDraft` the same link opens the published campaign normally, with the "answers are
saved for real" note.

`MapRouletteChoiceUITests` walks the demo from the picker to "Saved" and attaches a screenshot of
each screen. To also write them as PNGs:

```sh
TEST_RUNNER_SCREENSHOT_DIR="$PWD/screens" xcodebuild -project MapRouletteChoice.xcodeproj \
  -scheme MapRouletteChoice -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:MapRouletteChoiceUITests test
```

## Configuration

`Config/App.xcconfig` (public values, no secrets), overridable on the `xcodebuild` command line:

| Setting | Default | |
| --- | --- | --- |
| `MAPROULETTE_BASE_URL` | `https://mr-api.osm.lol` | Backend API origin. The dev deployment; edits development OSM. Planned rename: `mr-dev.osm.lol` (also allowed). |
| `MAPROULETTE_OAUTH_CLIENT_ID` | `maproulette-ios-choice` | Native OAuth client registered on the backend (scopes `tasks:read tasks:write osm:tagfix`). Registered on dev; stage/prod need it too. |
| `MAPROULETTE_OAUTH_CALLBACK_SCHEME` | `lol.osm.maproulette.choice` | Callback is `<scheme>:/oauth2redirect`. |
| `MAPROULETTE_GUESTS` | `NO` | `YES`: participants answer first; answers are saved on the server and go on the map once they finish signing up (deferred sign-up). Needs a backend with guests on. |
| `MAPROULETTE_ALLOW_LIVE_WRITES` | `NO` | `YES` lets `mr-stage.osm.lol` / `mr-prod.osm.lol` (real OpenStreetMap) receive answers. |
| `MAP_STYLE_URL` | `https://tiles.openfreemap.org/styles/positron` | Any MapLibre style URL. The map hides the style's POI and transit symbols so campaign pins are the only things to tap. |
| `MAP_DETAIL_STYLE_URL` | `https://tiles.openfreemap.org/styles/liberty` | The small map above a task; same symbol hiding. |
| `APP_BUNDLE_IDENTIFIER` | `lol.osm.maproulette.choice` | |

Task writes (answers, skips) are sent only to `mr-api.osm.lol` / `mr-dev.osm.lol` (and loopback in
Debug with `MAPROULETTE_ALLOW_LOOPBACK=YES`), plus `mr-stage.osm.lol` / `mr-prod.osm.lol` when
`MAPROULETTE_ALLOW_LIVE_WRITES=YES`; other backends are read-only. See `AppSession.writeOrigins`
and `liveWriteOrigins`. A stage or prod pilot build:

```sh
xcodebuild ... MAPROULETTE_BASE_URL=https://mr-stage.osm.lol MAPROULETTE_ALLOW_LIVE_WRITES=YES
```

That backend must also have the `maproulette-ios-choice` OAuth client and accept writes.

## Pilot build (TestFlight)

`scripts/archive-pilot.sh` archives a Release build with `Config/Pilot.xcconfig` (production backend,
live writes and guests on, no loopback) and exports an App Store Connect `.ipa` to `build/`. It needs
`TEAM_ID` (the Apple Developer team), a clean checkout, and Xcode signed in to that team. The build
number is the commit count, so a later commit is always a newer build. `--stage` builds the same app
against `mr-stage.osm.lol` for a rehearsal. The script checks the archived Info.plist and stops if
it isn't the pilot configuration. It never uploads; upload with Xcode Organizer or `xcrun altool`
once the release checklist clears it. Demo flags (`-demo…`) exist only in Debug builds.
