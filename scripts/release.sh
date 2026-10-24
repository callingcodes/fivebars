#!/usr/bin/env bash
# Builds, signs, notarizes and packages a Fivebars release, and writes its appcast.
#
# Usage:
#   scripts/release.sh <version> [--publish]          Developer ID release (needs the one-time setup)
#   scripts/release.sh <version> --adhoc              dry run: ad-hoc signed, no notarization, no upload
#   scripts/release.sh <version> --no-notarize        dry run signed with the Developer ID (hardened
#                                                     runtime), no notarization, no upload
#   scripts/release.sh <version> --test               full Developer ID path (notarized, stapled) for any
#                                                     version, relaxed checks, no upload: a local rehearsal
#   scripts/release.sh <version> --resume             finish a --publish that failed midway: no rebuild;
#                                                     re-checks and uploads the existing build/release/<version>/
#                                                     files (archives only if absent), then appcast.xml and latest.json
#   options: --download-base <url>   enclosure URL prefix (default https://callingcodes.com/fivebars/download;
#                                    override only to test against a local server; refused with --publish)
#   FIVEBARS_SIGN_IDENTITY=<sha1|name>  codesign identity (default: PINNED_SHA1, the G2 Developer ID
#                                    certificate). A name must match exactly one certificate. The G2,
#                                    team and expiry checks apply to any identity.
#
# Guards (scripts/release-guards.sh): the build must be newer than every build in the live appcast,
# only a 404 counts as "no appcast yet", a published archive is never overwritten with other bytes,
# and the app, its Sparkle helpers, the zip and the DMG must be signed by the pinned certificate.
#
# Output: build/release/<version>/ holds Fivebars-<version>.zip (the Sparkle update), Fivebars-<version>.dmg
# (first install), appcast.xml (the previous appcast plus this release) and latest.json. A dry run
# (--adhoc or --no-notarize) also copies the appcast to build/release/appcast.xml, so build/release can be served as a local test feed.
#
# Release notes: release-notes/<version>.html (an HTML fragment), embedded in the appcast item.
# The upload to R2 happens only with --publish; otherwise the exact commands are printed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TEAM_NAME="Calling Codes"
NOTARY_PROFILE="fivebars-notary"
BUCKET="fivebars-releases"
APPCAST_URL="https://callingcodes.com/fivebars/appcast.xml"
CONTRACT_DOWNLOAD_BASE="https://callingcodes.com/fivebars/download"
DOWNLOAD_BASE="$CONTRACT_DOWNLOAD_BASE"
TEAM_ID="232ZPKUQMV"
# SHA-1 of the "Developer ID Application: Calling Code (232ZPKUQMV)" certificate issued by the
# G2 Developer ID CA (valid until 2027-11-23). Signing goes by hash because an older non-G2
# certificate (0AE0602C..., expires 2027-02-01) has the same name. Public, not a secret.
# On renewal: security find-identity -v -p codesigning, and update this line.
PINNED_SHA1="9B2724121C10B0414AD15A3230FCE816A5B86B85"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

VERSION=""
ADHOC=0
NOTARIZE=1
PUBLISH=0
TEST=0
RESUME=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --adhoc|--dry-run) ADHOC=1; NOTARIZE=0 ;;
        --no-notarize) NOTARIZE=0 ;;
        --test) TEST=1 ;;
        --publish) PUBLISH=1 ;;
        --resume) RESUME=1 ;;
        --download-base) DOWNLOAD_BASE="${2:?--download-base needs a URL}"; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        -*) echo "error: unknown option $1" >&2; exit 64 ;;
        *) VERSION="$1" ;;
    esac
    shift
done

fail() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
# shellcheck source=release-guards.sh
source "$ROOT/scripts/release-guards.sh"

[[ -n "$VERSION" ]] || fail "usage: scripts/release.sh <version> [--adhoc | --publish]"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]{1,2}\.[0-9]{1,2}$ ]] || fail "version must be major.minor.patch (got $VERSION)"
DRY=$(( (1 - NOTARIZE) | TEST ))
[[ $DRY -eq 1 && $PUBLISH -eq 1 ]] && fail "--publish can't be combined with --adhoc, --no-notarize or --test"
[[ $DRY -eq 1 && $RESUME -eq 1 ]] && fail "--resume can't be combined with --adhoc, --no-notarize or --test"
if [[ $(( PUBLISH | RESUME )) -eq 1 && "$DOWNLOAD_BASE" != "$CONTRACT_DOWNLOAD_BASE" ]]; then
    fail "--download-base $DOWNLOAD_BASE would point the public appcast elsewhere; publishing uses $CONTRACT_DOWNLOAD_BASE only"
