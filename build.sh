#!/bin/zsh
# Build Meter.
#   ./build.sh            Debug build (macOS)
#   ./build.sh run        Debug build, then launch
#   ./build.sh release    Release build, Developer ID signed
#   ./build.sh notarize   …then notarized, stapled and zipped into dist/
#
# Notarizing needs a stored credential profile (Apple ID + app-specific
# password). The credential is per Apple ID rather than per app, so a profile
# stored for another of these apps works here; the script uses the first that
# authenticates. Set NOTARY_PROFILE=… to force one.
#
#   xcrun notarytool store-credentials meter-notary \
#     --apple-id "you@example.com" --team-id YKF353373Y \
#     --password "<app-specific-password>"
#   ./build.sh ios        Build Meter Flow for the simulator
#   ./build.sh ios-run    …and install and launch it on the booted one
#   ./build.sh device     Build, sign and install Meter Flow on the iPhone
#   ./build.sh log        Pull the marked moments off the iPhone and show them
#
# `device` signs with automatic provisioning and -allowProvisioningUpdates, which
# is also what registers the App ID and turns on the capabilities the entitlements
# file asks for — HealthKit, here. HealthKit is a free capability, so unlike a
# reviewed one (CarPlay, say) this needs no approval; if it were not enabled, the
# failure would read "Entitlement com.apple.developer.healthkit not found and
# could not be included in profile", which sounds like a typo and is not.
#
# The two apps share Sources/Shared verbatim; Sources/Mac and Sources/iOS are
# the parts that cannot be shared.
set -e
cd "$(dirname "$0")"

xcodegen generate

# ./build.sh log — fetch what the triple taps wrote.
#
# `--domain-type appDataContainer` needs a development build, which an install
# from here always is.
if [[ "${1:-}" == log ]]; then
  DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ {print $3; exit}')}"
  OUT="${2:-dist/moments.log}"
  mkdir -p "$(dirname "$OUT")"
  rm -f "$OUT"
  if xcrun devicectl list devices 2>/dev/null | grep -i iphone | grep -q unavailable; then
    echo "▸ Device unavailable — restarting CoreDevice…"
    killall -9 remotepairingd remotepaireddevice CoreDeviceService coredeviced 2>/dev/null || true
    sleep 6
  fi
  xcrun devicectl device copy from --device "$DEVICE" \
    --domain-type appDataContainer --domain-identifier com.jeffhobbs.meterflow \
    --source "Library/Application Support/Meter/moments.log" \
    --destination "$OUT" >/dev/null
  echo
  cat "$OUT"
  exit 0
fi

if [[ "${1:-}" == device ]]; then
  DEVICE="${DEVICE:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ {print $3; exit}')}"
  [[ -n "$DEVICE" ]] || { echo "No iPhone paired — plug it in or pair it over Wi-Fi."; exit 1; }
  # A wedged CoreDevice tunnel reports the phone as unavailable even when it is
  # sitting unlocked on the desk; restarting the daemons clears it.
  if xcrun devicectl list devices 2>/dev/null | grep -i iphone | grep -q unavailable; then
    echo "▸ Device unavailable — restarting CoreDevice…"
    killall -9 remotepairingd remotepaireddevice CoreDeviceService coredeviced 2>/dev/null || true
    sleep 6
  fi

  echo "▸ Building Meter Flow for $DEVICE"
  xcodebuild -project Meter.xcodeproj -scheme MeterFlow -configuration Debug \
    -sdk iphoneos -destination "id=$DEVICE" -derivedDataPath build-device \
    -allowProvisioningUpdates build | \
    grep -E "error:|BUILD" || true

  APP="build-device/Build/Products/Debug-iphoneos/MeterFlow.app"
  [[ -d "$APP" ]] || { echo "Build failed: $APP not found"; exit 1; }

  echo "▸ Installing"
  xcrun devicectl device install app --device "$DEVICE" "$APP"
  echo
  echo "▸ Installed. Open Meter on the phone — the first run asks for Health and Motion."
  exit 0
fi

