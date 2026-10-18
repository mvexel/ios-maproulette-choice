#!/bin/bash
# Boots an iPhone 17 on the newest iOS runtime (the Mac passes use iPhone 17), else the newest
# iPhone, so CI doesn't break when the runner image changes. Prints the udid; under GitHub
# Actions also sets the step output `udid`.
set -euo pipefail
udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
ios = sorted((k for k in devices if "iOS" in k), key=lambda k: [int(p) for p in k.rsplit("iOS-", 1)[-1].split("-")])
phones = [d for d in devices[ios[-1]] if d["name"].startswith("iPhone")]
print(next((d for d in phones if d["name"] == "iPhone 17"), phones[-1])["udid"])')
xcrun simctl list devices available | grep "$udid" >&2
# Booted before anything runs, so the first test or launch doesn't spend its time on a cold boot.
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >&2
[ -n "${GITHUB_OUTPUT:-}" ] && echo "udid=$udid" >> "$GITHUB_OUTPUT"
echo "$udid"
