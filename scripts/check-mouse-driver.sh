#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/checks
swiftc -parse-as-library Sources/Shared/MouseCommand.swift Sources/Mac/MouseDriver.swift \
  Tests/RemotePadTests/MouseDriverChecks.swift -o build/checks/MouseDriverChecks
build/checks/MouseDriverChecks
