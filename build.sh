#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "PinTop must be built on macOS." >&2
  exit 1
fi

for tool in xcrun codesign plutil /usr/libexec/PlistBuddy; do
  if [[ "$tool" == /* ]]; then
    [[ -x "$tool" ]] || { echo "Missing required tool: $tool" >&2; exit 1; }
  elif ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    echo "Install Apple's Xcode Command Line Tools and try again." >&2
    exit 1
  fi
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/PinTop.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}"
ARCHITECTURE="${ARCH:-$(uname -m)}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.cognitivediscovery.pintop}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-pintop-notary}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

if [[ "$NOTARIZE" == "1" && ( "$SIGNING_IDENTITY" == "-" || "$SIGNING_IDENTITY" == "none" ) ]]; then
  cat >&2 <<'MSG'
NOTARIZE=1 requires signing with a Developer ID Application certificate, e.g.:
  SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARIZE=1 ./build.sh
Ad-hoc or unsigned builds cannot be notarized.
MSG
  exit 1
fi

case "$ARCHITECTURE" in
  arm64|x86_64) ;;
  *)
    echo "Unsupported architecture: $ARCHITECTURE" >&2
    exit 1
    ;;
esac

rm -rf "$ROOT/build"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_IDENTIFIER" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DEPLOYMENT_TARGET" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
xcrun --sdk macosx swiftc \
  -swift-version 5 \
  "$ROOT/Sources/main.swift" \
  -o "$MACOS/PinTop" \
  -target "$ARCHITECTURE-apple-macosx$DEPLOYMENT_TARGET" \
  -sdk "$SDK_PATH" \
  -O \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  -framework CoreVideo

if [[ "$SIGNING_IDENTITY" == "none" ]]; then
  : # Signing explicitly skipped.
elif [[ "$SIGNING_IDENTITY" == "-" ]]; then
  # Ad-hoc signature for local testing. This app has no nested executable content, so
  # --deep is intentionally not used.
  codesign --force --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  # Real identities get the hardened runtime and a secure timestamp; notarization requires
  # both. PinTop needs no hardened-runtime exception entitlements.
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  ZIP="$ROOT/build/PinTop.zip"

  # One-time setup for the credentials this uses (see README):
  #   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  #     --apple-id you@example.com --team-id TEAMID --password app-specific-password
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  # Staple the notarization ticket to the app, then rebuild the zip so the distributable
  # carries the ticket (users can then launch it offline without a Gatekeeper block).
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP"
  printf '\nNotarized, stapled, and assessed.\nDistributable: %s\n' "$ZIP"
fi

printf '\nBuilt: %s\n' "$APP"
printf 'Run:   open %q\n' "$APP"
printf 'Target: macOS %s, %s\n' "$DEPLOYMENT_TARGET" "$ARCHITECTURE"
printf 'Bundle: %s\n' "$BUNDLE_IDENTIFIER"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  cat <<'NOTE'

Note: this build uses an ad-hoc signature. Rebuilding changes its code identity,
so macOS may ask you to grant Accessibility permission again. For a stable
identity, build with SIGNING_IDENTITY set to an Apple Development or Developer
ID Application certificate name.
NOTE
fi
