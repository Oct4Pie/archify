#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="${ARCHIFY_DEBUG_TEAM_ID:-9827C97648}"
DERIVED_DATA="${ARCHIFY_DEBUG_DERIVED_DATA:-$(getconf DARWIN_USER_TEMP_DIR)archify-privileged-debug}"

find_identity() {
    local kind="$1"
    security find-identity -v -p codesigning 2>/dev/null |
        awk -v kind="$kind" -v team="($TEAM_ID)" '
            index($0, kind) && index($0, team) {
                gsub(/[()]/, "", $2)
                print $2
                exit
            }
        '
}

IDENTITY="${ARCHIFY_DEBUG_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(find_identity "Apple Development:")"
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(find_identity "Developer ID Application:")"
fi

if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<EOF
No Apple code-signing identity was found for Team ID $TEAM_ID.

For a free Personal Team:
  1. Sign in to Xcode with your Apple Account.
  2. Create an Apple Development certificate.
  3. Re-run with ARCHIFY_DEBUG_TEAM_ID=<your-team-id>.

Developer ID also works for local testing when a matching certificate exists.
Ordinary Archify Debug builds remain ad hoc and do not need an Apple account.
EOF
    exit 66
fi

CLIENT_REQUIREMENT="anchor apple generic and identifier \"com.oct4pie.archify\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
HELPER_REQUIREMENT="anchor apple generic and identifier \"com.oct4pie.archifyhelper\" and certificate leaf[subject.OU] = \"$TEAM_ID\""

rm -rf "$DERIVED_DATA"

echo "Building privileged-helper Debug configuration for team $TEAM_ID..."
build_args=(
    -project "$ROOT/archify.xcodeproj"
    -scheme archify
    -configuration Debug
    -derivedDataPath "$DERIVED_DATA"
    -destination "platform=macOS,arch=$(uname -m)"
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$IDENTITY"
    DEVELOPMENT_TEAM="$TEAM_ID"
    ARCHIFY_CLIENT_CODE_REQUIREMENT="$CLIENT_REQUIREMENT"
    ARCHIFY_HELPER_CODE_REQUIREMENT="$HELPER_REQUIREMENT"
)
xcodebuild "${build_args[@]}" build

APP="$DERIVED_DATA/Build/Products/Debug/archify.app"
HELPER="$APP/Contents/Library/LaunchServices/com.oct4pie.archifyhelper"

codesign --verify --deep --strict "$APP"
codesign --verify --strict -R="$CLIENT_REQUIREMENT" "$APP"
codesign --verify --strict -R="$HELPER_REQUIREMENT" "$HELPER"

APP_TEAM="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
HELPER_TEAM="$(codesign -dv --verbose=4 "$HELPER" 2>&1 | sed -n 's/^TeamIdentifier=//p')"

if [[ "$APP_TEAM" != "$TEAM_ID" || "$HELPER_TEAM" != "$TEAM_ID" ]]; then
    echo "Built code does not carry the requested Team ID." >&2
    echo "App:    $APP_TEAM" >&2
    echo "Helper: $HELPER_TEAM" >&2
    exit 67
fi

echo
echo "Privileged-helper Debug build verified:"
echo "  $APP"
echo
echo "Open this build to test SMAppService/helper registration."
echo "macOS may require administrator approval in System Settings."
