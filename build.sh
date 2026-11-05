#!/bin/bash
# Builds Looksee and wraps it in an ad-hoc signed .app bundle.
#   ./build.sh        build build/Looksee.app
#   ./build.sh run    build, then (re)launch it
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Looksee.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Looksee"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Looksee"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc signatures change on every build, which makes macOS forget the Accessibility and Camera
# grants. If a code-signing identity named below exists in the keychain, use it so the grants stick.
SIGN_IDENTITY="${SIGN_IDENTITY:-Zaryab Local Code Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
    echo "note: ad-hoc signed; rebuilds will need Accessibility re-granted (see README)"
fi
echo "Built $APP"

if [ "${1:-}" = "run" ]; then
    pkill -x Looksee 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Looksee >/dev/null || break; sleep 0.3; done
    open "$APP"
fi
