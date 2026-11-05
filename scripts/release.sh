#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Looksee.app and packs it into dist/Looksee-<version>.dmg,
# the one file to send to friends. Command Line Tools are enough; no Xcode needed.
#
#   ./scripts/release.sh                       # signed with "Zaryab Local Code Signing" if present, else ad-hoc
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./scripts/release.sh
#
# The version comes from CFBundleShortVersionString in Resources/Info.plist; bump it there first.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=Looksee
BUNDLE_ID=com.zaryab.looksee
PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")
SIGN_ID="${SIGN_IDENTITY:-Zaryab Local Code Signing}"
security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID" || SIGN_ID="-"
ARCHS=(arm64 x86_64)

OUT=build/release
APP="$OUT/$NAME.app"
STAGE="$OUT/dmg"
DIST=dist
DMG="$DIST/$NAME-$VERSION.dmg"
LOG=$(mktemp -t looksee-release)
trap 'rm -f "$LOG"' EXIT
die() { echo "✗ $*" >&2; exit 1; }

echo "▸ $NAME $VERSION (macOS $MIN_OS+), signing identity: $SIGN_ID"

# 1. One build per architecture, then lipo. (`swift build --arch a --arch b` needs Xcode's XCBuild.)
SLICES=()
for arch in "${ARCHS[@]}"; do
  echo "▸ swift build release ($arch)"
  args=(-c release --product "$NAME" --triple "$arch-apple-macosx$MIN_OS" --scratch-path ".build/release-$arch")
  if ! swift build "${args[@]}" >"$LOG" 2>&1; then
    tail -30 "$LOG"
    die "build failed ($arch)"
  fi
  bin="$(swift build "${args[@]}" --show-bin-path)/$NAME"
  [ -x "$bin" ] || die "missing $bin"
  SLICES+=("$bin")
done

mkdir -p "$OUT"
UNIVERSAL="$OUT/$NAME"
lipo -create "${SLICES[@]}" -output "$UNIVERSAL"
lipo "$UNIVERSAL" -verify_arch "${ARCHS[@]}" || die "universal binary is missing an architecture"
echo "✓ $(lipo -info "$UNIVERSAL")"

# The linker records the Command Line Tools' Swift back-deploy folder as an rpath; it doesn't exist on
# other Macs. Drop it as long as nothing is loaded via @rpath.
if ! otool -L "$UNIVERSAL" | grep -q "@rpath/"; then
  for rp in $(otool -l "$UNIVERSAL" | awk '/cmd LC_RPATH/{r=1} r&&/ path /{print $2; r=0}' | sort -u); do
    case "$rp" in /Library/Developer/*|/Applications/Xcode*)
      install_name_tool -delete_rpath "$rp" "$UNIVERSAL" 2>/dev/null || echo "  (kept rpath $rp)" ;;
    esac
  done
fi

# 2. Bundle.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UNIVERSAL" "$APP/Contents/MacOS/$NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod -R u+rwX,go+rX "$APP"

# 3. Sign. With ad-hoc, pin the designated requirement to the bundle id so macOS keeps the Camera and
#    Accessibility grants across updates; a real identity gives that for free.
SIGN_ARGS=(--force --sign "$SIGN_ID" --identifier "$BUNDLE_ID")
if [ "$SIGN_ID" = "-" ]; then
  SIGN_ARGS+=(-r="designated => identifier \"$BUNDLE_ID\"")
else
  SIGN_ARGS+=(--timestamp=none)
fi
echo "▸ codesign ($SIGN_ID)"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP" || die "signature does not verify"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Format|Signature)=" | sed 's/^/  /'

# 4. Disk image: the app, an Applications shortcut, and the read-me.
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "Resources/Read Me First.txt" "$STAGE/Read Me First.txt"

rm -f "$DMG"
echo "▸ hdiutil create $DMG"
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify -quiet "$DMG" || die "dmg failed verification"

rm -rf "$STAGE" "$UNIVERSAL"
echo "✓ $DMG  ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
