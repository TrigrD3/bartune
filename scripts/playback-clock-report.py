#!/usr/bin/env python3
"""Summarizes BarTune's playback-clock log per track: how far the overlay's clock was from the
player's reported position on each poll.

    log stream --level debug --predicate 'subsystem == "com.arya.BarTune" AND category == "playback-clock"' > clock.log
    python3 scripts/playback-clock-report.py clock.log
"""

import re
import statistics
import sys

SAMPLE = re.compile(r"clock track=(\S+) error_ms=(-?[\d.]+) rtt_ms=([\d.]+) reanchored=(\w+)")


def percentile(values, share):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))]


def main(path):
    tracks = {}
    with open(path, encoding="utf-8") as log:
        for line in log:
            match = SAMPLE.search(line)
            if match:
                track, error, rtt, reanchored = match.groups()
                samples = tracks.setdefault(track, [])
                samples.append((float(error), float(rtt), reanchored.lower() in ("true", "yes", "1")))
    if not tracks:
        sys.exit(f"No playback-clock samples in {path}")

    print(f"{'track':40} {'polls':>5} {'|err| med':>9} {'|err| p95':>9} {'bias':>7} {'rtt med':>7} {'re-anchor':>9}")
    everything = []
    for track, samples in tracks.items():
        everything += samples
        print(row(track, samples))
    print(row("ALL", everything))


def row(name, samples):
    errors = [error for error, _, _ in samples]
    absolute = [abs(error) for error in errors]
    return (
        f"{name[:40]:40} {len(samples):5d} {statistics.median(absolute):7.1f}ms {percentile(absolute, 0.95):7.1f}ms "
        f"{statistics.mean(errors):+5.1f}ms {statistics.median(rtt for _, rtt, _ in samples):5.1f}ms "
        f"{sum(reanchored for _, _, reanchored in samples):9d}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
