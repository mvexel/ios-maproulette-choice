#!/usr/bin/env python3
"""Time how long a big campaign takes to open, on a booted simulator with the app installed.

Launches the app on the `-demoLoad <n>` campaign (n made-up places, in-process, no network but map
tiles), straight onto its map, and reads two things while it loads:
- the app's "load" log (LoadLog.swift): first places shown, pages read, holds read, tally set,
  and every pin redraw;
- the app process from the host: memory (RSS, as Tess measured AB13b) and CPU, until the CPU has
  been idle for a few seconds after the tally is set.
No XCUITest and no accessibility queries: an accessibility snapshot of thousands of pins times out
(Tess, AB12) and would load the app while it is being timed.

Usage: open-time.py <simulator udid> [places]
Prints a Markdown table (also appended to $GITHUB_STEP_SUMMARY) and writes open-time.json and
open-time.log. Exits 1 if the tally isn't set within the time limit.
"""

import json
import os
import re
import subprocess
import sys
import time

BUNDLE = "lol.osm.maproulette.choice"
LIMIT = 420  # seconds; AB13 took 290 s before #57
IDLE_CPU = 0.05  # under 5% of one core
IDLE_FOR = 5.0  # seconds


def cpu_seconds(text):
    """ps `time`: [[dd-]hh:]mm:ss.cc"""
    days, _, rest = text.strip().rpartition("-")
    parts = [float(p) for p in rest.split(":")]
    seconds = sum(p * 60**i for i, p in enumerate(reversed(parts)))
    return seconds + (int(days) * 86400 if days else 0)


def main():
    udid = sys.argv[1]
    places = int(sys.argv[2]) if len(sys.argv) > 2 else 5200
    sim = ["xcrun", "simctl"]
    subprocess.run(sim + ["terminate", udid, BUNDLE], capture_output=True)
    # The map asks for the location on open; Woodbine is the middle of the grid.
    subprocess.run(sim + ["privacy", udid, "grant", "location", BUNDLE], check=True)
    subprocess.run(sim + ["location", udid, "set", "40.7545,-111.9040"], check=True)

    log_file = open("open-time.log", "w")
    stream = subprocess.Popen(
        sim + ["spawn", udid, "log", "stream", "--level", "debug", "--style", "compact", "--predicate",
               f'subsystem == "{BUNDLE}" AND category == "load"'],
        stdout=log_file, stderr=subprocess.STDOUT)
    time.sleep(2)  # let the stream attach before the first line

    launched = time.monotonic()
    out = subprocess.run(
        sim + ["launch", udid, BUNDLE, "-demo", "-demoLoad", str(places), "-demoMap"],
        check=True, capture_output=True, text=True).stdout
    pid = out.strip().rsplit(" ", 1)[-1]

    samples = []
    tally_at = idle_at = None
    last_cpu = last_t = None
    idle_since = None
    while time.monotonic() - launched < LIMIT:
        time.sleep(0.5)
        if tally_at is None and "tally set:" in open("open-time.log").read():
            tally_at = time.monotonic() - launched
        ps = subprocess.run(["ps", "-o", "rss=,time=", "-p", pid], capture_output=True, text=True).stdout.split()
        if len(ps) < 2:
            print(f"The app (pid {pid}) is gone.", file=sys.stderr)
            break
        t = time.monotonic() - launched
        rss_mb, cpu = int(ps[0]) / 1024, cpu_seconds(ps[1])
        load = (cpu - last_cpu) / (t - last_t) if last_t is not None else 1.0
        last_cpu, last_t = cpu, t
        samples.append({"t": round(t, 2), "rss_mb": round(rss_mb), "cpu": round(load, 2)})
        if tally_at is not None and load < IDLE_CPU:
            idle_since = idle_since or t
            if t - idle_since >= IDLE_FOR:
                idle_at = idle_since
                break
        else:
            idle_since = None
    stream.terminate()
    stream.wait()
    log_file.close()
    lines = open("open-time.log").read().splitlines()
    subprocess.run(sim + ["terminate", udid, BUNDLE], capture_output=True)

    def at(pattern):
        """The app's own time (since it started reading pages) on the first line matching pattern."""
        for line in lines:
            if re.search(pattern, line) and (m := re.search(r" at ([0-9.]+) s", line)):
                return float(m.group(1))
        return None

    pins = [l for l in lines if "pins:" in l]
    redraws = [float(m.group(1)) for l in pins if (m := re.search(r" in ([0-9.e-]+) seconds", l))]
    shown = re.search(r"tally set: (\d+) places", "\n".join(lines))
    result = {
        "places_asked": places,
        "places_shown": int(shown.group(1)) if shown else None,
        "first_places_s": at(r"page \d+: \d+ places shown"),
        "pages_read_s": at(r"places read at"),
        "holds_read_s": at(r"holds read at"),
        "tally_set_s": at(r"tally set:"),
        "last_pin_redraw_s": next(
            (float(m.group(1)) for l in reversed(pins) if (m := re.search(r" at ([0-9.]+) s", l))), None),
        "pin_redraws": len(pins),
        "slowest_pin_redraw_s": round(max(redraws), 2) if redraws else None,
        "tally_set_since_launch_s": round(tally_at, 1) if tally_at else None,
        "cpu_idle_since_launch_s": round(idle_at, 1) if idle_at else None,
        "peak_rss_mb": max((s["rss_mb"] for s in samples), default=None),
        "rss_at_end_mb": samples[-1]["rss_mb"] if samples else None,
    }
    json.dump({"result": result, "samples": samples}, open("open-time.json", "w"), indent=1)

    def fmt(v, unit):
        return "not reached" if v is None else f"{v:,} {unit}" if isinstance(v, int) else f"{v:.1f} {unit}"

    table = "\n".join([
        f"### Open time, {places:,} places (`-demoLoad`, Debug build)",
        "",
        "| Step | Time |",
        "|---|---|",
        f"| First places on the map | {fmt(result['first_places_s'], 's')} |",
        f"| All pages read | {fmt(result['pages_read_s'], 's')} |",
        f"| Holds read | {fmt(result['holds_read_s'], 's')} |",
        f"| Full tally set ({fmt(result['places_shown'], 'places')}) | {fmt(result['tally_set_s'], 's')} |",
        f"| Last pin redraw | {fmt(result['last_pin_redraw_s'], 's')} |",
        f"| CPU idle (since launch) | {fmt(result['cpu_idle_since_launch_s'], 's')} |",
        f"| Peak memory (RSS) | {fmt(result['peak_rss_mb'], 'MB')} |",
        f"| Memory when idle (RSS) | {fmt(result['rss_at_end_mb'], 'MB')} |",
        f"| Pin redraws, slowest | {result['pin_redraws']}, {fmt(result['slowest_pin_redraw_s'], 's')} |",
        "",
        "Step times are the app's own, from when it starts reading the campaign's pages; "
        "the targets for L1-CLUSTER are a full tally within 30 s and peak memory under 300 MB.",
        "",
    ])
    print(table)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(table + "\n")
    print("\n".join(lines[-40:]))
    return 0 if tally_at is not None else 1


if __name__ == "__main__":
    sys.exit(main())
