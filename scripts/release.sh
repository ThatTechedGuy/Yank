#!/bin/bash
# Builds the Release version of Yank and checks it.
#
# Usage: scripts/release.sh               Build, check, then install to /Applications/Yank.app.
#        scripts/release.sh --no-install  Build and check only; the app stays in build/.
#        scripts/release.sh --dmg         Build a copy signed with the "Yank Self-Signed"
#                                         certificate, check it and write build/Yank-<version>.dmg
#                                         and build/appcast.xml, the two files a GitHub release ships.
#                                         Sparkle's key comes from the login keychain, or from the
#                                         file $SPARKLE_KEY_FILE names (the release workflow).
#
# build/Yank.xcarchive holds the latest build and its dSYM. An install also copies it to
# build/Installed.xcarchive, the only symbols that can read crash reports from the installed app.
# The installed Yank must not be running during an install; "Yank Debug" is a separate app.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=${1:-}
archive=build/Yank.xcarchive
app=$archive/Products/Applications/Yank.app
binary=$app/Contents/MacOS/Yank

# A release for other people is always signed with the maintainer's self-signed certificate, whatever
# Signing.local.xcconfig says. Its signature stays the same from release to release, so macOS keeps
# the Accessibility permission across updates and Sparkle accepts the next version. An ad hoc
# signature changes on every build; a personal Apple Development certificate carries its owner's
# Apple ID and expires within a year. Creating the certificate: README, "Cutting a release".
identity="Yank Self-Signed"
signing=()
[[ "$mode" == "--dmg" ]] && signing=("CODE_SIGN_IDENTITY=$identity" "DEVELOPMENT_TEAM=" "CODE_SIGN_STYLE=Manual")

xcodegen --quiet
rm -rf "$archive"
xcodebuild archive -scheme Yank -destination 'generic/platform=macOS' \
    -derivedDataPath build/release -archivePath "$archive" -quiet ${signing[@]+"${signing[@]}"}

# Xcode re-signs Sparkle.framework but not the helpers inside it, which ship ad hoc signed. Sparkle
# wants them signed like the app (its "Code Signing" docs); innermost first, then the framework
# and the app, whose signatures cover them.
if [[ "$mode" == "--dmg" ]]; then
    sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
    for helper in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
        codesign -f -s "$identity" -o runtime --preserve-metadata=entitlements "$sparkle/$helper"
    done
    codesign -f -s "$identity" -o runtime "$app/Contents/Frameworks/Sparkle.framework"
    codesign -f -s "$identity" -o runtime --preserve-metadata=entitlements "$app"
    for code in "$app" "$app/Contents/Frameworks/Sparkle.framework" "$sparkle"/XPCServices/*.xpc \
        "$sparkle/Autoupdate" "$sparkle/Updater.app"; do
        codesign --verify -R="certificate leaf[subject.CN] = \"$identity\"" "$code" ||
            { echo "Not signed by $identity: $code"; exit 1; }
    done
fi

# Each check stops the script if it fails.
codesign --verify --deep --strict "$app"
# Read into a variable first: `grep -q` on a pipe exits early and pipefail then fails codesign.
signature=$(codesign -dv "$app" 2>&1)
[[ "$signature" == *"flags="*"runtime"* ]] || { echo "Hardened runtime is off."; exit 1; }
# Exactly the entitlements in App/Resources/Yank.entitlements: no get-task-allow, nothing extra.
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p - | grep '=>' | sort)
expected='    0 => "com.apple.universalaccessAuthWarn"
    1 => "com.thattechedguy.Yank-spks"
    2 => "com.thattechedguy.Yank-spki"
  "com.apple.security.app-sandbox" => true
  "com.apple.security.cs.disable-library-validation" => true
  "com.apple.security.files.user-selected.read-only" => true
  "com.apple.security.network.client" => true
  "com.apple.security.temporary-exception.mach-lookup.global-name" => ['
[[ "$entitlements" == "$expected" ]] || { echo "Unexpected entitlements:"; echo "$entitlements"; exit 1; }
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$bundle_id" == com.thattechedguy.Yank ]] || { echo "Unexpected bundle id: $bundle_id"; exit 1; }
[[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "Not an arm64-only binary."; exit 1; }
# None of the `#if DEBUG` code (the Developer window, --seed) made it in.
debug=$(strings "$binary" | grep -c -E 'StoreInspector|Open Data Folder|--seed' || true)
[[ "$debug" == 0 ]] || { echo "Debug-only code found in the Release binary."; exit 1; }
echo "Checks passed: $(du -sh "$app" | cut -f1) app, arm64, signed, hardened runtime, sandboxed."

[[ "$mode" == "--no-install" ]] && exit 0

if [[ "$mode" == "--dmg" ]]; then
    version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
    dmg=build/Yank-$version.dmg
    # The disk image opens to Yank and a link to Applications, so it gets dragged there rather
    # than run from Downloads, where macOS runs it from a read-only copy Sparkle cannot replace.
    staging=build/dmg
    rm -rf "$staging" "$dmg"
    mkdir -p "$staging"
    ditto "$app" "$staging/Yank.app"
    ln -s /Applications "$staging/Applications"
    hdiutil create -volname Yank -srcfolder "$staging" -format UDZO -quiet "$dmg"
    rm -rf "$staging"
    # The copy inside the image is what users get: check its signature survived.
    mount=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mount" "$dmg"
    codesign --verify --deep --strict "$mount/Yank.app" ||
        { hdiutil detach -quiet "$mount"; echo "The app in $dmg fails its signature check."; exit 1; }
    hdiutil detach -quiet "$mount"
    echo "Wrote $dmg"
    shasum -a 256 "$dmg"

    # The feed Sparkle reads (SUFeedURL in App/Resources/Info.plist is the latest release's copy).
    # Sparkle offers an update only when its CFBundleVersion is higher than the installed one's.
    # sign_update signs the image with the EdDSA key and prints the enclosure's signature and
    # length attributes.
    build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
    min_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
    key_file=()
    [[ -n "${SPARKLE_KEY_FILE:-}" ]] && key_file=(--ed-key-file "$SPARKLE_KEY_FILE")
    signed=$(build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update \
        ${key_file[@]+"${key_file[@]}"} "$dmg")
    cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Yank</title>
    <item>
      <title>Yank $version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build_number</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$min_os</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/ThatTechedGuy/Yank/releases/download/v$version/Yank-$version.dmg"
        $signed type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF
    echo "Wrote build/appcast.xml for Yank $version (build $build_number)"
    exit 0
fi

# `pgrep -f` matches the executable's path, so a running "Yank Debug" doesn't count.
if pgrep -f '^/Applications/Yank.app/Contents/MacOS/Yank' > /dev/null; then
    echo "Yank is running. Quit it from its menu bar icon (Quit Yank), then run this again."
    exit 1
fi
# The old copy goes first so no stale file survives.
rm -rf /Applications/Yank.app
ditto "$app" /Applications/Yank.app
rm -rf build/Installed.xcarchive
ditto "$archive" build/Installed.xcarchive
echo "Installed /Applications/Yank.app (not opened). Its symbols: build/Installed.xcarchive."
