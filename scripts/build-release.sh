#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$ROOT/dist"
TEAM_ID="${ARCHIFY_RELEASE_TEAM_ID:-9827C97648}"
NOTARY_PROFILE="${ARCHIFY_NOTARY_PROFILE:-archify-notary}"
UNSIGNED=0
SKIP_NOTARIZATION=0
GENERATE_APPCAST=0
RELEASE_TAG=""

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --output DIR            Output directory (default: ./dist)
  --unsigned              Build an unsigned universal Release for CI validation
  --skip-notarization     Developer-ID sign, but do not submit to Apple
  --notary-profile NAME   notarytool Keychain profile
  --generate-appcast      Update appcast.xml from the final release archive
  --tag TAG               GitHub release tag (default: v<version>)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --unsigned)
            UNSIGNED=1
            SKIP_NOTARIZATION=1
            shift
            ;;
        --skip-notarization)
            SKIP_NOTARIZATION=1
            shift
            ;;
        --notary-profile)
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --generate-appcast)
            GENERATE_APPCAST=1
            shift
            ;;
        --tag)
            RELEASE_TAG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

eval "$("$ROOT/scripts/project-version.py" --format shell)"
if [[ -z "$RELEASE_TAG" ]]; then
    RELEASE_TAG="v$ARCHIFY_VERSION"
fi

if [[ "$GENERATE_APPCAST" -eq 1 && "$UNSIGNED" -eq 1 ]]; then
    echo "Cannot generate a production appcast from an unsigned build." >&2
    exit 65
fi

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/updates"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"

IDENTITY=""
if [[ "$UNSIGNED" -eq 0 ]]; then
    IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null |
            awk -v team="($TEAM_ID)" '
                index($0, "Developer ID Application:") && index($0, team) {
                    gsub(/[()]/, "", $2)
                    print $2
                    exit
                }
            '
    )"
    if [[ -z "$IDENTITY" ]]; then
        echo "No Developer ID Application identity found for Team ID $TEAM_ID." >&2
        exit 66
    fi
fi

echo "Building Archify $ARCHIFY_VERSION ($ARCHIFY_BUILD)..."
build_args=(
    -project "$ROOT/archify.xcodeproj"
    -scheme archify
    -configuration Release
    -derivedDataPath "$DERIVED_DATA"
    -destination "generic/platform=macOS"
    ARCHS="arm64 x86_64"
    ONLY_ACTIVE_ARCH=NO
    MACOSX_DEPLOYMENT_TARGET=12.0
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
)

if [[ "$UNSIGNED" -eq 1 ]]; then
    build_args+=(
        CODE_SIGNING_ALLOWED=NO
        CODE_SIGNING_REQUIRED=NO
        DEVELOPMENT_TEAM=
    )
else
    build_args+=(
        CODE_SIGN_STYLE=Manual
        CODE_SIGN_IDENTITY="$IDENTITY"
        DEVELOPMENT_TEAM="$TEAM_ID"
    )
fi

xcodebuild "${build_args[@]}" build

APP="$DERIVED_DATA/Build/Products/Release/archify.app"
HELPER="$APP/Contents/Library/LaunchServices/com.oct4pie.archifyhelper"
SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_BASE="$SPARKLE_FRAMEWORK/Versions/B"
SPARKLE_BINARY="$SPARKLE_BASE/Sparkle"
SPARKLE_UPDATER="$SPARKLE_BASE/Updater.app"
SPARKLE_AUTOUPDATE="$SPARKLE_BASE/Autoupdate"
SPARKLE_DOWNLOADER="$SPARKLE_BASE/XPCServices/Downloader.xpc"
SPARKLE_INSTALLER="$SPARKLE_BASE/XPCServices/Installer.xpc"

for path in \
    "$APP" \
    "$HELPER" \
    "$SPARKLE_FRAMEWORK" \
    "$SPARKLE_UPDATER" \
    "$SPARKLE_AUTOUPDATE" \
    "$SPARKLE_DOWNLOADER" \
    "$SPARKLE_INSTALLER"
do
    if [[ ! -e "$path" ]]; then
        echo "Missing release artifact: $path" >&2
        exit 67
    fi
done

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$APP_VERSION" != "$ARCHIFY_VERSION" || "$APP_BUILD" != "$ARCHIFY_BUILD" ]]; then
    echo "Built version does not match project version." >&2
    echo "Project: $ARCHIFY_VERSION ($ARCHIFY_BUILD)" >&2
    echo "Built:   $APP_VERSION ($APP_BUILD)" >&2
    exit 68
fi

for binary in "$APP/Contents/MacOS/archify" "$HELPER" "$SPARKLE_BINARY"; do
    slices="$(lipo -archs "$binary")"
    if [[ "$slices" != *arm64* || "$slices" != *x86_64* ]]; then
        echo "Universal architecture check failed for $binary: $slices" >&2
        exit 69
    fi
