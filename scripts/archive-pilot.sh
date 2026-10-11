#!/bin/sh
# Archives the pilot build and exports a TestFlight .ipa. It does not upload: that needs
# Martijn's OK (release/woodbine-release-checklist.md I6).
#
#   TEAM_ID=XXXXXXXXXX scripts/archive-pilot.sh          # production (Config/Pilot.xcconfig)
#   TEAM_ID=XXXXXXXXXX scripts/archive-pilot.sh --stage  # the same build against mr-stage
#
# The build number is the commit count on HEAD, so each later commit uploads as a newer build.
# Run from a clean checkout of the release sha.
set -eu
cd "$(dirname "$0")/.."

: "${TEAM_ID:?Set TEAM_ID to the Apple Developer team ID}"
base=https://mr-prod.osm.lol
[ "${1:-}" = "--stage" ] && base=https://mr-stage.osm.lol

if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean; archive a committed sha." >&2
  exit 1
fi
sha=$(git rev-parse --short HEAD)
build=$(git rev-list --count HEAD)
out="build/pilot-$sha"
archive="$out/StreetTally.xcarchive"

xcodebuild archive -project MapRouletteChoice.xcodeproj -scheme MapRouletteChoice \
  -configuration Release -destination 'generic/platform=iOS' -archivePath "$archive" \
  -xcconfig Config/Pilot.xcconfig MAPROULETTE_BASE_URL="$base" \
  CURRENT_PROJECT_VERSION="$build" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates

# Refuse an archive that isn't the pilot configuration.
plist="$archive/Products/Applications/MapRouletteChoice.app/Info.plist"
check() {
  actual=$(/usr/libexec/PlistBuddy -c "Print :$1" "$plist")
  if [ "$actual" != "$2" ]; then
    echo "Info.plist $1 is '$actual', expected '$2'." >&2
    exit 1
  fi
}
check MRBaseURL "$base"
check MRAllowLiveWrites YES
check MRGuests YES
check MRAllowLoopback NO
check CFBundleVersion "$build"
check CFBundleIdentifier lol.osm.maproulette.choice

xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" \
  -exportOptionsPlist Config/ExportOptions.plist -allowProvisioningUpdates

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
echo "Exported $out (version $version, build $build, $sha, $base)."
