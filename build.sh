#!/bin/bash
# ──────────────────────────────────────────────────────────────
#  Stack — build script (no Xcode project needed, just the Command Line Tools)
#
#    bash build.sh                       build for this Mac + install in /Applications
#    BUILD_MODE=release bash build.sh    universal build (Apple Silicon + Intel) + DMG in dist/
#    NO_INSTALL=1 bash build.sh          don't touch /Applications (used by GitHub Actions)
# ──────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")"

APP="Stack"
MIN_MACOS="13.0"
MODE="${BUILD_MODE:-$( [ -f .buildmode ] && tr -d '[:space:]' < .buildmode || echo dev )}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP.app"

step() { printf '\n== %s\n' "$*"; }
fail() { printf '\n❌ %s\n' "$*"; exit 1; }

# GitHub Actions workflow lives in ci/ (copied into .github/ for the repo)
if [ -f ci/release.yml ]; then mkdir -p .github/workflows && cp ci/release.yml .github/workflows/release.yml; fi

step "Stack $VERSION — mode: $MODE — $(date '+%H:%M:%S')"
sw_vers 2>/dev/null | tr '\n' ' '; echo; uname -m

xcrun --find swiftc >/dev/null 2>&1 || fail "Swift compiler not found. Run: xcode-select --install"
xcrun swiftc --version 2>&1 | head -1
SDK="$(xcrun --sdk macosx --show-sdk-path)"

if [ "$MODE" = "release" ]; then ARCHS="arm64 x86_64"; else ARCHS="$(uname -m)"; fi

# SwiftUI's @State is a compiler macro in recent SDKs: point swiftc to the macro plugins
# (the Command Line Tools don't always add this path on their own).
DEVDIR="$(xcode-select -p 2>/dev/null)"
SWIFTC="$(xcrun --find swiftc)"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$SWIFTC")")")"
PLUGIN_ARGS=()
while IFS= read -r dir; do
  [ -n "$dir" ] && PLUGIN_ARGS+=(-plugin-path "$dir")
done < <(find "$SDK/usr/lib/swift/host/plugins" "$TOOLCHAIN" "$DEVDIR" -name 'libSwiftUIMacros*.dylib' 2>/dev/null | xargs -n1 dirname 2>/dev/null | sort -u)
echo "developer dir: $DEVDIR"
echo "macro plugins: ${PLUGIN_ARGS[*]:-none found}"

rm -rf "$APP_DIR" "$BUILD_DIR/obj"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR/obj"

BINS=()
for ARCH in $ARCHS; do
  step "Compiling ($ARCH)"
  xcrun swiftc -O -swift-version 5 -parse-as-library \
    -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" \
    -module-name "$APP" ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} \
    Sources/*.swift -o "$BUILD_DIR/obj/$APP-$ARCH" || fail "Compilation failed ($ARCH)"
  BINS+=("$BUILD_DIR/obj/$APP-$ARCH")
done
lipo -create "${BINS[@]}" -output "$APP_DIR/Contents/MacOS/$APP" || fail "lipo failed"

step "Bundling"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
for L in Resources/*.lproj; do cp -R "$L" "$APP_DIR/Contents/Resources/"; done
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
codesign --force --sign - --timestamp=none "$APP_DIR" || fail "codesign failed"
codesign --verify "$APP_DIR" && echo "signature OK (ad-hoc)"
lipo -info "$APP_DIR/Contents/MacOS/$APP"

if [ "${NO_INSTALL:-0}" != "1" ]; then
  step "Installing in /Applications"
  pkill -f "/Applications/$APP.app/Contents/MacOS/$APP" 2>/dev/null && sleep 0.5
  rm -rf "/Applications/$APP.app"
  ditto "$APP_DIR" "/Applications/$APP.app" || fail "Could not copy to /Applications"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP.app" >/dev/null 2>&1 || true
  touch "/Applications/$APP.app"
  echo "Installed: /Applications/$APP.app"
fi

if [ "$MODE" = "release" ]; then
  step "Creating DMG"
  mkdir -p dist
  DMG="dist/$APP-$VERSION.dmg"
  rm -f "$DMG"
  if [ ! -x "$BUILD_DIR/venv/bin/dmgbuild" ]; then
    python3 -m venv "$BUILD_DIR/venv" >/dev/null 2>&1 && "$BUILD_DIR/venv/bin/pip" install -q dmgbuild >/dev/null 2>&1 \
      || echo "(could not install dmgbuild — falling back to a plain DMG)"
  fi
  tiffutil -cathidpicheck Resources/dmg/background.png Resources/dmg/background@2x.png \
    -out "$BUILD_DIR/dmg-background.tiff" >/dev/null 2>&1
  if [ -x "$BUILD_DIR/venv/bin/dmgbuild" ] && [ -f "$BUILD_DIR/dmg-background.tiff" ]; then
    "$BUILD_DIR/venv/bin/dmgbuild" -s Resources/dmg/settings.py \
      -D app="$APP_DIR" -D background="$BUILD_DIR/dmg-background.tiff" "$APP" "$DMG" || fail "dmgbuild failed"
  else
    STAGE="$BUILD_DIR/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
    ditto "$APP_DIR" "$STAGE/$APP.app"; ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null || fail "hdiutil failed"
  fi
  echo "DMG: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
fi

if [ "$(cat .smoketest 2>/dev/null)" = "on" ] && [ "${NO_INSTALL:-0}" != "1" ]; then
  step "Smoke test"
  bash scripts/smoke-test.sh
fi
if [ "$(cat .dockdiag 2>/dev/null)" = "on" ]; then
  step "Dock diagnostic"
  bash scripts/dock-diag.sh
fi

step "✅ Done"
