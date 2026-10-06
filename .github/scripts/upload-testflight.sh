#!/bin/bash
set -euo pipefail
umask 077
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for name in APP_STORE_CONNECT_API_ISSUER_ID APP_STORE_CONNECT_API_KEY_ID APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64 APP_STORE_PROVISIONING_PROFILE_BASE64 APP_STORE_WATCH_PROVISIONING_PROFILE_BASE64 APPLE_DISTRIBUTION_CERTIFICATE_BASE64 APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD BUILD_NUMBER MARKETING_VERSION; do
    if [[ -z "${!name:-}" ]]; then
        echo "Required environment variable $name is not configured." >&2
        exit 1
    fi
done
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "BUILD_NUMBER must be a positive integer." >&2
    exit 1
fi
if [[ ! "$APP_STORE_CONNECT_API_KEY_ID" =~ ^[[:alnum:]]+$ ]]; then
    echo "APP_STORE_CONNECT_API_KEY_ID must contain only letters and numbers." >&2
    exit 1
fi
bash "$SCRIPT_DIR/validate-release-source.sh"
python3 "$SCRIPT_DIR/require-release-ci.py"
readonly TEMP_ROOT="$(mktemp -d "${RUNNER_TEMP:-/tmp}/shopping-testflight.XXXXXX")"
readonly KEYCHAIN_PATH="$TEMP_ROOT/shopping-signing.keychain-db"
readonly KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
readonly PROFILES_DIRECTORY="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
readonly ARCHIVE_PATH="$TEMP_ROOT/Shopping.xcarchive"
readonly EXPORT_PATH="$TEMP_ROOT/export"
readonly API_PRIVATE_KEYS_DIRECTORY="$TEMP_ROOT/private_keys"
INSTALLED_PROFILES=()
ORIGINAL_KEYCHAINS=()
SEARCH_LIST_CHANGED=false
cleanup() {
    local exit_code=$?
    trap - EXIT
    set +e
    python3 "$SCRIPT_DIR/release-evidence.py" collect "$ARCHIVE_PATH" "$exit_code"
    local evidence_exit=$?

    if [[ "$SEARCH_LIST_CHANGED" == true ]]; then
        security list-keychains -d user -s ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"} >/dev/null 2>&1 || true
    fi
    for installed in ${INSTALLED_PROFILES[@]+"${INSTALLED_PROFILES[@]}"}; do rm -f "$installed"; done
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    rm -rf "$TEMP_ROOT"
    if [[ "$exit_code" -eq 0 && "$evidence_exit" -ne 0 ]]; then exit "$evidence_exit"; fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export RELEASE_EVIDENCE_DIR="${RELEASE_EVIDENCE_DIR:-$(mktemp -d "${RUNNER_TEMP:-/tmp}/shopping-release-evidence.XXXXXX")}"
python3 "$SCRIPT_DIR/release-evidence.py" init
echo "Release evidence: $RELEASE_EVIDENCE_DIR"
security list-keychains -d user > "$TEMP_ROOT/original-keychains.txt"
while IFS= read -r keychain; do
    keychain="${keychain#*\"}"; keychain="${keychain%\"*}"
    [[ -z "$keychain" ]] || ORIGINAL_KEYCHAINS+=("$keychain")
done < "$TEMP_ROOT/original-keychains.txt"
mkdir -p "$API_PRIVATE_KEYS_DIRECTORY" "$PROFILES_DIRECTORY"
printf '%s' "$APPLE_DISTRIBUTION_CERTIFICATE_BASE64" | base64 --decode > "$TEMP_ROOT/distribution.p12"
printf '%s' "$APP_STORE_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$TEMP_ROOT/iphone.mobileprovision"
printf '%s' "$APP_STORE_WATCH_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$TEMP_ROOT/watch.mobileprovision"
printf '%s' "$APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64" | base64 --decode > "$API_PRIVATE_KEYS_DIRECTORY/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
for target in iphone watch; do
    security cms -D -i "$TEMP_ROOT/$target.mobileprovision" > "$TEMP_ROOT/$target.plist"
done
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$TEMP_ROOT/distribution.p12" -k "$KEYCHAIN_PATH" -P "$APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security -t agg -f pkcs12 >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security find-identity -v -p codesigning "$KEYCHAIN_PATH" > "$TEMP_ROOT/identities.txt"
python3 "$SCRIPT_DIR/validate-release-profiles.py" --iphone "$TEMP_ROOT/iphone.plist" --watch "$TEMP_ROOT/watch.plist" --identities "$TEMP_ROOT/identities.txt" --output "$TEMP_ROOT"
readonly IPHONE_PROFILE_UUID="$(cat "$TEMP_ROOT/iphone.uuid")"
readonly WATCH_PROFILE_UUID="$(cat "$TEMP_ROOT/watch.uuid")"
readonly SIGNING_CERTIFICATE="$(cat "$TEMP_ROOT/certificate.sha1")"
for target in iphone watch; do
    uuid="$(cat "$TEMP_ROOT/$target.uuid")"
    installed="$PROFILES_DIRECTORY/$uuid.mobileprovision"
    if [[ -e "$installed" ]]; then
        cmp -s "$TEMP_ROOT/$target.mobileprovision" "$installed" || { echo "Refusing to replace an existing provisioning profile." >&2; exit 1; }
    else
        # Register before copying so cleanup also handles partial installation.
        INSTALLED_PROFILES+=("$installed")
        cp "$TEMP_ROOT/$target.mobileprovision" "$installed"
    fi
done
SEARCH_LIST_CHANGED=true
security list-keychains -d user -s "$KEYCHAIN_PATH" ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}
python3 "$SCRIPT_DIR/release-evidence.py" run archive "$TEMP_ROOT/archive.log" xcodebuild archive -project Shopping.xcodeproj -scheme Shopping -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE_PATH" -derivedDataPath "$TEMP_ROOT/DerivedData" \
    DEVELOPMENT_TEAM=649367BDD4 CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_CERTIFICATE" \
    SHOPPING_IPHONE_PROFILE_UUID="$IPHONE_PROFILE_UUID" SHOPPING_WATCH_PROFILE_UUID="$WATCH_PROFILE_UUID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
