#!/usr/bin/env bash
# Builds, notarizes and publishes a Postmere release: a drag-to-install disk
# image for new users and a Sparkle update for existing ones.
#
#   script/release.sh 1.1.0
#
# Needs: a Developer ID certificate, a notarytool keychain profile
# (NOTARY_PROFILE, default "postmere-notary"), the Sparkle private key in the
# login keychain (account "postmere"), and the GitHub CLI signed in.
# The private key is never read into this repository.
set -euo pipefail

version="${1:?Usage: script/release.sh <version, e.g. 1.1.0>}"
[[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Version must look like 1.2 or 1.2.3" >&2; exit 2; }
notary_profile="${NOTARY_PROFILE:-postmere-notary}"
repo="Mujhtech/postmere"
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/release-$version"
packages="$root/build/SourcePackages"
# Build numbers only ever grow, so Sparkle can compare them.
build_number="$(git -C "$root" rev-list --count HEAD)"

if [[ -n "$(git -C "$root" status --porcelain -- postmere appcast.xml)" ]]; then
    echo "Commit or stash app changes before releasing." >&2
    exit 1
fi

rm -rf "$build" && mkdir -p "$build/updates"
echo "› Archiving $version ($build_number)"
xcodebuild -project "$root/postmere/postmere.xcodeproj" -scheme postmere -configuration Release \
    -archivePath "$build/Postmere.xcarchive" -clonedSourcePackagesDirPath "$packages" \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" archive -quiet

echo "› Exporting with Developer ID"
# Push notifications need a Developer ID provisioning profile; let Xcode
# create or refresh it with the account signed in under Xcode › Settings.
xcodebuild -exportArchive -allowProvisioningUpdates -archivePath "$build/Postmere.xcarchive" \
    -exportOptionsPlist "$root/script/ExportOptions.plist" -exportPath "$build/export" -quiet
app="$build/export/Postmere.app"
archive="$build/updates/Postmere-$version.zip"

echo "› Notarizing"
ditto -c -k --keepParent "$app" "$build/notarize.zip"
xcrun notarytool submit "$build/notarize.zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"

# The disk image is what people download; the zip above is Sparkle's update.
echo "› Building the installer disk image"
dmg="$build/Postmere-$version.dmg"
"$root/script/make_dmg.sh" "$app" "$dmg"
identity="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application: .*\(6JR3ZGLPD6\)/ {print $2; exit}')"
[[ -n $identity ]] || { echo "No Developer ID Application certificate for team 6JR3ZGLPD6." >&2; exit 1; }
codesign --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"

echo "› Updating appcast.xml"
sparkle="$packages/artifacts/sparkle/Sparkle/bin"
cp "$root/appcast.xml" "$build/updates/appcast.xml"
"$sparkle/generate_appcast" --account postmere \
    --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
    --link "https://github.com/$repo" "$build/updates"
cp "$build/updates/appcast.xml" "$root/appcast.xml"

echo "› Publishing GitHub release v$version"
gh release create "v$version" "$dmg" "$archive" --repo "$repo" --title "Postmere $version" --generate-notes

cat <<DONE

Released Postmere $version. Commit and push appcast.xml to publish the update:
  git add appcast.xml && git commit -m "release: Postmere $version" && git push
DONE
