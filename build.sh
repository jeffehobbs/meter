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
#   ./build.sh testflight Archive Meter Flow → App Store IPA in dist/ios/,
#                         and upload it if App Store Connect credentials are found
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
# Only `testflight` reads this: an explicit build number, overriding project.yml.
BUILD_ARG="${2:-}"

# Find an app-specific password without it having to be in the environment.
#
# These cannot be recovered from Apple: appleid.apple.com shows the password once,
# at creation, and never again. Other apps' stored items are probed too, because
# an app-specific password is **per Apple ID rather than per app** — the one made
# for Thrum works here unchanged, which is why `thrum-asc` is in the list.
#
#   xcrun altool --store-password-in-keychain-item --item meter-asc \
#     -u you@example.com -p abcd-efgh-ijkl-mnop
#
# `--item` is required and altool's own usage line omits it — without it the
# command fails with "Expected item argument is missing, --item", which reads like
# the flag is wrong rather than incomplete.
resolve_asc_password() {
  if [[ -n "${ASC_APP_PASSWORD:-}" ]]; then
    echo "$ASC_APP_PASSWORD"
    return 0
  fi
  local candidates=(meter-asc meterflow-asc thrum-asc thrumflow-asc phonotropic-asc mutiny-asc)
  for item in "${candidates[@]}"; do
    if security find-generic-password -l "$item" >/dev/null 2>&1 \
       || security find-generic-password -s "$item" >/dev/null 2>&1; then
      echo "@keychain:$item"
      return 0
    fi
  done
  return 1
}

