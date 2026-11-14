#!/bin/bash
# Runs CloudStorageTests against a cloud service built the way Dropbox,
# Google Drive, OneDrive and Proton Drive are on macOS: a File Provider
# extension (scripts/cloud-mock), signed with this Mac's Developer ID. Its
# "server" is a folder on this Mac; nothing goes over the network. One
# domain per service, laid out like that service's folder, appears in
# ~/Library/CloudStorage and the Finder sidebar while the tests run, with
# files that are only in the cloud, as macOS keeps them: their size, no
# blocks, and the dataless flag. The extension logs every request for a
# file's content, and the tests check that MyMole makes none.
# Everything is removed afterwards, pass or fail.
# Usage: scripts/cloud-tests.sh [up|test|down]   (all three without an argument)
set -euo pipefail

fail() { printf '%s\n' "$*" >&2; exit 1; }
repo=$(cd "$(dirname "$0")/.." && pwd -P)
build="$repo/.build/cloud-mock"
app="$build/MyMoleCloudMock.app"
appex="$app/Contents/PlugIns/MyMoleCloudProvider.appex"
host="$app/Contents/MacOS/MyMoleCloudMock"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# The services, as domain identifier and the name macOS gives its folder.
domains=("dropbox Dropbox" "google GoogleDrive" "onedrive OneDrive" "proton ProtonDrive")

team=$(security find-identity -v -p codesigning | sed -nE 's/.*"Developer ID Application: .*\(([A-Z0-9]{10})\)".*/\1/p' | head -1)
[ -n "$team" ] || fail "A Developer ID Application identity is needed to sign the extension."
group="$team.local.mymole.cloudmock"

plist() {  # path, bundle id, executable, package type, extra keys
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundleName</key><string>$3</string>
  <key>CFBundlePackageType</key><string>$4</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>MyMoleCloudGroup</key><string>$group</string>
  $5
</dict></plist>
EOF
}

entitlements() {  # path, sandboxed
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.application-groups</key><array><string>$group</string></array>
  $( [ "$2" = yes ] && echo '<key>com.apple.security.app-sandbox</key><true/>' )
</dict></plist>
EOF
}

make_app() {
  [ ! -d "$app" ] || rm -rf "$app"
  mkdir -p "$appex/Contents/MacOS" "$app/Contents/MacOS"
  swiftc -O -swift-version 5 -parse-as-library -module-name MyMoleCloudProvider \
    -Xlinker -e -Xlinker _NSExtensionMain -framework FileProvider \
    -o "$appex/Contents/MacOS/MyMoleCloudProvider" "$repo/scripts/cloud-mock/Provider/Provider.swift"
  swiftc -O -swift-version 5 -module-name MyMoleCloudMock -framework FileProvider \
    -o "$host" "$repo/scripts/cloud-mock/Host/main.swift"
  plist "$appex/Contents/Info.plist" local.mymole.cloudmock.provider MyMoleCloudProvider XPC! '
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.fileprovider-nonui</string>
    <key>NSExtensionPrincipalClass</key><string>MyMoleCloudProvider</string>
    <key>NSExtensionFileProviderDocumentGroup</key><string>'"$group"'</string>
    <key>NSExtensionFileProviderSupportsEnumeration</key><true/>
  </dict>'
  plist "$app/Contents/Info.plist" local.mymole.cloudmock MyMoleCloudMock APPL '<key>LSUIElement</key><true/>'
  entitlements "$build/provider.entitlements" yes
  entitlements "$build/host.entitlements" no
  codesign --force --options runtime --sign "Developer ID Application: " --entitlements "$build/provider.entitlements" "$appex"
  codesign --force --options runtime --sign "Developer ID Application: " --entitlements "$build/host.entitlements" "$app"
}