fi
[[ "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]
# Same formula as build-app.sh.
EXPECTED_BUILD=$(( BASH_REMATCH[1] * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]} ))

OUT="$ROOT/build/release/$VERSION"
APP="$OUT/Fivebars.app"
ZIP="$OUT/Fivebars-$VERSION.zip"
DMG="$OUT/Fivebars-$VERSION.dmg"
NOTES="$ROOT/release-notes/$VERSION.html"
UPLOADS=(
    "npx wrangler r2 object put $BUCKET/Fivebars-$VERSION.zip --remote --file $ZIP --content-type application/zip"
    "npx wrangler r2 object put $BUCKET/Fivebars-$VERSION.dmg --remote --file $DMG --content-type application/x-apple-diskimage"
    "npx wrangler r2 object put $BUCKET/appcast.xml --remote --file $OUT/appcast.xml --content-type application/xml"
    "npx wrangler r2 object put $BUCKET/latest.json --remote --file $OUT/latest.json --content-type application/json"
)

# Runs every check again on the files about to go out, then uploads the archives (unless the
# identical bytes are already published), verifies what is served, and only then the feed.
publish_release() {
    local mode="${1:-new}" live state_zip state_dmg
    step "Checks before upload"
    check_artifacts "$ZIP" "$DMG" "$IDENTITY" "$TEAM_ID" notarized || exit 1
    live="$(mktemp)"
    fetch_appcast "$APPCAST_URL" "$live" || exit 1
    check_build_newer "$BUILD_NUMBER" "$live" "$mode" || exit 1
    rm -f "$live"
    state_zip="$(remote_state "$DOWNLOAD_BASE/Fivebars-$VERSION.zip" "$ZIP")" || exit 1
    state_dmg="$(remote_state "$DOWNLOAD_BASE/Fivebars-$VERSION.dmg" "$DMG")" || exit 1
    step "Upload to R2"
    if [[ "$state_zip" == absent ]]; then eval "${UPLOADS[0]}"; else echo "Fivebars-$VERSION.zip: already published, same bytes"; fi
    if [[ "$state_dmg" == absent ]]; then eval "${UPLOADS[1]}"; else echo "Fivebars-$VERSION.dmg: already published, same bytes"; fi
    check_served "$DOWNLOAD_BASE/Fivebars-$VERSION.zip" "$ZIP" || fail "appcast not uploaded"
    check_served "$DOWNLOAD_BASE/Fivebars-$VERSION.dmg" "$DMG" || fail "appcast not uploaded"
    for command in "${UPLOADS[@]:2}"; do eval "$command"; done
    check_served "$APPCAST_URL" "$OUT/appcast.xml" || fail "the served appcast differs from $OUT/appcast.xml"
}

# 0. Preconditions ------------------------------------------------------------------------------------
step "Preconditions"
[[ -x "$SPARKLE_BIN/sign_update" ]] || swift package resolve >/dev/null
[[ -x "$SPARKLE_BIN/sign_update" ]] || fail "Sparkle tools not found in $SPARKLE_BIN (run swift build once)"
"$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1 || fail "no Sparkle EdDSA key in the login Keychain.
  Restore the backup: $SPARKLE_BIN/generate_keys -f <backup-file>
  (A new key would not match SUPublicEDKey in shipped copies; never generate one for an existing app.)"
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
PLIST_KEY="$(plutil -extract SUPublicEDKey raw Resources/Info.plist)"
[[ "$PUBLIC_KEY" == "$PLIST_KEY" ]] || fail "the Keychain's EdDSA public key ($PUBLIC_KEY) differs from SUPublicEDKey in Resources/Info.plist ($PLIST_KEY)"

if [[ $DRY -eq 1 ]]; then
    echo "Dry run: no upload$([[ $NOTARIZE -eq 0 ]] && echo ", no notarization")."
    [[ -z "$(git status --porcelain)" ]] || echo "warning: uncommitted changes are included in this dry run"
