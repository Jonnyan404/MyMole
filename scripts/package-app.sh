#!/bin/bash
# Assemble MyMole.app from SwiftPM products for one architecture, then zip
# and wrap it into a disk image.
#
#   scripts/package-app.sh <bin-dir> <arch> <output-dir> [version]
#
# <bin-dir> is what `swift build -c release --triple <triple> --show-bin-path`
# prints. <arch> is arm64 or x86_64 and is only used for names and a sanity
# check: the architectures are the binaries' own, never relabelled.
#
# The bundle is signed ad hoc. It is not notarized, so a machine that downloads
# it sees Gatekeeper's first-run prompt; see the note printed at the end.
set -euo pipefail

BIN="${1:?bin dir}"
ARCH="${2:?arch: arm64 or x86_64}"
OUT="${3:?output dir}"
VERSION="${4:-1.0}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$OUT/MyMole.app"
PLIST_BUDDY=/usr/libexec/PlistBuddy
BUNDLE_ID="${MYMOLE_BUNDLE_ID:-app.mymole.MyMole.local}"

for product in MyMole MyMoleHelper; do
  [ -x "$BIN/$product" ] || { echo "missing product: $BIN/$product" >&2; exit 1; }
done

# A mislabelled build is worse than a failed one: an Intel binary called
# arm64 downloads fine and dies on launch.
actual="$(lipo -archs "$BIN/MyMole" | tr ' ' '\n' | sort | tr '\n' ' ')"
case " $actual " in
  *" $ARCH "*) ;;
  *) echo "MyMole is [$actual], expected $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$OUT"
if [ -e "$APP" ]; then
  mv "$APP" "$OUT/MyMole.app.previous.$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"

# The main executable and the privileged helper share one directory: the
# client looks for MyMoleHelper next to its own executable.
cp "$BIN/MyMole" "$APP/Contents/MacOS/MyMole"
cp "$BIN/MyMoleHelper" "$APP/Contents/MacOS/MyMoleHelper"
chmod +x "$APP/Contents/MacOS/MyMole" "$APP/Contents/MacOS/MyMoleHelper"

cp "$REPO/Icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [ -f "$REPO/LICENSE" ]; then
  cp "$REPO/LICENSE" "$APP/Contents/Resources/Licenses/MyMole-LICENSE.txt"
fi

# Nothing in the SwiftPM build compiles the string catalog, and String(localized:)
# resolves against Bundle.main: without .lproj folders in Resources every lookup
# falls back to the English key. Xcode's xcstringstool does this for an official
# build; here the same job is done by the script next to this one.
if [ -f "$REPO/Localization/Localizable.xcstrings" ]; then
  python3 "$REPO/scripts/compile-strings.py" \
    "$REPO/Localization/Localizable.xcstrings" "$APP/Contents/Resources"
fi

PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MyMole</string>
    <key>CFBundleDisplayName</key>
    <string>MyMole</string>
    <key>CFBundleExecutable</key>
    <string>MyMole</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST_EOF

# The languages the bundle ships are the .lproj folders that were just written,
# and macOS reads them from there. Don't also list them in CFBundleLocalizations:
# naming a language twice — as a folder and in that array — makes the bundle
# report every localization twice, which the Language picker in Settings lists.
shipped=$(cd "$APP/Contents/Resources" && ls -d *.lproj 2>/dev/null | sed 's/\.lproj$//' | tr '\n' ' ')
if [ -n "$shipped" ]; then
  echo "localizations: $shipped"
fi

# The privacy strings macOS shows in its permission prompts come from the
# repository's own plist, so there is one place to edit them.
if [ -f "$REPO/Config/MyMole-Info.plist" ]; then
  for key in NSAppleEventsUsageDescription NSAppBundlesUsageDescription NSAppDataUsageDescription; do
    value="$("$PLIST_BUDDY" -c "Print :$key" "$REPO/Config/MyMole-Info.plist" 2>/dev/null)" || continue
    "$PLIST_BUDDY" -c "Add :$key string \"$value\"" "$PLIST" 2>/dev/null \
      || "$PLIST_BUDDY" -c "Set :$key \"$value\"" "$PLIST"
  done
fi

# Ad hoc signing keeps the two executables' identities stable across launches;
# without it every start looks like a new program to TCC.
codesign --force --sign - "$APP/Contents/MacOS/MyMoleHelper"
codesign --force --sign - "$APP/Contents/MacOS/MyMole"
codesign --force --sign - "$APP"

plutil -lint "$PLIST" > /dev/null
codesign --verify --strict "$APP"

NAME="MyMole-$VERSION-macOS-$ARCH"
rm -f "$OUT/$NAME.zip" "$OUT/$NAME.dmg"
# ditto, not zip: it keeps the icon resource fork and the signature intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$NAME.zip"
hdiutil create -quiet -volname "MyMole" -srcfolder "$APP" -ov -format UDZO "$OUT/$NAME.dmg"

echo "built: $OUT/$NAME.zip"
echo "built: $OUT/$NAME.dmg"
echo "note: ad hoc signed and not notarized; first launch needs"
echo "      System Settings > Privacy & Security > Open Anyway."
