#!/bin/zsh
# Builds the Mac app for TestFlight: sandboxed, without the GitHub updater, signed for App Store Connect.
# The GitHub build (scripts/release-mac.sh) stays as it is.
#
#   scripts/testflight-mac.sh            # archive, export and validate with Apple
#   scripts/testflight-mac.sh --upload   # the same, then upload
#
# Version: MARKETING_VERSION from project.yml, build number: git rev-list --count HEAD.
# Needs the App Store Connect API key in ~/.appstoreconnect/private_keys.

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME=PorridgeMac
OUT=build/testflight
KEY_ID=${ASC_KEY_ID:-P42ZP4TS87}
ISSUER=${ASC_ISSUER:-818f36ae-6711-4f80-a313-49156330b12c}
KEY_FILE=$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8
UPLOAD=0
for arg in "$@"; do
  case $arg in
    --upload) UPLOAD=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[[ -f $KEY_FILE ]] || { echo "API key missing: $KEY_FILE" >&2; exit 1 }
if [[ $UPLOAD == 1 && -n $(git status --porcelain) ]]; then
  echo "Working tree is not clean: commit first, the upload must match a commit." >&2
  exit 1
fi

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml | head -1 | tr -d '"')
BUILD=$(git rev-list --count HEAD)
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$KEY_FILE" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

rm -rf "$OUT"
mkdir -p "$OUT"
echo "Building $SCHEME $VERSION ($BUILD) for TestFlight …"
xcodegen generate --quiet
xcodebuild -project Porridge.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$OUT/$SCHEME.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD" CODE_SIGN_ENTITLEMENTS=PorridgeMac/PorridgeMacBeta.entitlements \
  ENABLE_APP_SANDBOX=YES DISTRIBUTION_CONDITIONS=TESTFLIGHT \
  "${AUTH[@]}" archive -quiet

cat > "$OUT/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>699G2QY959</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/$SCHEME.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" "${AUTH[@]}" -quiet

PKG=$OUT/export/Porridge.pkg
xcrun altool --validate-app -f "$PKG" -t osx --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
if [[ $UPLOAD == 1 ]]; then
  xcrun altool --upload-app -f "$PKG" -t osx --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
fi
ls -l "$PKG"
