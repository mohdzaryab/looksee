#!/bin/bash
# Runs the tests. Without full Xcode, Swift Testing lives in the Command Line Tools
# and needs explicit search paths (and no Foundation cross-import overlay).
set -euo pipefail
cd "$(dirname "$0")"

if xcode-select -p | grep -q CommandLineTools; then
    F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    exec swift test \
        -Xswiftc -F -Xswiftc "$F" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