# One folder per service, laid out as that service lays out its own.
seed_folders() {
  local seed="$build/seed"
  [ ! -d "$seed" ] || rm -rf "$seed"
  for d in "${domains[@]}"; do
    local id=${d%% *} root="$seed/${d%% *}"
    case "$id" in
      google) root="$root/My Drive"; mkdir -p "$seed/google/Shared drives/Team/Reports" "$seed/google/.shortcut-targets-by-id/1AbC/Shared folder"
              head -c 200000 /dev/urandom > "$seed/google/Shared drives/Team/Reports/q3.pdf"
              head -c 150000 /dev/urandom > "$seed/google/.shortcut-targets-by-id/1AbC/Shared folder/linked.bin" ;;
      onedrive) mkdir -p "$root/Documents" "$root/Desktop" ;;
    esac
    mkdir -p "$root/Copies" "$root/Photos" "$root/Code/app/node_modules/left-pad" "$root/Code/app/.git" "$root/Installers"
    head -c 400000 /dev/urandom > "$root/Copies/one.bin"
    cp "$root/Copies/one.bin" "$root/Copies/two.bin"
    cp "$root/Copies/one.bin" "$root/Copies/three-cloud-only.bin"
    head -c 400000 /dev/urandom > "$root/Copies/other.bin"
    for i in 1 2 3; do
      sips -s format png -z 256 256 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns \
        --out "$root/Photos/photo-$i.png" >/dev/null
    done
    printf '{"name":"app","version":"1.0.0","dependencies":{"left-pad":"1.3.0"}}' > "$root/Code/app/package.json"
    printf 'ref: refs/heads/main\n' > "$root/Code/app/.git/HEAD"
    printf '{"name":"left-pad"}' > "$root/Code/app/node_modules/left-pad/package.json"
    head -c 300000 /dev/urandom > "$root/Code/app/node_modules/left-pad/index.js"
    head -c 500000 /dev/urandom > "$root/Installers/Tool-1.0.dmg"
    head -c 500000 /dev/urandom > "$root/Installers/Tool-1.0.pkg"
    # Apps kept in the cloud folder: one to run, one that installs macOS.
    for app in "Apps/Tool.app:com.example.cloudtool:Tool" "Installers/Install macOS Test.app:com.apple.InstallAssistant.Test:Install macOS Test"; do
      local bundle="$root/${app%%:*}" rest=${app#*:}
      mkdir -p "$bundle/Contents/MacOS"
      plutil -create xml1 "$bundle/Contents/Info.plist"
      plutil -insert CFBundleIdentifier -string "${rest%%:*}" "$bundle/Contents/Info.plist"
      plutil -insert CFBundleName -string "${rest#*:}" "$bundle/Contents/Info.plist"
      plutil -insert CFBundleExecutable -string tool "$bundle/Contents/Info.plist"
      head -c 200000 /dev/urandom > "$bundle/Contents/MacOS/tool"
    done
  done
}

folder_of() { "$host" path "$1"; }

up() {
  make_app
  "$lsregister" -f -R "$app"
  pluginkit -a "$appex"
  seed_folders
  "$host" remove-all
  for d in "${domains[@]}"; do
    "$host" seed "${d%% *}" "$build/seed/${d%% *}"
    "$host" add "${d%% *}" "${d#* }"
  done
  # Every file starts out only in the cloud. A few are downloaded, as a
  # user would have opened them: both Copies but the third, and the photos.
  for d in "${domains[@]}"; do
    local id=${d%% *} root
    root=$(folder_of "$id")
    [ "$id" != google ] || root="$root/My Drive"
    for _ in $(seq 1 40); do [ -e "$root/Copies/one.bin" ] && break; sleep 0.5; ls "$root" "$root/Copies" >/dev/null 2>&1 || true; done
    # A new File Provider runs only once it's switched on in System Settings.
    [ -e "$root/Copies/one.bin" ] || fail "macOS isn't running the test cloud. Switch on MyMoleCloudMock in System Settings → General → Login Items & Extensions → Extensions → MyMoleCloudMock (i) → File Provider, then run this again."
    cat "$root/Copies/one.bin" "$root/Copies/two.bin" "$root/Copies/other.bin" "$root"/Photos/*.png >/dev/null
  done
  "$host" clear-log
}

run() {
  local env=()
  for d in "${domains[@]}"; do
    local id=${d%% *}
    env+=("MYMOLE_CLOUD_$(printf '%s' "$id" | tr '[:lower:]' '[:upper:]')=$(folder_of "$id")")
  done
  (cd "$repo" && env "${env[@]}" MYMOLE_CLOUD_HOST="$host" swift test --filter 'CloudStorageTests|CloudStorageModelTests')
}

down() {
  set +e
  [ ! -x "$host" ] || "$host" remove-all
  [ ! -d "$appex" ] || pluginkit -r "$appex"
  [ ! -d "$app" ] || "$lsregister" -u "$app"
  [ ! -d "$build" ] || rm -rf "$build"
}

case "${1:-all}" in
  up) up ;;
  test) run ;;
  down) down ;;
  all) trap down EXIT; up; run ;;
  *) fail "Usage: scripts/cloud-tests.sh [up|test|down]" ;;
esac
