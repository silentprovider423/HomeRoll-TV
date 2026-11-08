#!/bin/bash
# Unit-Tests der gemeinsamen Logik auf dem Mac (kein tvOS-Simulator nötig). Mit .test-account (gitignored)
# laufen zusätzlich die Live-Tests gegen das Immich-Testkonto.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .test-account ] && source .test-account
cd Core && swift test 2>&1 | grep -vE "^\[|^Building|^Build complete|Compiling|Write swift" 
