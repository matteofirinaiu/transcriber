#!/bin/bash
# Runs the tests. With only the Command Line Tools (no Xcode), Swift doesn't find
# the Testing framework by itself: this tells it where it is.
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=/Library/Developer/CommandLineTools/Library/Developer
swift test \
  -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
  -Xlinker -F -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" \
  "$@"