done

if [[ "$UNSIGNED" -eq 0 ]]; then
    sign_release_item() {
        local path="$1"
        codesign \
            --force \
            --sign "$IDENTITY" \
            --options runtime \
            --timestamp \
            --preserve-metadata=identifier,entitlements,requirements \
            "$path"
    }

    # Direct xcodebuild embeds Sparkle updater/XPC components with ad-hoc
    # signatures. Re-sign nested code inside-out with our Developer ID and a
    # secure timestamp, then seal the framework, helper, and parent app.
    sign_release_item "$SPARKLE_UPDATER"
    sign_release_item "$SPARKLE_AUTOUPDATE"
    sign_release_item "$SPARKLE_DOWNLOADER"
    sign_release_item "$SPARKLE_INSTALLER"
    sign_release_item "$SPARKLE_FRAMEWORK"
    sign_release_item "$HELPER"
    sign_release_item "$APP"

    codesign --verify --deep --strict --all-architectures "$APP"

    APP_TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    HELPER_TEAM="$(codesign -dv --verbose=4 "$HELPER" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [[ "$APP_TEAM" != "$TEAM_ID" || "$HELPER_TEAM" != "$TEAM_ID" ]]; then
        echo "Release Team ID mismatch." >&2
        echo "App: $APP_TEAM  Helper: $HELPER_TEAM  Expected: $TEAM_ID" >&2
        exit 70
    fi

    for signed_item in \
        "$APP" \
        "$HELPER" \
        "$SPARKLE_FRAMEWORK" \
        "$SPARKLE_UPDATER" \
        "$SPARKLE_AUTOUPDATE" \
        "$SPARKLE_DOWNLOADER" \
        "$SPARKLE_INSTALLER"
    do
        details="$(codesign -dv --verbose=4 "$signed_item" 2>&1)"
        grep -q '^Authority=Developer ID Application:' <<<"$details" || {
            echo "Missing Developer ID signature: $signed_item" >&2
            exit 71
        }
        grep -q '^Timestamp=' <<<"$details" || {
            echo "Missing secure timestamp: $signed_item" >&2
            exit 72
        }
    done

    for entitlement_target in "$APP" "$HELPER"; do
        if codesign -d --entitlements :- "$entitlement_target" 2>/dev/null \
            | grep -q 'com.apple.security.get-task-allow'
        then
            echo "Release artifact contains get-task-allow: $entitlement_target" >&2
            exit 73
        fi
    done
fi

ARCHIVE_NAME="Archify-$ARCHIFY_VERSION.zip"
SUBMISSION_ZIP="$OUTPUT_DIR/notarization-$ARCHIVE_NAME"
FINAL_ZIP="$OUTPUT_DIR/updates/$ARCHIVE_NAME"

/usr/bin/ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"

if [[ "$UNSIGNED" -eq 0 && "$SKIP_NOTARIZATION" -eq 0 ]]; then
    echo "Submitting to Apple notarization..."
    NOTARY_RESULT="$OUTPUT_DIR/notary-result.json"
    xcrun notarytool submit "$SUBMISSION_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json \
        > "$NOTARY_RESULT"
    NOTARY_STATUS="$(
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' \
            "$NOTARY_RESULT"
    )"
    NOTARY_ID="$(
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' \
            "$NOTARY_RESULT"
    )"
    if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
        echo "Notarization failed: $NOTARY_STATUS ($NOTARY_ID)" >&2
        xcrun notarytool log "$NOTARY_ID" \
            --keychain-profile "$NOTARY_PROFILE" \
            > "$OUTPUT_DIR/notary-log.json" 2>&1 || true
        cat "$OUTPUT_DIR/notary-log.json" >&2
        exit 74
    fi

    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
fi

rm -f "$FINAL_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$FINAL_ZIP"
shasum -a 256 "$FINAL_ZIP" > "$FINAL_ZIP.sha256"

if [[ "$GENERATE_APPCAST" -eq 1 ]]; then
    ARCHIFY_SPARKLE_DERIVED_DATA="$DERIVED_DATA" \
        "$ROOT/scripts/generate_appcast.sh" \
        "$OUTPUT_DIR/updates" \
        "$RELEASE_TAG"
fi

rm -f "$SUBMISSION_ZIP"

echo
echo "Release validation complete:"
echo "  Version: $ARCHIFY_VERSION ($ARCHIFY_BUILD)"
echo "  Archive: $FINAL_ZIP"
if [[ "$UNSIGNED" -eq 1 ]]; then
    echo "  Signing: unsigned CI validation"
elif [[ "$SKIP_NOTARIZATION" -eq 1 ]]; then
    echo "  Signing: Developer ID (notarization skipped)"
else
    echo "  Signing: Developer ID + notarized"
fi
