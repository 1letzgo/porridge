#!/bin/zsh
# Builds the Android app (sideload flavor, signed), runs the unit tests and publishes the APK as a GitHub release.
#
#   scripts/release-android.sh            # release the version from project.yml
#   scripts/release-android.sh --dry-run  # build, test and copy the APK only, no GitHub release
#
# Tag: android-v<MARKETING_VERSION>, asset: Porridge-android-<version>.apk. The app's update check
# (android/.../data/AppUpdate.kt) reads these releases. A tag that exists already stops the script: raise
# MARKETING_VERSION in project.yml first. versionCode is the commit count, so it grows with every commit.
#
# Signing: ~/Library/Application Support/porridge-signing/keystore.properties. Never change that key, or
# installed apps refuse the update.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO=${PORRIDGE_REPO:-1letzgo/porridge}
OUT=build/release
DRY=0
for arg in "$@"; do
  case $arg in
    --dry-run) DRY=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}
export ANDROID_HOME=${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *\([^ ]*\).*/\1/p' project.yml | head -1)
CODE=$(git rev-list --count HEAD)
TAG="android-v$VERSION"
ASSET="Porridge-android-$VERSION.apk"

if [[ ! -f "$HOME/Library/Application Support/porridge-signing/keystore.properties" ]]; then
  echo "Signing key missing: ~/Library/Application Support/porridge-signing/keystore.properties" >&2
  exit 1
fi

if (( ! DRY )) && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release $TAG exists already on $REPO. Raise MARKETING_VERSION in project.yml first." >&2
  exit 1
fi

if [[ -n $(git status --porcelain) ]]; then
  echo "Working tree not clean; commit first so the tag points at what was built." >&2
  git status --short >&2
  exit 1
fi

echo "Building Porridge Android $VERSION ($CODE) …"
(cd android && ./gradlew --quiet testSideloadDebugUnitTest assembleSideloadRelease) 2>&1 \
  | grep -vE '^w: |^warning:' || true

BUILD_DIR=$(cd android && ./gradlew -q :app:properties 2>/dev/null | sed -n 's/^buildDir: //p')
APK_DIR="$BUILD_DIR/outputs/apk/sideload/release"
APK=$(ls -t "$APK_DIR"/*.apk 2>/dev/null | head -1 || true)
[[ -n $APK ]] || { echo "Build failed: no APK in $APK_DIR" >&2; exit 1; }
[[ $APK != *-unsigned.apk ]] || { echo "APK is unsigned: $APK" >&2; exit 1; }

mkdir -p "$OUT"
cp "$APK" "$OUT/$ASSET"
SHA=$(shasum -a 256 "$OUT/$ASSET" | cut -d' ' -f1)
echo "$SHA  $OUT/$ASSET"
ls -la "$OUT/$ASSET"

if (( DRY )); then
  echo "Dry run: not released."
  exit 0
fi

git tag -a "$TAG" -m "Porridge Android $VERSION ($CODE)"
git push origin HEAD "$TAG"

NOTES_FILE=$(mktemp)
{
  echo "Porridge for Android $VERSION (versionCode $CODE)."
  echo
  echo "Install: open the APK on the phone and allow installing apps from this source. Later versions arrive through the update check in the app."
  echo
  echo "SHA-256: $SHA"
} > "$NOTES_FILE"

gh release create "$TAG" "$OUT/$ASSET" --repo "$REPO" --title "Porridge Android $VERSION" --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"

REMOTE=$(gh release view "$TAG" --repo "$REPO" --json assets --jq ".assets[] | select(.name == \"$ASSET\") | .digest" | sed 's/^sha256://')
if [[ $REMOTE != "$SHA" ]]; then
  echo "Uploaded digest $REMOTE does not match local $SHA" >&2
  exit 1
fi
gh release view "$TAG" --repo "$REPO" --json url --jq .url