python3 "$SCRIPT_DIR/release-evidence.py" run export "$TEMP_ROOT/export.log" xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" -exportOptionsPlist "$TEMP_ROOT/ExportOptions.plist"
shopt -s nullglob
ipa_paths=("$EXPORT_PATH"/*.ipa)
shopt -u nullglob
[[ "${#ipa_paths[@]}" -eq 1 ]] || { echo "Expected exactly one exported IPA." >&2; exit 1; }
readonly IPA_PATH="${ipa_paths[0]}"
python3 "$SCRIPT_DIR/validate-cloudkit-sharing.py" --ipa "$IPA_PATH"
python3 "$SCRIPT_DIR/validate-release-identity.py" --ipa "$IPA_PATH" --version "$MARKETING_VERSION" --build "$BUILD_NUMBER" --commit "$(git rev-parse HEAD)"
export API_PRIVATE_KEYS_DIR="$API_PRIVATE_KEYS_DIRECTORY"
python3 "$SCRIPT_DIR/release-evidence.py" run validation "$TEMP_ROOT/validation.log" xcrun altool --validate-app --file "$IPA_PATH" --type ios --apiKey "$APP_STORE_CONNECT_API_KEY_ID" --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"
# Serialization cannot reserve a number against uploads from other clients.
# Repeat the GET-only check immediately before the one permitted upload.
RELEASE_MODE=upload ruby "$SCRIPT_DIR/preflight-testflight.rb"
python3 "$SCRIPT_DIR/release-evidence.py" run upload "$TEMP_ROOT/upload.log" xcrun altool --upload-app --file "$IPA_PATH" --type ios --apiKey "$APP_STORE_CONNECT_API_KEY_ID" --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"
