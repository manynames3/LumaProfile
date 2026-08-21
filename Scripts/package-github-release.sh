#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h}"
info_plist="$project_root/App/LumaProfileApp/Info.plist"
version="${LUMAPROFILE_VERSION:-$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")}"
build_number="${LUMAPROFILE_BUILD_NUMBER:-$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_plist")}"
output_directory="${LUMAPROFILE_OUTPUT_DIRECTORY:-$project_root/outputs}"

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/LumaProfile-release.XXXXXX")"
trap 'if [[ -n "${staging_root:-}" && -d "$staging_root" ]]; then rm -rf -- "$staging_root"; fi' EXIT INT TERM
metadata_file="$staging_root/LumaProfile-release-metadata.plist"

"$script_directory/check-release-revision.sh" \
  --version "$version" \
  --build-number "$build_number" \
  --metadata-output "$metadata_file"

LUMAPROFILE_VERSION="$version" \
LUMAPROFILE_BUILD_NUMBER="$build_number" \
LUMAPROFILE_OUTPUT_DIRECTORY="$output_directory" \
LUMAPROFILE_RELEASE_METADATA_FILE="$metadata_file" \
  "$script_directory/package-dmg.sh"

output_directory="${output_directory:A}"
release_record="$output_directory/LumaProfile-$version-arm64.release.plist"
release_dmg="$output_directory/LumaProfile-$version-arm64.dmg"
release_checksum="$output_directory/LumaProfile-$version-arm64.sha256"

discard_generated_release() {
  for generated_path in "$release_record" "$release_dmg" "$release_checksum"; do
    if [[ -e "$generated_path" && ! -d "$generated_path" ]]; then
      /bin/unlink "$generated_path"
    fi
  done
}

if ! "$script_directory/check-release-revision.sh" \
  --version "$version" \
  --build-number "$build_number" >/dev/null
then
  print -u2 -- "The source revision changed while packaging. Generated release files were discarded."
  discard_generated_release
  exit 2
fi

expected_commit="$(/usr/bin/git -C "$project_root" rev-parse --verify HEAD)"
recorded_commit="$(/usr/bin/plutil -extract GitCommit raw -o - "$release_record")"
[[ "$recorded_commit" == "$expected_commit" ]] || {
  print -u2 -- "Release record commit mismatch: expected $expected_commit, found $recorded_commit"
  discard_generated_release
  exit 2
}

print -- "GitHub/showcase release package is tied to v$version at $recorded_commit."
print -- "$release_record"
