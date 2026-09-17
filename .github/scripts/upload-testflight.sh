#!/bin/bash

set -euo pipefail

readonly PROJECT="Shopping.xcodeproj"
readonly SCHEME="Shopping"
readonly CONFIGURATION="Release"
readonly BUNDLE_IDENTIFIER="com.mggarofalo.shopping"

require_environment_variable() {
    local variable_name="$1"

    if [[ -z "${!variable_name:-}" ]]; then
        echo "Required environment variable $variable_name is not configured." >&2
        exit 1
    fi
}

for variable_name in \
    APP_STORE_CONNECT_API_ISSUER_ID \
    APP_STORE_CONNECT_API_KEY_ID \
    APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64 \
    APP_STORE_PROVISIONING_PROFILE_BASE64 \
    APPLE_DISTRIBUTION_CERTIFICATE_BASE64 \
    APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD \
    BUILD_NUMBER; do
    require_environment_variable "$variable_name"
done

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "BUILD_NUMBER must be a positive integer." >&2
    exit 1
fi

if [[ ! "$APP_STORE_CONNECT_API_KEY_ID" =~ ^[[:alnum:]]+$ ]]; then
    echo "APP_STORE_CONNECT_API_KEY_ID must contain only letters and numbers." >&2
    exit 1
fi

readonly TEMP_ROOT="$(mktemp -d "${RUNNER_TEMP:-/tmp}/shopping-testflight.XXXXXX")"
readonly CERTIFICATE_PATH="$TEMP_ROOT/distribution.p12"
readonly PROFILE_PATH="$TEMP_ROOT/distribution.mobileprovision"
readonly PROFILE_PLIST_PATH="$TEMP_ROOT/distribution.plist"
readonly API_PRIVATE_KEYS_DIRECTORY="$TEMP_ROOT/private_keys"
readonly API_PRIVATE_KEY_PATH="$API_PRIVATE_KEYS_DIRECTORY/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
readonly KEYCHAIN_PATH="$TEMP_ROOT/shopping-signing.keychain-db"
readonly ARCHIVE_PATH="$TEMP_ROOT/Shopping.xcarchive"
readonly EXPORT_PATH="$TEMP_ROOT/export"
readonly EXPORT_OPTIONS_PATH="$TEMP_ROOT/ExportOptions.plist"
readonly KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"

INSTALLED_PROFILE_PATH=""

cleanup() {
    if [[ -n "$INSTALLED_PROFILE_PATH" ]]; then
        rm -f "$INSTALLED_PROFILE_PATH"
    fi

    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$API_PRIVATE_KEYS_DIRECTORY"
printf '%s' "$APPLE_DISTRIBUTION_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE_PATH"
printf '%s' "$APP_STORE_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"
printf '%s' "$APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64" | base64 --decode > "$API_PRIVATE_KEY_PATH"
chmod 600 "$CERTIFICATE_PATH" "$PROFILE_PATH" "$API_PRIVATE_KEY_PATH"

if ! security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST_PATH"; then
    echo "APP_STORE_PROVISIONING_PROFILE_BASE64 is not a valid provisioning profile." >&2
    exit 1
fi

profile_value() {
    /usr/libexec/PlistBuddy -c "Print $1" "$PROFILE_PLIST_PATH"
}

readonly PROFILE_NAME="$(profile_value :Name)"
readonly PROFILE_UUID="$(profile_value :UUID)"
readonly PROFILE_TEAM_ID="$(profile_value :TeamIdentifier:0)"
readonly PROFILE_APPLICATION_IDENTIFIER_PREFIX="$(profile_value :ApplicationIdentifierPrefix:0)"
readonly PROFILE_APPLICATION_IDENTIFIER="$(profile_value :Entitlements:application-identifier)"
readonly EXPECTED_APPLICATION_IDENTIFIER="$PROFILE_APPLICATION_IDENTIFIER_PREFIX.$BUNDLE_IDENTIFIER"

if [[ ! "$PROFILE_UUID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    echo "Provisioning profile contains an invalid UUID." >&2
    exit 1
fi

if [[ ! "$PROFILE_TEAM_ID" =~ ^[[:alnum:]]+$ ]]; then
    echo "Provisioning profile contains an invalid team identifier." >&2
    exit 1
fi

if [[ "$PROFILE_APPLICATION_IDENTIFIER" != "$EXPECTED_APPLICATION_IDENTIFIER" ]]; then
    echo "Provisioning profile is for $PROFILE_APPLICATION_IDENTIFIER; expected $EXPECTED_APPLICATION_IDENTIFIER." >&2
    exit 1
fi

if /usr/libexec/PlistBuddy -c "Print :ProvisionedDevices" "$PROFILE_PLIST_PATH" >/dev/null 2>&1; then
    echo "Provisioning profile contains registered devices; an App Store Connect profile is required." >&2
    exit 1
fi

if [[ "$(profile_value :ProvisionsAllDevices 2>/dev/null || true)" == "true" ]]; then
    echo "Provisioning profile permits all devices; an App Store Connect profile is required." >&2
    exit 1
fi

readonly PROFILES_DIRECTORY="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES_DIRECTORY"
INSTALLED_PROFILE_PATH="$PROFILES_DIRECTORY/$PROFILE_UUID.mobileprovision"
cp "$PROFILE_PATH" "$INSTALLED_PROFILE_PATH"
chmod 600 "$INSTALLED_PROFILE_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD" \
    -A \
    -t cert \
    -f pkcs12
security set-key-partition-list \
    -S apple-tool:,apple: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH"

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -F "$PROFILE_TEAM_ID"; then
    echo "The imported distribution identity does not match team $PROFILE_TEAM_ID." >&2
    exit 1
fi

/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PATH"
/usr/bin/plutil -insert method -string app-store-connect "$EXPORT_OPTIONS_PATH"
/usr/bin/plutil -insert destination -string export "$EXPORT_OPTIONS_PATH"
/usr/bin/plutil -insert signingStyle -string manual "$EXPORT_OPTIONS_PATH"
/usr/bin/plutil -insert signingCertificate -string "Apple Distribution" "$EXPORT_OPTIONS_PATH"
/usr/bin/plutil -insert teamID -string "$PROFILE_TEAM_ID" "$EXPORT_OPTIONS_PATH"
/usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool false "$EXPORT_OPTIONS_PATH"
/usr/bin/plutil -insert provisioningProfiles -xml '<dict/>' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy \
    -c "Add :provisioningProfiles:$BUNDLE_IDENTIFIER string '$PROFILE_NAME'" \
    "$EXPORT_OPTIONS_PATH"

xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$TEMP_ROOT/DerivedData" \
    DEVELOPMENT_TEAM="$PROFILE_TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

shopt -s nullglob
ipa_paths=("$EXPORT_PATH"/*.ipa)
shopt -u nullglob

if [[ "${#ipa_paths[@]}" -ne 1 ]]; then
    echo "Expected exactly one exported IPA, found ${#ipa_paths[@]}." >&2
    exit 1
fi

export API_PRIVATE_KEYS_DIR="$API_PRIVATE_KEYS_DIRECTORY"
readonly IPA_PATH="${ipa_paths[0]}"

xcrun altool --validate-app \
    --file "$IPA_PATH" \
    --type ios \
    --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"

xcrun altool --upload-app \
    --file "$IPA_PATH" \
    --type ios \
    --apiKey "$APP_STORE_CONNECT_API_KEY_ID" \
    --apiIssuer "$APP_STORE_CONNECT_API_ISSUER_ID"
