#!/usr/bin/env bash
# Builds a release Fivebars.app into build/. Pass --install to copy it to /Applications.
#
# Environment:
#   VERSION   marketing version (default: the VERSION file, the single version source)
#   IDENTITY  codesign identity (default "-", ad-hoc). A real identity adds the hardened runtime
#             and a secure timestamp, as notarization requires.
#   APP       output bundle path (default build/Fivebars.app)
#
# CFBundleVersion is derived from VERSION (major*10000 + minor*100 + patch), so it grows with every
# release without a second number to maintain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/build/Fivebars.app}"
IDENTITY="${IDENTITY:--}"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        *) echo "usage: $0 [--install]" >&2; exit 64 ;;
    esac
done

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]{1,2})\.([0-9]{1,2})$ ]]; then
    echo "error: VERSION must be major.minor.patch with minor and patch below 100 (got '$VERSION')" >&2
    exit 65
fi
BUILD_NUMBER=$(( BASH_REMATCH[1] * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]} ))

cd "$ROOT"
swift build -c release --arch arm64
BINDIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINDIR/Fivebars" "$APP/Contents/MacOS/Fivebars"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

# App icon: actool compiles the Icon Composer document into Assets.car (the Liquid Glass icon that
# macOS 26+ renders, light, dark and tinted) plus AppIcon.icns for older systems and Sparkle.
ICON_TMP="$(mktemp -d)"
xcrun actool "$ROOT/Resources/Icon/AppIcon.icon" --compile "$APP/Contents/Resources" \
    --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
    --development-region en --target-device mac --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$ICON_TMP/icon.plist" --output-format human-readable-text >/dev/null
plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
plutil -replace CFBundleIconName -string AppIcon "$APP/Contents/Info.plist"
rm -rf "$ICON_TMP"

# Sparkle: ditto keeps the framework's symlinks. Not sandboxed, so the XPC services aren't needed.
ditto "$BINDIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
if ! otool -l "$APP/Contents/MacOS/Fivebars" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Fivebars"
fi

# Sign inside-out, never with --deep (Sparkle's documentation).
SIGN=(codesign --force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    SIGN+=(--options runtime --timestamp)
fi
SP="$APP/Contents/Frameworks/Sparkle.framework"
for nested in "$SP/Versions/B/Autoupdate" "$SP/Versions/B/Updater.app" "$SP"; do
    "${SIGN[@]}" "$nested"
done
"${SIGN[@]}" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER, signed with ${IDENTITY/#-/ad-hoc})"

if [[ $INSTALL -eq 1 ]]; then
    pkill -x Fivebars 2>/dev/null || true
    rm -rf /Applications/Fivebars.app
    ditto "$APP" /Applications/Fivebars.app
    echo "Installed /Applications/Fivebars.app"
fi
