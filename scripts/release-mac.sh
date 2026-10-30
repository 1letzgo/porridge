#!/bin/zsh
# Builds the Mac app for release, signs it, zips it and publishes it as a GitHub release.
#
#   scripts/release-mac.sh            # release the version from project.yml
#   scripts/release-mac.sh --bump     # first raise CURRENT_PROJECT_VERSION by one (and regenerate the project)
#   scripts/release-mac.sh --dry-run  # build and zip only, no GitHub release
#
# Tag: mac-v<MARKETING_VERSION>, asset: Porridge-mac-<version>.zip. A tag that exists already stops the
# script: bump the version in project.yml (or pass --bump for the build number) before releasing again.
#
# Signing: Developer ID + notarization when a "Developer ID Application" certificate is in the keychain,
# otherwise Apple Development (the app then needs right-click → Open on a Mac it was downloaded to).

set -euo pipefail
cd "$(dirname "$0")/.."

REPO=${PORRIDGE_REPO:-1letzgo/porridge}
SCHEME=PorridgeMac
DERIVED=build/Release-DerivedData
OUT=build/release
BUMP=0
DRY=0
for arg in "$@"; do
  case $arg in
    --bump) BUMP=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if (( BUMP )); then
  current=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9]*\).*/\1/p' project.yml | head -1)
  next=$((current + 1))
  sed -i '' "s/^\( *CURRENT_PROJECT_VERSION:\) *$current/\1 $next/" project.yml
  echo "CURRENT_PROJECT_VERSION: $current → $next"
  xcodegen generate >/dev/null
fi

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *\([^ ]*\).*/\1/p' project.yml | head -1)
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *\([0-9]*\).*/\1/p' project.yml | head -1)
TAG="mac-v$VERSION"
ASSET="Porridge-mac-$VERSION.zip"

if (( ! DRY )) && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG exists already on $REPO. Raise MARKETING_VERSION in project.yml first." >&2
  exit 1
fi

if [[ -n $(git status --porcelain) ]]; then
  echo "Working tree not clean; commit first so the tag points at what was built." >&2
  git status --short >&2
  exit 1
fi

DEVELOPER_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
if [[ -n $DEVELOPER_ID ]]; then
  SIGN_ARGS=(CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual)
  echo "Signing with: $DEVELOPER_ID"
else
  SIGN_ARGS=()
  echo "No Developer ID certificate: signing with Apple Development (right-click → Open on other Macs)."
fi

echo "Building $SCHEME $VERSION ($BUILD) …"
rm -rf "$DERIVED/Build/Products/Release"
xcodebuild -scheme "$SCHEME" -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" "${SIGN_ARGS[@]}" build 2>&1 \
  | grep -E '^\*\* BUILD|^/.* error:' || true
APP="$DERIVED/Build/Products/Release/Porridge.app"
[[ -d $APP ]] || { echo "Build failed: $APP missing" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

mkdir -p "$OUT"
rm -f "$OUT/$ASSET"
ditto -c -k --keepParent "$APP" "$OUT/$ASSET"

if [[ -n $DEVELOPER_ID ]]; then
  # Needs a keychain profile: xcrun notarytool store-credentials porridge-notary
  echo "Notarizing …"
  xcrun notarytool submit "$OUT/$ASSET" --keychain-profile porridge-notary --wait
  xcrun stapler staple "$APP"
  rm -f "$OUT/$ASSET"
  ditto -c -k --keepParent "$APP" "$OUT/$ASSET"
fi

shasum -a 256 "$OUT/$ASSET"
ls -la "$OUT/$ASSET"

if (( DRY )); then
  echo "Dry run: not released."
  exit 0
fi

git tag -a "$TAG" -m "Porridge Mac $VERSION ($BUILD)"
git push origin HEAD "$TAG"
# Notes go inline and the asset is uploaded in a second step: creating the release with a notes file and
# the asset in one call answered HTTP 500 from GitHub (seen with 0.3.0).
NOTES="Porridge for Mac $VERSION (build $BUILD), signed with ${DEVELOPER_ID:-Apple Development}."
if [[ -z $DEVELOPER_ID ]]; then
  NOTES+=$'\n\n'"Not notarized: after downloading, right-click Porridge.app and choose Open the first time."
fi
NOTES+=$'\n\n'"SHA-256: $(shasum -a 256 "$OUT/$ASSET" | cut -d' ' -f1)"
if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release create "$TAG" --repo "$REPO" --title "Porridge Mac $VERSION" --notes "$NOTES"
fi
gh release upload "$TAG" "$OUT/$ASSET" --repo "$REPO" --clobber
gh release view "$TAG" --repo "$REPO" --json url --jq .url
