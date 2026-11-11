#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cp tests/job-model.swift "$t/main.swift"
xcrun swiftc -swift-version 5 Sources/PopcornNodes/Models.swift "$t/main.swift" -o "$t/model-tests"
"$t/model-tests"
