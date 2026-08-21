#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h}"
info_plist="$project_root/App/LumaProfileApp/Info.plist"
version="${LUMAPROFILE_VERSION:-$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")}"
build_number="${LUMAPROFILE_BUILD_NUMBER:-$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_plist")}"
output_directory="${LUMAPROFILE_OUTPUT_DIRECTORY:-$project_root/outputs}"
release_binary="${LUMAPROFILE_RELEASE_BINARY:-}"
release_metadata_file="${LUMAPROFILE_RELEASE_METADATA_FILE:-}"
argyll_version="3.5.0"
argyll_archive_directory="${LUMAPROFILE_ARGYLL_ARCHIVE_DIRECTORY:-$project_root/ThirdParty/ArgyllCMS/Artifacts}"
argyll_binary_name="Argyll_V${argyll_version}_macOS11_arm64_bin.tgz"
argyll_source_name="Argyll_V${argyll_version}_src.zip"
argyll_binary_archive="${argyll_archive_directory:A}/$argyll_binary_name"
argyll_source_archive="${argyll_archive_directory:A}/$argyll_source_name"
argyll_manifest="$project_root/ThirdParty/ArgyllCMS/SHA256SUMS"
required_argyll_tools=(spotread dispcal targen dispread colprof profcheck dispwin)
source_entries=(
  .github
  .gitignore
  AGENTS.md
  App
  CONTRIBUTING.md
  INSTALLING.txt
  LICENSE
  Package.swift
  PROJECT_STATE.md
  README.md
  Scripts
  SECURITY.md
  Sources
  Tests
  THIRD_PARTY_NOTICES.md
  docs
)

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 -- "LUMAPROFILE_VERSION must use numeric major.minor.patch form."
  exit 2
fi

if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 -- "LUMAPROFILE_BUILD_NUMBER must be a positive integer."
  exit 2
fi

"$script_directory/ci/check-release-metadata.sh"

if [[ -n "$release_metadata_file" ]]; then
  release_metadata_file="${release_metadata_file:A}"
  if [[ ! -f "$release_metadata_file" || -L "$release_metadata_file" ]]; then
    print -u2 -- "Release metadata is missing or unsafe: $release_metadata_file"
    exit 2
  fi
  /usr/bin/plutil -lint "$release_metadata_file" >/dev/null
  metadata_version="$(/usr/bin/plutil -extract Version raw -o - "$release_metadata_file")"
  metadata_build="$(/usr/bin/plutil -extract BuildNumber raw -o - "$release_metadata_file")"
  metadata_tag="$(/usr/bin/plutil -extract GitTag raw -o - "$release_metadata_file")"
  metadata_commit="$(/usr/bin/plutil -extract GitCommit raw -o - "$release_metadata_file")"
  metadata_bundle_identifier="$(/usr/bin/plutil -extract BundleIdentifier raw -o - "$release_metadata_file")"
  metadata_product="$(/usr/bin/plutil -extract Product raw -o - "$release_metadata_file")"
  metadata_release_kind="$(/usr/bin/plutil -extract ReleaseKind raw -o - "$release_metadata_file")"
  metadata_argyll_version="$(/usr/bin/plutil -extract ArgyllCMSVersion raw -o - "$release_metadata_file")"
  expected_bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$project_root/App/LumaProfileApp/Info.plist")"
  if [[ "$metadata_version" != "$version" \
    || "$metadata_build" != "$build_number" \
    || "$metadata_tag" != "v$version" \
    || "$metadata_bundle_identifier" != "$expected_bundle_identifier" \
    || "$metadata_product" != "LumaProfile" \
    || "$metadata_release_kind" != "portfolio-ad-hoc-non-notarized" \
    || "$metadata_argyll_version" != "$argyll_version" \
    || ! "$metadata_commit" =~ '^[0-9a-f]{40}$' ]]
  then
    print -u2 -- "Release metadata does not match the requested version, build, tag, commit, and bundle identifier."
    exit 2
  fi
  "$script_directory/check-release-revision.sh" \
    --version "$version" \
    --build-number "$build_number" >/dev/null
fi

