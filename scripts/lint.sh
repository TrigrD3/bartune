#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-all}"

if [[ "$MODE" == "--format-only" || "$MODE" == "all" ]]; then
    echo "==> Checking SwiftFormat..."
    swiftformat Sources Tests --lint
fi

if [[ "$MODE" == "--lint-only" || "$MODE" == "all" ]]; then
    echo "==> Running SwiftLint..."
    swiftlint lint --strict
fi