if [[ "${1:-}" == ios || "${1:-}" == ios-run ]]; then
  SIM=$(xcrun simctl list devices available | grep -m1 "iPhone" | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/')
  echo "▸ Building Meter Flow for simulator $SIM"
  xcodebuild -project Meter.xcodeproj -scheme MeterFlow -sdk iphonesimulator \
    -destination "id=$SIM" -derivedDataPath build-ios build | \
    grep -E "error:|BUILD" || true
  APP="build-ios/Build/Products/Debug-iphonesimulator/MeterFlow.app"
  [[ -d "$APP" ]] || { echo "Build failed: $APP not found"; exit 1; }
  echo "Built $APP"
  if [[ "${1:-}" == ios-run ]]; then
    xcrun simctl boot "$SIM" 2>/dev/null || true
    open -a Simulator
    xcrun simctl install "$SIM" "$APP"
    # METER_AUTOPLAY starts it without a tap, which is the only way to see a
    # simulator build actually running — there is no tap API. METER_TUNING opens
    # the pulse screen the same way.
    xcrun simctl launch --terminate-running-process "$SIM" com.jeffhobbs.meterflow
  fi
  exit 0
fi

CONFIG=Debug
MODE="${1:-debug}"
[[ "$MODE" == release || "$MODE" == notarize ]] && CONFIG=Release
DEV_ID="${DEV_ID:-Developer ID Application}"   # codesign matches this as a substring

# Anything shipped is built for both architectures, and that needs an explicit
# generic destination: left to itself xcodebuild resolves "My Mac" to the first
# matching destination, which pins arm64 and quietly overrides ARCHS — so
# ONLY_ACTIVE_ARCH=NO alone is not enough and the result is a single-slice
# binary that looks fine until an Intel Mac opens it.
DEST=()
[[ "$CONFIG" == Release ]] && DEST=(-destination 'generic/platform=macOS')

xcodebuild -project Meter.xcodeproj -scheme Meter -configuration "$CONFIG" \
  "${DEST[@]}" -derivedDataPath build CODE_SIGNING_ALLOWED=YES build | \
  grep -E "error:|BUILD" || true

APP="build/Build/Products/$CONFIG/Meter.app"
if [[ ! -d "$APP" ]]; then
  echo "Build failed: $APP not found"
  exit 1
fi
echo "Built $APP"

if [[ "$MODE" == run ]]; then
  killall Meter 2>/dev/null || true
  open "$APP"
  exit 0
fi
[[ "$MODE" == debug ]] && exit 0

# --- Developer ID signing -----------------------------------------------------
#
# Xcode has already signed the bundle for running here; this re-signs it with the
# Developer ID identity and the hardened runtime, which is what Gatekeeper on
# somebody else's Mac cares about. Meter embeds no frameworks or helpers, so one
# call covers the whole bundle.
echo "--- signing with \"$DEV_ID\" ---"
codesign --force --timestamp --options runtime --sign "$DEV_ID" "$APP"

echo "--- verifying ---"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|Runtime)" || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

if [[ "$MODE" == release ]]; then
  # An unnotarized Developer ID build fails `spctl` until it has been notarized.
  # Expected here, so report it rather than failing the build.
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 || \
    echo "  (not notarized yet — run ./build.sh notarize)"
  echo "Signed Meter $VERSION"
  exit 0
fi

# --- Notarize -----------------------------------------------------------------
resolve_notary_profile() {
  local candidates=(meter-notary thrum-notary echo-notary mutiny-notary)
  [[ -n "$NOTARY_PROFILE" ]] && candidates=("$NOTARY_PROFILE")
  local p
  for p in $candidates; do
    if xcrun notarytool history --keychain-profile "$p" >/dev/null 2>&1; then
      echo "$p"; return 0
    fi
  done
  echo "✗ No usable notarytool credential (tried: $candidates)." >&2
  return 1
}

PROFILE=$(resolve_notary_profile)
mkdir -p dist
ZIP="dist/Meter-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the bundle's symlinks and extended attributes; `zip` does not.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "--- notarizing $ZIP (profile: $PROFILE) ---"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "--- stapling ---"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Re-zip so the distributed archive carries the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarized and stapled: $ZIP"