for legal_file in "$project_root/INSTALLING.txt" "$project_root/LICENSE" "$project_root/THIRD_PARTY_NOTICES.md"; do
  if [[ ! -f "$legal_file" || -L "$legal_file" ]]; then
    print -u2 -- "Required release legal file is missing or unsafe: $legal_file"
    exit 2
  fi
done

"$script_directory/fetch-argyllcms.sh" \
  --verify-only \
  --archive-directory "${argyll_archive_directory:A}"

if [[ -z "$release_binary" ]]; then
  cd "$project_root"
  swift build -c release --product LumaProfileApp
  release_directory="$(swift build -c release --show-bin-path)"
  release_binary="$release_directory/LumaProfileApp"
fi

release_binary="${release_binary:A}"
if [[ ! -x "$release_binary" || -L "$release_binary" ]]; then
  print -u2 -- "Release executable is missing, unsafe, or not executable: $release_binary"
  exit 2
fi

binary_description="$(/usr/bin/file -b "$release_binary")"
if [[ "$binary_description" != *"Mach-O"* ]]; then
  print -u2 -- "Release executable is not a Mach-O: $binary_description"
  exit 2
fi
if [[ "$(/usr/bin/lipo -archs "$release_binary")" != "arm64" ]]; then
  print -u2 -- "Release executable must contain only the arm64 architecture: $binary_description"
  exit 2
fi

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/LumaProfile-package.XXXXXX")"
trap 'if [[ -n "${staging_root:-}" && -d "$staging_root" ]]; then rm -rf -- "$staging_root"; fi' EXIT INT TERM

argyll_extract_directory="$staging_root/argyll-extract"
mkdir -p "$argyll_extract_directory"
if ! /usr/bin/tar -tzf "$argyll_binary_archive" | /usr/bin/awk \
  -v root="Argyll_V${argyll_version}/" \
  'index($0, root) != 1 || $0 ~ /(^|\/)\.\.(\/|$)/ { invalid = 1 } END { exit invalid }'
then
  print -u2 -- "The verified ArgyllCMS archive has an unexpected or unsafe path layout."
  exit 2
fi
/usr/bin/tar -xzf "$argyll_binary_archive" -C "$argyll_extract_directory"
argyll_distribution="$argyll_extract_directory/Argyll_V${argyll_version}"

if [[ ! -d "$argyll_distribution/bin" || -L "$argyll_distribution" ]]; then
  print -u2 -- "The ArgyllCMS archive did not extract the expected complete distribution."
  exit 2
fi
for required_file in License.txt ReadMe.txt; do
  if [[ ! -f "$argyll_distribution/$required_file" ]]; then
    print -u2 -- "The ArgyllCMS distribution is missing $required_file."
    exit 2
  fi
done

for tool_name in "${required_argyll_tools[@]}"; do
  tool_path="$argyll_distribution/bin/$tool_name"
  if [[ ! -f "$tool_path" || ! -x "$tool_path" || -L "$tool_path" ]]; then
    print -u2 -- "The ArgyllCMS distribution is missing required executable $tool_name."
    exit 2
  fi
  tool_description="$(/usr/bin/file -b "$tool_path")"
  if [[ "$tool_description" != *"Mach-O"* || "$(/usr/bin/lipo -archs "$tool_path")" != "arm64" ]]; then
    print -u2 -- "ArgyllCMS tool $tool_name must be a thin arm64 Mach-O: $tool_description"
    exit 2
  fi
  /usr/bin/codesign --verify --strict --verbose=2 "$tool_path"
done

mach_o_count=0
while IFS= read -r -d '' candidate; do
  if [[ "$(/usr/bin/file -b "$candidate")" == *"Mach-O"* ]]; then
    if [[ "$(/usr/bin/lipo -archs "$candidate")" != "arm64" ]]; then
      print -u2 -- "Bundled ArgyllCMS Mach-O is not thin arm64: $candidate"
      exit 2
    fi
    /usr/bin/codesign --verify --strict --verbose=2 "$candidate"
    (( mach_o_count += 1 ))
  fi
done < <(/usr/bin/find "$argyll_distribution/bin" -type f -print0)

