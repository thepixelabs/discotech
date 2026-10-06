#!/usr/bin/env bash
# Prints line coverage per source directory after `swift test --enable-code-coverage`,
# and exits non-zero when a gated directory is below a threshold.
#
#   swift test --enable-code-coverage
#   scripts/coverage-summary.sh [threshold-percent]     # default 0: report only
#
# Gated directories (the logic the tests target; views are not gated):
#   COVERAGE_GATE_DIRS="Model Scanner Legal Canvas"   (override with a space-separated list)
set -euo pipefail

threshold="${1:-0}"
gate_dirs="${COVERAGE_GATE_DIRS:-Model Scanner Legal Canvas}"

if ! [[ "$threshold" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "usage: $0 [threshold-percent]" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
bin_path="$(swift build --show-bin-path)"
profdata="$bin_path/codecov/default.profdata"
xctest="$bin_path/DiscotechPackageTests.xctest/Contents/MacOS/DiscotechPackageTests"

if [[ ! -f "$profdata" || ! -f "$xctest" ]]; then
  echo "No coverage data found. Run: swift test --enable-code-coverage" >&2
  exit 2
fi

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

xcrun llvm-cov export "$xctest" -instr-profile="$profdata" -summary-only \
  -ignore-filename-regex='(/\.build/|/Tests/)' > "$report"

python3 - "$report" "$threshold" "$gate_dirs" <<'PY'
import json
import os
import sys

report, threshold, gated = sys.argv[1], float(sys.argv[2]), sys.argv[3].split()
with open(report) as handle:
    files = json.load(handle)["data"][0]["files"]
marker = os.sep + "Sources" + os.sep + "Discotech" + os.sep

totals = {}
for entry in files:
    name = entry["filename"]
    if marker not in name:
        continue
    rel = name.split(marker, 1)[1]
    directory = rel.split(os.sep, 1)[0] if os.sep in rel else "(root)"
    lines = entry["summary"]["lines"]
    covered, count = totals.get(directory, (0, 0))
    totals[directory] = (covered + lines["covered"], count + lines["count"])


def pct(covered, count):
    return 100.0 * covered / count if count else 100.0


print(f"{'Directory':<12} {'Covered':>8} {'Lines':>8} {'Line %':>8}")
failed = []
for directory in sorted(totals):
    covered, count = totals[directory]
    value = pct(covered, count)
    mark = ""
    if directory in gated:
        mark = "  gated"
        if value < threshold:
            failed.append((directory, value))
            mark += "  BELOW"
    print(f"{directory:<12} {covered:>8} {count:>8} {value:>7.1f}%{mark}")
all_covered = sum(c for c, _ in totals.values())
all_count = sum(n for _, n in totals.values())
print(f"{'All':<12} {all_covered:>8} {all_count:>8} {pct(all_covered, all_count):>7.1f}%")

if failed:
    for directory, value in failed:
        print(f"coverage of {directory} is {value:.1f}%, below {threshold:g}%", file=sys.stderr)
    sys.exit(1)
PY
