#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h:h}"
info_plist="$project_root/App/LumaProfileApp/Info.plist"
project_file="$project_root/App/LumaProfileApp.xcodeproj/project.pbxproj"
package_manifest="$project_root/Package.swift"
app_icon="$project_root/App/LumaProfileApp/AppIcon.icns"
expected_bundle_identifier="com.lumaprofile.app"

fail() {
  print -u2 -- "Release metadata check failed: $1"
  exit 2
}

for required_file in "$info_plist" "$project_file" "$package_manifest" "$app_icon"; do
  [[ -f "$required_file" && ! -L "$required_file" ]] || fail "missing or unsafe file: $required_file"
done

/usr/bin/plutil -lint "$info_plist" >/dev/null

bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
marketing_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
build_number="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_plist")"
minimum_system_version="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$info_plist")"
bundle_executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$info_plist")"
bundle_icon="$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$info_plist")"

[[ "$bundle_identifier" == "$expected_bundle_identifier" ]] \
  || fail "Info.plist bundle identifier is '$bundle_identifier', expected '$expected_bundle_identifier'."
[[ "$marketing_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || fail "Info.plist version must use numeric major.minor.patch form."
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] \
  || fail "Info.plist build number must be a positive integer."
[[ "$minimum_system_version" == "15.0" ]] \
  || fail "Info.plist minimum system version must remain 15.0."
[[ "$bundle_executable" == "LumaProfileApp" ]] \
  || fail "Info.plist executable must remain LumaProfileApp."
[[ "$bundle_icon" == "AppIcon.icns" ]] \
  || fail "Info.plist icon must remain AppIcon.icns."
[[ "$(/usr/bin/file -b "$app_icon")" == *"Mac OS X icon"* ]] \
  || fail "AppIcon.icns is not a valid macOS icon container."

project_icon_count="$(/usr/bin/grep -c 'INFOPLIST_KEY_CFBundleIconFile = AppIcon.icns;' "$project_file")"
[[ "$project_icon_count" == "2" ]] \
  || fail "the Xcode project must declare AppIcon.icns for both target configurations."

project_bundle_identifier_text="$(
  /usr/bin/sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = \([^;]*\);/\1/p' "$project_file"
)"
project_bundle_identifiers=("${(@f)project_bundle_identifier_text}")
(( ${#project_bundle_identifiers[@]} == 2 )) \
  || fail "the Xcode project must declare exactly two target bundle identifiers."
for identifier in "${project_bundle_identifiers[@]}"; do
  [[ "$identifier" == "$expected_bundle_identifier" ]] \
    || fail "Xcode bundle identifier is '$identifier', expected '$expected_bundle_identifier'."
done

project_version_text="$(
  /usr/bin/sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' "$project_file"
)"
project_versions=("${(@f)project_version_text}")
(( ${#project_versions[@]} == 2 )) \
  || fail "the Xcode project must declare exactly two marketing versions."
for version in "${project_versions[@]}"; do
  [[ "$version" == "$marketing_version" ]] \
    || fail "Xcode marketing version '$version' does not match Info.plist '$marketing_version'."
done

project_build_text="$(
  /usr/bin/sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$project_file"
)"
project_builds=("${(@f)project_build_text}")
(( ${#project_builds[@]} == 2 )) \
  || fail "the Xcode project must declare exactly two build numbers."
for project_build in "${project_builds[@]}"; do
  [[ "$project_build" == "$build_number" ]] \
    || fail "Xcode build number '$project_build' does not match Info.plist '$build_number'."
done

project_target_text="$(
  /usr/bin/sed -n 's/^[[:space:]]*MACOSX_DEPLOYMENT_TARGET = \([^;]*\);/\1/p' "$project_file"
)"
project_targets=("${(@f)project_target_text}")
(( ${#project_targets[@]} == 2 )) \
  || fail "the Xcode project must declare exactly two deployment targets."
for target in "${project_targets[@]}"; do
  [[ "$target" == "$minimum_system_version" ]] \
    || fail "Xcode deployment target '$target' does not match Info.plist '$minimum_system_version'."
done

/usr/bin/grep -Fq '.macOS(.v15)' "$package_manifest" \
  || fail "Package.swift must target macOS 15."

print -- "Release metadata is consistent: $bundle_identifier $marketing_version ($build_number), macOS $minimum_system_version."