else
    [[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes; commit or stash them first"
    FILE_VERSION="$(tr -d '[:space:]' < VERSION)"
    [[ "$FILE_VERSION" == "$VERSION" ]] || fail "VERSION says $FILE_VERSION; set it to $VERSION and commit first"
fi
if [[ $ADHOC -eq 1 ]]; then
    IDENTITY="-"
    echo "Signing ad-hoc."
else
    IDENTITY="${FIVEBARS_SIGN_IDENTITY:-$PINNED_SHA1}"
    IDENTITIES="$(security find-identity -v -p codesigning)"
    if [[ ! "$IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        # A name: resolve it to one hash, since a renewed certificate keeps the same name.
        HASHES="$(grep -F "\"$IDENTITY\"" <<<"$IDENTITIES" | awk '{print $2}' | sort -u)"
        [[ $(grep -c . <<<"$HASHES") -eq 1 ]] || fail "identity \"$IDENTITY\" matches $(grep -c . <<<"$HASHES") certificates; set FIVEBARS_SIGN_IDENTITY to a SHA-1 from: security find-identity -v -p codesigning"
        IDENTITY="$HASHES"
    fi
    grep -qi "$IDENTITY" <<<"$IDENTITIES" || fail "no codesigning identity $IDENTITY in the Keychain.
  Create it once (Account Holder role) at developer.apple.com > Certificates > + > Developer ID Application,
  Profile Type G2 Sub-CA, with a CSR from Keychain Access > Certificate Assistant > Request a Certificate
  From a Certificate Authority (saved to disk). Double-click the downloaded .cer to install it, then check:
  security find-identity -v -p codesigning
  Until then, test with: scripts/release.sh $VERSION --adhoc"
        check_identity "$IDENTITY" || exit 1
    echo "Signing as: $(grep -i "$IDENTITY" <<<"$IDENTITIES" | head -1 | sed 's/^ *[0-9]*) //')"
fi
if [[ $NOTARIZE -eq 1 ]]; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "no notary credentials named $NOTARY_PROFILE.
  Store them once: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <TEAMID> --password <app-specific password>
  (app-specific password: account.apple.com > Sign-In and Security > App-Specific Passwords)
  Until then, test the signed build with: scripts/release.sh $VERSION --no-notarize"
    [[ $DRY -eq 1 || -f "$NOTES" ]] || fail "write the release notes first: $NOTES (an HTML fragment, e.g. <ul><li>…</li></ul>)"
fi

if [[ $DRY -eq 0 && $RESUME -eq 0 ]]; then
    LIVE_APPCAST="$(mktemp)"
    fetch_appcast "$APPCAST_URL" "$LIVE_APPCAST" || exit 1
    check_build_newer "$EXPECTED_BUILD" "$LIVE_APPCAST" || exit 1
    rm -f "$LIVE_APPCAST"
fi

if [[ $RESUME -eq 1 ]]; then
    step "Resume the upload of $VERSION from $OUT (no rebuild)"
    for f in "$ZIP" "$DMG" "$OUT/appcast.xml" "$OUT/latest.json"; do
        [[ -f "$f" ]] || fail "--resume needs the original build, and $f is missing"
    done
    BUILD_NUMBER="$(sed -n 's/.*"build":\([0-9]*\).*/\1/p' "$OUT/latest.json")"
    [[ "$BUILD_NUMBER" == "$EXPECTED_BUILD" ]] || fail "$OUT/latest.json has build $BUILD_NUMBER, expected $EXPECTED_BUILD"
    grep -qF "url=\"$DOWNLOAD_BASE/Fivebars-$VERSION.zip\" length=\"$(stat -f %z "$ZIP")\"" "$OUT/appcast.xml" \
        || fail "$OUT/appcast.xml does not describe $ZIP"
    publish_release resume
    step "Fivebars $VERSION (build $BUILD_NUMBER) published from $OUT"
    exit 0
fi

# 1. Test and build -----------------------------------------------------------------------------------
step "Tests"
swift test

# Never delete the files of a version that is already (even partly) published.
PUBLISHED_URLS=("$CONTRACT_DOWNLOAD_BASE/Fivebars-$VERSION.zip" "$CONTRACT_DOWNLOAD_BASE/Fivebars-$VERSION.dmg")
if [[ "$DOWNLOAD_BASE" != "$CONTRACT_DOWNLOAD_BASE" ]]; then
    PUBLISHED_URLS+=("$DOWNLOAD_BASE/Fivebars-$VERSION.zip" "$DOWNLOAD_BASE/Fivebars-$VERSION.dmg")
fi
check_unpublished "$([[ $DRY -eq 0 ]] && echo strict || echo lenient)" "${PUBLISHED_URLS[@]}" || exit 1

step "Build $VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
APP="$APP" VERSION="$VERSION" IDENTITY="$IDENTITY" scripts/build-app.sh
codesign --verify --strict --deep --verbose=2 "$APP"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"

notarize() {
    # Submissions sometimes sit "In Progress" for hours; resume with: xcrun notarytool info <id> ...
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 2h \
        || fail "notarization of $1 failed or timed out. Inspect: xcrun notarytool history --keychain-profile $NOTARY_PROFILE, then xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"
}

# 2. Notarize and staple the app ----------------------------------------------------------------------
if [[ $ADHOC -eq 0 ]]; then
    check_app_signatures "$APP" "$IDENTITY" "$TEAM_ID" || exit 1
fi
if [[ $NOTARIZE -eq 1 ]]; then
    step "Notarize the app"
    ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
    notarize "$OUT/notarize.zip"
    rm -f "$OUT/notarize.zip"
    xcrun stapler staple "$APP"
    spctl -a -vvv -t exec "$APP"
else
    step "Skip notarization (dry run)"
fi

# 3. Update archive, from the stapled app -------------------------------------------------------------
step "Update archive"
ditto -c -k --keepParent "$APP" "$ZIP"

# 4. DMG for first installs ---------------------------------------------------------------------------
step "DMG"
# A read-write image gets the designed window (Finder lays it out and writes .DS_Store), then is
# converted to a compressed read-only one. Layout needs Finder automation permission; without it
# the DMG still works, just with Finder's default window.
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Fivebars.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$ROOT/Resources/DMG/background.tiff" "$STAGE/.background/background.tiff"
RW="$OUT/Fivebars-rw.dmg"
rm -f "$RW" "$DMG"
hdiutil create -quiet -volname "Fivebars" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
rm -rf "$STAGE"
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)"
[[ -d "$MOUNT" ]] || fail "could not mount $RW"
# A placeholder volume icon is present during layout so Finder records its parked position.
cp "$ROOT/Resources/DMG/VolumeIcon.icns" "$MOUNT/.VolumeIcon.icns"
chflags hidden "$MOUNT/.background" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a V "$MOUNT/.background" "$MOUNT/.VolumeIcon.icns"
VOLUME="$(basename "$MOUNT")"
if ! osascript <<OSA
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set sidebar width of container window to 0
        set the bounds of container window to {200, 120, 840, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Fivebars.app" of container window to {160, 170}
        set position of item "Applications" of container window to {480, 170}
        -- Parked far outside the window, for Finders set to show hidden files.
        repeat with parked in {".background", ".VolumeIcon.icns", ".fseventsd", ".DS_Store"}
            try
                set position of item parked of container window to {900, 900}
            end try
        end repeat
        update without registering applications
        close
        -- Finder only keeps the window bounds when they are set again on a reopened window.
        open
        delay 1
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 520}
        delay 2
        close
    end tell
end tell
OSA
then
    echo "warning: Finder layout failed (if denied: System Settings > Privacy & Security > Automation); the DMG keeps the default window" >&2
fi
# The volume icon goes in again last: hdiutil -srcfolder drops it, and Finder's layout pass clears it.
cp "$ROOT/Resources/DMG/VolumeIcon.icns" "$MOUNT/.VolumeIcon.icns"
chflags hidden "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a V "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
sync
for _ in 1 2 3 4 5; do hdiutil detach -quiet "$MOUNT" && break; sleep 2; done
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"
if [[ $ADHOC -eq 0 ]]; then
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
if [[ $NOTARIZE -eq 1 ]]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi
if [[ $ADHOC -eq 0 ]]; then
    step "Verify the final artefacts (the app from the zip and from the DMG)"
    check_artifacts "$ZIP" "$DMG" "$IDENTITY" "$TEAM_ID" "$([[ $NOTARIZE -eq 1 ]] && echo notarized || echo unnotarized)" || exit 1
    echo "Zip, DMG and their apps: signed by $IDENTITY (G2, team $TEAM_ID)$([[ $NOTARIZE -eq 1 ]] && echo ", notarized and stapled")."
fi

# 5. EdDSA signature (private key read from the login Keychain) and appcast ---------------------------
step "Sign the update and write the appcast"
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$ZIP")"
echo "$SIGNATURE"
"$SPARKLE_BIN/sign_update" --verify "$ZIP" "$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNATURE")" >/dev/null \
    || fail "the EdDSA signature does not verify"

PREVIOUS="$OUT/previous-appcast.xml"
if [[ $DRY -eq 1 ]]; then
    # Dry runs chain locally, so 0.9.0 then 0.9.1 produce one feed with both.
    cp "$ROOT/build/release/appcast.xml" "$PREVIOUS" 2>/dev/null || : > "$PREVIOUS"
else
    fetch_appcast "$APPCAST_URL" "$PREVIOUS" || exit 1
    check_build_newer "$BUILD_NUMBER" "$PREVIOUS" || exit 1
fi
if [[ -f "$NOTES" ]]; then
    NOTES_HTML="$(cat "$NOTES")"
else
    NOTES_HTML="<p>Dry-run build $VERSION.</p>"
fi

python3 -I - "$PREVIOUS" "$OUT/appcast.xml" "$VERSION" "$BUILD_NUMBER" "$DOWNLOAD_BASE/Fivebars-$VERSION.zip" \
    "$SIGNATURE" "$NOTES_HTML" <<'PY'
import re, sys
from email.utils import formatdate
prev, out, version, build, url, signature, notes = sys.argv[1:]
sig = re.search(r'sparkle:edSignature="([^"]+)"', signature).group(1)
length = re.search(r'length="(\d+)"', signature).group(1)
if "]]>" in notes:
    sys.exit("release notes must not contain ]]>")
item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
    </item>
"""
text = open(prev).read()
if "<channel>" not in text:
    text = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Fivebars</title>
    <link>https://callingcodes.com/fivebars</link>
    <description>Fivebars updates</description>
    <language>en</language>
  </channel>
</rss>
"""
# Re-running a version replaces its item; the newest item goes first.
text = re.sub(r"[ \t]*<item>(?:(?!</item>).)*?<sparkle:shortVersionString>"
              + re.escape(version) + r"</sparkle:shortVersionString>.*?</item>\n?", "", text, flags=re.S)
anchor = re.search(r"[ \t]*<item>", text) or re.search(r"[ \t]*</channel>", text)
text = text[:anchor.start()] + item + text[anchor.start():]
open(out, "w").write(text)
PY
rm -f "$PREVIOUS"
xmllint --noout "$OUT/appcast.xml"

PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"version":"%s","build":%s,"dmg":"Fivebars-%s.dmg","zip":"Fivebars-%s.zip","published":"%s"}\n' \
    "$VERSION" "$BUILD_NUMBER" "$VERSION" "$VERSION" "$PUBLISHED" > "$OUT/latest.json"
[[ $DRY -eq 1 ]] && cp "$OUT/appcast.xml" "$ROOT/build/release/appcast.xml"

# 6. Upload to R2: the archives first, the appcast and latest.json last ------------------------------
if [[ $PUBLISH -eq 1 ]]; then
    publish_release new
else
    step "Upload commands (not run; pass --publish to run them, in this order)"
    printf '  %s\n' "${UPLOADS[@]}"
fi

# 7. Checklist ----------------------------------------------------------------------------------------
step "Fivebars $VERSION (build $BUILD_NUMBER) ready in $OUT"
ls -lh "$OUT" | sed 1d
cat <<CHECK

Checklist:
  [ ] Upgrade test: install the previous release, point it at the new feed, Check for Updates…, relaunch
  [ ] curl -sI $APPCAST_URL shows the new appcast; the archive URL answers 200
  [ ] https://callingcodes.com/fivebars/download/latest redirects to Fivebars-$VERSION.dmg
  [ ] git tag v$VERSION (local), and bump VERSION for the next release
CHECK
[[ $DRY -eq 1 ]] && echo "  (dry run: for local testing only, never publish these files)"
exit 0
