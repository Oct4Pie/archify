#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <archives-directory> <github-release-tag>" >&2
    echo "Example: $0 ./release-updates v1.5.0" >&2
    exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVES_DIR="$(cd "$1" && pwd)"
RELEASE_TAG="$2"
ACCOUNT="com.oct4pie.archify"
REPOSITORY="Oct4Pie/archify"
TOOLS_DERIVED_DATA="${ARCHIFY_SPARKLE_DERIVED_DATA:-$ROOT/.sparkle-tools}"

archive_found=0
for candidate in "$ARCHIVES_DIR"/*; do
    case "$candidate" in
        *.zip|*.dmg|*.tar|*.tar.gz|*.tar.bz2|*.tar.xz|*.aar)
            archive_found=1
            break
            ;;
    esac
done

if [[ "$archive_found" -ne 1 ]]; then
    echo "No Sparkle-compatible update archive found in: $ARCHIVES_DIR" >&2
    exit 65
fi

echo "Resolving Sparkle tools..."
resolve_args=(
    -resolvePackageDependencies
    -project "$ROOT/archify.xcodeproj"
    -scheme archify
    -derivedDataPath "$TOOLS_DERIVED_DATA"
)
xcodebuild "${resolve_args[@]}" >/dev/null

SPARKLE_BIN="$TOOLS_DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
GENERATE_KEYS="$SPARKLE_BIN/generate_keys"
SIGN_UPDATE="$SPARKLE_BIN/sign_update"

for tool in "$GENERATE_APPCAST" "$GENERATE_KEYS" "$SIGN_UPDATE"; do
    if [[ ! -x "$tool" ]]; then
        echo "Missing Sparkle tool: $tool" >&2
        exit 66
    fi
done

EXPECTED_PUBLIC_KEY="$(
    /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/archify/Info.plist"
)"
KEYCHAIN_PUBLIC_KEY="$(
    "$GENERATE_KEYS" --account "$ACCOUNT" -p
)"

if [[ "$EXPECTED_PUBLIC_KEY" != "$KEYCHAIN_PUBLIC_KEY" ]]; then
    echo "Sparkle Keychain key does not match archify/Info.plist." >&2
    echo "Expected: $EXPECTED_PUBLIC_KEY" >&2
    echo "Found:    $KEYCHAIN_PUBLIC_KEY" >&2
    exit 67
fi

cp "$ROOT/appcast.xml" "$ARCHIVES_DIR/appcast.xml"

DOWNLOAD_PREFIX="https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/"
RELEASE_LINK="https://github.com/$REPOSITORY/releases/tag/$RELEASE_TAG"

echo "Generating and signing appcast..."
appcast_args=(
    --account "$ACCOUNT"
    --download-url-prefix "$DOWNLOAD_PREFIX"
    --release-notes-url-prefix "$DOWNLOAD_PREFIX"
    --link "$RELEASE_LINK"
    --maximum-versions 0
    -o "$ARCHIVES_DIR/appcast.xml"
)
"$GENERATE_APPCAST" "${appcast_args[@]}" "$ARCHIVES_DIR"

"$SIGN_UPDATE" --account "$ACCOUNT" "$ARCHIVES_DIR/appcast.xml" >/dev/null
"$SIGN_UPDATE" --account "$ACCOUNT" --verify "$ARCHIVES_DIR/appcast.xml"

xmllint --noout "$ARCHIVES_DIR/appcast.xml"

if ! grep -q '<item>' "$ARCHIVES_DIR/appcast.xml"; then
    echo "Generated appcast contains no update item." >&2
    exit 68
fi

if ! grep -q 'sparkle:edSignature=' "$ARCHIVES_DIR/appcast.xml"; then
    echo "Generated appcast contains no EdDSA-signed update enclosure." >&2
    exit 69
fi

cp "$ARCHIVES_DIR/appcast.xml" "$ROOT/appcast.xml"

echo
echo "Appcast generated successfully."
echo "Feed: $ROOT/appcast.xml"
echo "Release downloads must be uploaded under:"
echo "  $DOWNLOAD_PREFIX"