# Meter Flow, to TestFlight.
#
# Handled before the macOS build below and exits, because none of that applies:
# no universal binary (iOS is arm64 only), no Developer ID, no notarization. App
# Store builds are signed by Apple's own pipeline after upload, so what leaves
# here is an unnotarized IPA and that is correct.
#
# One build covers iPhone and iPad — TARGETED_DEVICE_FAMILY is "1,2", so there is
# no second target and no second upload.
#
# **This needs an app record in App Store Connect first.** `altool` cannot create
# one; it has to exist before a build can be attached to it, and the bundle ID
# (com.jeffhobbs.meterflow) has to match exactly. Without it, validation fails
# and the IPA is still on disk, which is the right place to stop.
#
# Credentials are deliberately not stored here. Either shape works:
#
#   App-specific password (what the other iOS apps on this machine use). From
#   appleid.apple.com → Sign-In and Security → App-Specific Passwords, NOT from
#   App Store Connect:
#     ASC_APPLE_ID      your Apple ID email
#     ASC_APP_PASSWORD  abcd-efgh-ijkl-mnop     (or store it, see above)
#
#   Or an API key:
#     ASC_KEY_ID        the key's ID
#     ASC_ISSUER_ID     the issuer UUID from the Keys page
#   with the .p8 in ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
#
# The build number can be overridden: `./build.sh testflight 42`. App Store
# Connect rejects a number it has already seen, and rejects it *after* the upload
# and a processing wait, which is a slow way to find out.
# `./build.sh testflight $(date +%s)` sidesteps the question entirely.
if [[ "$MODE" == "testflight" ]]; then
  ARCHIVE="build-ios/MeterFlow.xcarchive"
  EXPORT_DIR="dist/ios"
  mkdir -p "$EXPORT_DIR" build-ios

  BUILD_ARGS=()
  if [[ -n "$BUILD_ARG" ]]; then
    BUILD_ARGS=(CURRENT_PROJECT_VERSION="$BUILD_ARG")
    echo "▸ Build number overridden: $BUILD_ARG"
  fi

  echo "▸ Archiving Meter Flow…"
  # -allowProvisioningUpdates creates or downloads the App Store distribution
  # profile, and is also what enables HealthKit on the App ID — the same
  # mechanism the `device` path above relies on.
  xcodebuild -project Meter.xcodeproj -scheme MeterFlow -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates -quiet \
    "${BUILD_ARGS[@]}" \
    archive

  # Read the version from the *archive*, not from Sources/iOS/Info.plist.
  # XcodeGen writes `$(MARKETING_VERSION)` in there as a literal and Xcode
  # resolves it at build time, so reading it beforehand yields the token rather
  # than a number. Same lesson as the macOS side naming its zip from the built
  # bundle: the artifact is the only source of truth for what a build calls itself.
  ARCHIVED_PLIST="$ARCHIVE/Products/Applications/MeterFlow.app/Info.plist"
  VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ARCHIVED_PLIST")
  BUILD_NO=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ARCHIVED_PLIST")
  echo "▸ Archived $VER ($BUILD_NO)"

  # `app-store-connect` is the current name; it was `app-store` before Xcode
  # 15.3 and the old value now warns.
  cat > build-ios/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>YKF353373Y</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

  echo "▸ Exporting IPA…"
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist build-ios/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" -allowProvisioningUpdates -quiet

  RAW_IPA=$(ls "$EXPORT_DIR"/MeterFlow.ipa 2>/dev/null | head -1)
  [[ -n "$RAW_IPA" ]] || { echo "✗ No IPA produced." >&2; exit 1; }

  # Re-read the build number from the *exported* IPA, because export can change
  # it: Xcode asks App Store Connect what it has already seen and silently bumps
  # past it, so the archive's number and the uploaded one need not agree.
  EXPORTED_BUILD_NO=$(unzip -p "$RAW_IPA" 'Payload/MeterFlow.app/Info.plist' 2>/dev/null \
    | plutil -extract CFBundleVersion raw -o - - 2>/dev/null) || true
  if [[ -n "$EXPORTED_BUILD_NO" && "$EXPORTED_BUILD_NO" != "$BUILD_NO" ]]; then
    echo "▸ Export bumped the build number: $BUILD_NO → $EXPORTED_BUILD_NO (App Store Connect had already seen $BUILD_NO)."
    BUILD_NO="$EXPORTED_BUILD_NO"
  fi
  # Versioned filename, matching the macOS convention — an unversioned artifact
  # is how you upload yesterday's build.
  IPA="$EXPORT_DIR/MeterFlow-$VER-$BUILD_NO.ipa"
  mv -f "$RAW_IPA" "$IPA"
  echo "▸ Exported: $IPA"

  # Two credential shapes, one upload. Validate first in both cases: it catches
  # the whole ITMS-9xxxx family — a missing privacy-manifest declaration, an icon
  # with an alpha channel, an entitlement the profile cannot carry, a missing app
  # record — in about a minute, against finding out by email a quarter of an hour
  # after uploading.
  AUTH=()
  ASC_APPLE_ID="${ASC_APPLE_ID:-}"
  ASC_PW="$(resolve_asc_password || true)"
  if [[ -n "$ASC_APPLE_ID" && -n "$ASC_PW" ]]; then
    AUTH=(-u "$ASC_APPLE_ID" -p "$ASC_PW")
    if [[ "$ASC_PW" == @keychain:* ]]; then
      echo "▸ Using the app-specific password in the keychain (${ASC_PW#@keychain:}) for $ASC_APPLE_ID."
    else
      echo "▸ Using the app-specific password from the environment for $ASC_APPLE_ID."
    fi
  elif [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
    AUTH=(--apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID")
    echo "▸ Using the App Store Connect API key $ASC_KEY_ID."
  fi

  if (( ${#AUTH[@]} )); then
    echo "▸ Validating…"
    if xcrun altool --validate-app -f "$IPA" -t ios "${AUTH[@]}"; then
      if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
        echo "▸ Validated. Not uploading (VALIDATE_ONLY=1)."
      else
        echo "▸ Uploading to App Store Connect…"
        xcrun altool --upload-app -f "$IPA" -t ios "${AUTH[@]}"
        echo "▸ Uploaded. Processing takes a few minutes before it appears in"
        echo "  TestFlight; Apple emails when it finishes. Testers are added there,"
        echo "  not here."
      fi
    else
      echo "✗ Validation failed — not uploading. The IPA is still at $IPA." >&2
      echo "  If it says the app cannot be found, the App Store Connect record" >&2
      echo "  does not exist yet: create it at appstoreconnect.apple.com with" >&2
      echo "  bundle ID com.jeffhobbs.meterflow, then run this again." >&2
      exit 1
    fi
  else
    echo "▸ Not uploading — no credentials found."
    if [[ -z "$ASC_APPLE_ID" ]]; then
      echo "  Missing ASC_APPLE_ID (your Apple ID email):  export ASC_APPLE_ID=\"you@example.com\""
    fi
    if [[ -z "$ASC_PW" ]]; then
      echo "  Missing the app-specific password. Make one at appleid.apple.com →"
      echo "  Sign-In and Security → App-Specific Passwords (it is shown once), then:"
      echo "    xcrun altool --store-password-in-keychain-item --item meter-asc \\"
      echo "      -u \"\$ASC_APPLE_ID\" -p abcd-efgh-ijkl-mnop"
      echo "  after which this script finds it by itself, forever."
    fi
    echo "  Or upload the IPA on disk by hand:"
    echo "    xcrun altool --upload-app -f \"$IPA\" -t ios -u <apple-id> -p @keychain:thrum-asc"
  fi
  echo
  echo "  Next upload needs a build number App Store Connect has not seen: bump"
  echo "  CURRENT_PROJECT_VERSION in project.yml, or run"
  echo "    ./build.sh testflight \$(date +%s)"
  exit 0
fi

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
