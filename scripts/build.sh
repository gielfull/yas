#!/usr/bin/env bash
# Generate the Xcode project and build an unsigned Debug app into build/.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate
xcodebuild -scheme YAS -configuration Debug -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
