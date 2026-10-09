#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECT_NOTARIZED=0
APP=""

usage() {
    echo "Usage: $0 [--expect-notarized] <Archify.app>" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect-notarized)
            EXPECT_NOTARIZED=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            exit 64
            ;;
        *)
            if [[ -n "$APP" ]]; then
                usage
                exit 64
            fi
            APP="$1"
            shift
            ;;
    esac
done

if [[ -z "$APP" || ! -d "$APP" ]]; then
    usage
    exit 64
fi

APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
HELPER="$APP/Contents/Library/LaunchServices/com.oct4pie.archifyhelper"
DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/com.oct4pie.archify.helper.plist"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_BINARY="$SPARKLE_FRAMEWORK/Versions/B/Sparkle"
TEAM_ID="${ARCHIFY_RELEASE_TEAM_ID:-9827C97648}"

eval "$("$ROOT/scripts/project-version.py" --format shell)"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

[[ -x "$APP/Contents/MacOS/archify" ]] || fail "main executable missing"
[[ -x "$HELPER" ]] || fail "privileged helper missing"
[[ -f "$DAEMON_PLIST" ]] || fail "SMAppService daemon plist missing"
[[ -d "$SPARKLE_FRAMEWORK" ]] || fail "Sparkle framework missing"
[[ ! -e "$APP/Contents/Resources/ldid" ]] || fail "host-specific ldid is bundled"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" == "$ARCHIFY_VERSION" ]] || fail "marketing version mismatch"
[[ "$APP_BUILD" == "$ARCHIFY_BUILD" ]] || fail "build number mismatch"
pass "version $APP_VERSION ($APP_BUILD)"

for binary in "$APP/Contents/MacOS/archify" "$HELPER" "$SPARKLE_BINARY"; do
    slices="$(lipo -archs "$binary")"
    [[ "$slices" == *arm64* && "$slices" == *x86_64* ]] || fail "non-universal binary: $binary ($slices)"
done
pass "app, helper, and Sparkle are arm64+x86_64"

codesign --verify --deep --strict --all-architectures "$APP"
pass "deep code-signature verification"

APP_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
HELPER_DETAILS="$(codesign -dv --verbose=4 "$HELPER" 2>&1)"
APP_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$APP_DETAILS")"
HELPER_TEAM="$(sed -n 's/^TeamIdentifier=//p' <<<"$HELPER_DETAILS")"
[[ "$APP_TEAM" == "$TEAM_ID" ]] || fail "app Team ID is $APP_TEAM, expected $TEAM_ID"
[[ "$HELPER_TEAM" == "$TEAM_ID" ]] || fail "helper Team ID is $HELPER_TEAM, expected $TEAM_ID"
grep -q '^Authority=Developer ID Application:' <<<"$APP_DETAILS" || fail "app is not Developer ID Application signed"
grep -q '^Authority=Developer ID Application:' <<<"$HELPER_DETAILS" || fail "helper is not Developer ID Application signed"
grep -q 'runtime' <<<"$APP_DETAILS" || fail "app hardened runtime flag missing"
grep -q 'runtime' <<<"$HELPER_DETAILS" || fail "helper hardened runtime flag missing"
pass "Developer ID team and hardened runtime"

APP_HELPER_REQUIREMENT="$(/usr/libexec/PlistBuddy -c 'Print :SMPrivilegedExecutables:com.oct4pie.archifyhelper' "$APP/Contents/Info.plist")"
grep -q "$TEAM_ID" <<<"$APP_HELPER_REQUIREMENT" || fail "app helper requirement is not Team-ID-bound"
strings "$HELPER" | grep -F "certificate leaf[subject.OU] = \"$TEAM_ID\"" >/dev/null || fail "helper client requirement is not Team-ID-bound"
pass "mutual helper authentication requirements"

plutil -lint "$APP/Contents/Info.plist" "$DAEMON_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$DAEMON_PLIST" | grep -F 'Contents/Library/LaunchServices/com.oct4pie.archifyhelper' >/dev/null || fail "daemon BundleProgram is incorrect"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST")" == "com.oct4pie.archify.helper" ]] || fail "SMAppService daemon label must differ from the legacy SMJobBless label"
/usr/libexec/PlistBuddy -c 'Print :MachServices:com.oct4pie.archify.helper' "$DAEMON_PLIST" >/dev/null || fail "SMAppService daemon Mach service is incorrect"
/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers:0' "$DAEMON_PLIST" | grep -Fx 'com.oct4pie.archify' >/dev/null || fail "daemon is not associated with the Archify app in Login Items"
pass "SMAppService metadata"

FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")"
[[ "$FEED_URL" == "https://raw.githubusercontent.com/Oct4Pie/archify/main/appcast.xml" ]] || fail "unexpected Sparkle feed URL"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$APP/Contents/Info.plist")" == "true" ]] || fail "signed Sparkle feed is not required"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$APP/Contents/Info.plist")" == "true" ]] || fail "pre-extraction update verification is disabled"
pass "Sparkle security configuration"

if strings "$HELPER" | grep -q 'healthCheck'; then
    fail "Debug-only helper health-check surface leaked into Release"
fi
pass "Debug helper surface absent"

for arch in x86_64 arm64; do
    minos="$(xcrun vtool -arch "$arch" -show-build "$APP/Contents/MacOS/archify" | awk '/minos/{print $2; exit}')"
    [[ "$minos" == "12.0" ]] || fail "$arch minimum macOS is $minos"
done
pass "minimum macOS 12.0"

if [[ "$EXPECT_NOTARIZED" -eq 1 ]]; then
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
    pass "notarization and Gatekeeper"
else
    if spctl_output="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)"; then
        pass "Gatekeeper assessment already passes"
    else
        echo "INFO: Gatekeeper assessment does not pass yet:"
        printf '%s\n' "$spctl_output" | sed -n '1,5p'
    fi
fi

echo
echo "Qualification complete for:"
echo "  $APP"
