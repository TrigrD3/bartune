#!/usr/bin/env bash
set -euo pipefail

BIN_PATH=""
PROFDATA=""
OUTPUT="coverage.lcov"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-path)
            if [[ $# -lt 2 ]]; then
                echo "::error::--bin-path requires a value." >&2
                exit 2
            fi
            BIN_PATH="$2"
            shift 2
            ;;
        --profdata)
            if [[ $# -lt 2 ]]; then
                echo "::error::--profdata requires a value." >&2
                exit 2
            fi
            PROFDATA="$2"
            shift 2
            ;;
        --output)
            if [[ $# -lt 2 ]]; then
                echo "::error::--output requires a value." >&2
                exit 2
            fi
            OUTPUT="$2"
            shift 2
            ;;
        *)
            echo "::error::Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ -z "$BIN_PATH" ]]; then
    BIN_PATH="$(swift build --show-bin-path)"
fi

if [[ -z "$PROFDATA" ]]; then
    PROFDATA="$(swift test --show-codecov-path | sed 's|/codecov/.*|/codecov/default.profdata|')"
fi

TEST_BIN=""
if [[ -f "$BIN_PATH/BarTuneTests.xctest/Contents/MacOS/BarTuneTests" ]]; then
    TEST_BIN="$BIN_PATH/BarTuneTests.xctest/Contents/MacOS/BarTuneTests"
else
    TEST_BIN="$(find "$BIN_PATH" -maxdepth 4 -type f \( -path '*/BarTuneTests.xctest/Contents/MacOS/BarTuneTests' -o -name 'BarTunePackageTests' \) | head -n 1 || true)"
fi

if [[ -z "$TEST_BIN" || ! -f "$TEST_BIN" ]]; then
    echo "::error::Could not locate Swift test binary under '$BIN_PATH' (checked BarTuneTests.xctest/Contents/MacOS/BarTuneTests and BarTunePackageTests)." >&2
    exit 1
fi

if [[ ! -f "$PROFDATA" ]]; then
    echo "::error::Coverage profdata file not found at '$PROFDATA'." >&2
    exit 1
fi

TMP_OUT="$(mktemp "${OUTPUT}.tmp.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

xcrun llvm-cov export -format=lcov "$TEST_BIN" -instr-profile="$PROFDATA" > "$TMP_OUT"

if [[ ! -s "$TMP_OUT" ]]; then
    echo "::error::Exported LCOV coverage report is empty (binary: '$TEST_BIN', profdata: '$PROFDATA')." >&2
    exit 1
fi

mv "$TMP_OUT" "$OUTPUT"
echo "==> Exported LCOV coverage to $OUTPUT ($(wc -l < "$OUTPUT" | tr -d '[:space:]') lines)"
