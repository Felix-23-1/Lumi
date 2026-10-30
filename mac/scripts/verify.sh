#!/bin/sh
# Gate für die native App: bauen + alle Prüfungen. Ohne Xcode reicht swiftc
# aus den Command Line Tools.
set -e
cd "$(dirname "$0")/.."
swift build
swift run TabyChecks "$@"