if (( mach_o_count < ${#required_argyll_tools[@]} )); then
  print -u2 -- "ArgyllCMS distribution contains fewer signed Mach-O tools than required."
  exit 2
fi

app_bundle="$staging_root/LumaProfile.app"
contents_directory="$app_bundle/Contents"
macos_directory="$contents_directory/MacOS"
resources_directory="$contents_directory/Resources"
argyll_resources="$resources_directory/ThirdParty/ArgyllCMS"
license_resources="$resources_directory/Licenses"
dmg_root="$staging_root/dmg-root"
compliance_directory="$dmg_root/Source and Licenses"
lumaprofile_source_root="$staging_root/LumaProfile-$version-source"
lumaprofile_source_archive="$staging_root/LumaProfile-$version-source.zip"
dmg_path="$output_directory/LumaProfile-$version-arm64.dmg"
checksum_path="$output_directory/LumaProfile-$version-arm64.sha256"
release_record_path="$output_directory/LumaProfile-$version-arm64.release.plist"

mkdir -p \
  "$macos_directory" \
  "$resources_directory/ThirdParty" \
  "$license_resources" \
  "$dmg_root" \
  "$compliance_directory" \
  "$output_directory"
/usr/bin/ditto "$release_binary" "$macos_directory/LumaProfileApp"
/usr/bin/ditto "$project_root/App/LumaProfileApp/Info.plist" "$contents_directory/Info.plist"
/usr/bin/ditto "$project_root/App/LumaProfileApp/AppIcon.icns" "$resources_directory/AppIcon.icns"
/usr/bin/ditto "$argyll_distribution" "$argyll_resources"
/usr/bin/ditto "$project_root/LICENSE" "$license_resources/LumaProfile-AGPL-3.0.txt"
/usr/bin/ditto "$project_root/THIRD_PARTY_NOTICES.md" "$license_resources/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto "$argyll_distribution/License.txt" "$license_resources/ArgyllCMS-License.txt"
/usr/bin/ditto "$argyll_distribution/ReadMe.txt" "$license_resources/ArgyllCMS-ReadMe.txt"
/usr/bin/ditto "$argyll_manifest" "$license_resources/ArgyllCMS-SHA256SUMS"
if [[ -n "$release_metadata_file" ]]; then
  /usr/bin/ditto "$release_metadata_file" "$resources_directory/ReleaseMetadata.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents_directory/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents_directory/Info.plist"
chmod 755 "$macos_directory/LumaProfileApp"
/usr/bin/xattr -cr "$app_bundle"

/usr/bin/codesign --force --sign - --timestamp=none "$macos_directory/LumaProfileApp"
/usr/bin/codesign --force --sign - --timestamp=none "$app_bundle"
/usr/bin/codesign --verify --strict --verbose=2 "$macos_directory/LumaProfileApp"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
/usr/bin/plutil -lint "$contents_directory/Info.plist"

for tool_name in "${required_argyll_tools[@]}"; do
  original_tool="$argyll_distribution/bin/$tool_name"
  bundled_tool="$argyll_resources/bin/$tool_name"
  if ! /usr/bin/cmp -s "$original_tool" "$bundled_tool"; then
    print -u2 -- "Packaging changed the upstream bytes for ArgyllCMS tool $tool_name."
    exit 2
  fi
  /usr/bin/codesign --verify --strict --verbose=2 "$bundled_tool"
done

mkdir -p "$lumaprofile_source_root"
for source_entry in "${source_entries[@]}"; do
  source_path="$project_root/$source_entry"
  if [[ ! -e "$source_path" || -L "$source_path" ]]; then
    print -u2 -- "Required LumaProfile source entry is missing or unsafe: $source_path"
    exit 2
  fi
  /usr/bin/ditto "$source_path" "$lumaprofile_source_root/$source_entry"
done
mkdir -p "$lumaprofile_source_root/ThirdParty/ArgyllCMS/Artifacts"
for third_party_entry in \
  "$project_root/ThirdParty/ArgyllCMS/README.md" \
  "$project_root/ThirdParty/ArgyllCMS/SHA256SUMS" \
  "$project_root/ThirdParty/ArgyllCMS/Artifacts/.gitignore"
do
  relative_path="${third_party_entry#$project_root/}"
  mkdir -p "$lumaprofile_source_root/${relative_path:h}"
  /usr/bin/ditto "$third_party_entry" "$lumaprofile_source_root/$relative_path"
done
/usr/bin/ditto \
  -c \
  -k \
  --keepParent \
  --norsrc \
  --noextattr \
  --noqtn \
  --noacl \
  "$lumaprofile_source_root" \
  "$lumaprofile_source_archive"
/usr/bin/unzip -tq "$lumaprofile_source_archive" >/dev/null
if /usr/bin/unzip -Z1 "$lumaprofile_source_archive" | /usr/bin/awk '
  /(^|\/)(\.git|\.build[^\/]*|work|outputs)(\/|$)/ { found = 1 }
  {
    marker = "/ThirdParty/ArgyllCMS/Artifacts/"
    position = index($0, marker)
    if (position > 0) {
      remainder = substr($0, position + length(marker))
      if (remainder != "" && remainder != ".gitignore") { found = 1 }
    }
  }
  END { exit !found }
'
then
  print -u2 -- "The generated LumaProfile source archive contains a forbidden build or artifact path."
  exit 2
fi

/usr/bin/ditto "$app_bundle" "$dmg_root/LumaProfile.app"
/usr/bin/ditto "$project_root/INSTALLING.txt" "$dmg_root/READ ME - Install LumaProfile.txt"
/usr/bin/ditto "$project_root/LICENSE" "$compliance_directory/LumaProfile-AGPL-3.0.txt"
/usr/bin/ditto "$project_root/THIRD_PARTY_NOTICES.md" "$compliance_directory/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto "$argyll_distribution/License.txt" "$compliance_directory/ArgyllCMS-License.txt"
/usr/bin/ditto "$argyll_distribution/ReadMe.txt" "$compliance_directory/ArgyllCMS-ReadMe.txt"
/usr/bin/ditto "$argyll_source_archive" "$compliance_directory/$argyll_source_name"
/usr/bin/ditto "$lumaprofile_source_archive" "$compliance_directory/LumaProfile-$version-source.zip"
/usr/bin/ditto "$argyll_manifest" "$compliance_directory/ArgyllCMS-SHA256SUMS"
if [[ -n "$release_metadata_file" ]]; then
  /usr/bin/ditto "$release_metadata_file" "$compliance_directory/LumaProfile-ReleaseMetadata.plist"
fi
ln -s /Applications "$dmg_root/Applications"

copied_source_hash="$(/usr/bin/shasum -a 256 "$compliance_directory/$argyll_source_name" | /usr/bin/awk '{ print $1 }')"
expected_source_hash="$(/usr/bin/awk -v name="$argyll_source_name" '$2 == name { print $1 }' "$argyll_manifest")"
if [[ "$copied_source_hash" != "$expected_source_hash" ]]; then
  print -u2 -- "The DMG staging copy of the ArgyllCMS source archive failed SHA-256 verification."
  exit 2
fi

rm -f "$dmg_path" "$checksum_path" "$release_record_path"
/usr/bin/hdiutil create \
  -volname "LumaProfile" \
  -srcfolder "$dmg_root" \
  -format UDZO \
  -ov \
  "$dmg_path"
/usr/bin/codesign --force --sign - --timestamp=none "$dmg_path"
/usr/bin/codesign --verify --strict --verbose=2 "$dmg_path"
/usr/bin/hdiutil verify "$dmg_path"

dmg_hash="$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{ print $1 }')"
print -r -- "$dmg_hash  ${dmg_path:t}" > "$checksum_path"
if [[ -n "$release_metadata_file" ]]; then
  /usr/bin/ditto "$release_metadata_file" "$release_record_path"
  /usr/bin/plutil -lint "$release_record_path" >/dev/null
fi

print -- "Packaged $mach_o_count byte-preserved ArgyllCMS arm64 tools."
print -- "$dmg_path"
print -- "$checksum_path"
if [[ -n "$release_metadata_file" ]]; then
  print -- "$release_record_path"
fi
