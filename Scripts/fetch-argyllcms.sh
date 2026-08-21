#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h}"
release_directory="$project_root/ThirdParty/ArgyllCMS"
manifest="$release_directory/SHA256SUMS"
archive_directory="${LUMAPROFILE_ARGYLL_ARCHIVE_DIRECTORY:-$release_directory/Artifacts}"
mode="fetch"

binary_archive_name="Argyll_V3.5.0_macOS11_arm64_bin.tgz"
source_archive_name="Argyll_V3.5.0_src.zip"
binary_archive_url="https://www.argyllcms.com/$binary_archive_name"
source_archive_url="https://www.argyllcms.com/$source_archive_name"
binary_archive_size="37235087"
source_archive_size="15352322"

usage() {
  print -u2 -- "Usage: Scripts/fetch-argyllcms.sh [--verify-only] [--archive-directory PATH]"
}

while (( $# > 0 )); do
  case "$1" in
    --verify-only)
      mode="verify"
      shift
      ;;
    --archive-directory)
      if (( $# < 2 )); then
        usage
        exit 2
      fi
      archive_directory="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

archive_directory="${archive_directory:A}"

if [[ ! -f "$manifest" || -L "$manifest" ]]; then
  print -u2 -- "Pinned checksum manifest is missing or unsafe: $manifest"
  exit 2
fi

manifest_hash() {
  local artifact_name="$1"
  local hash
  local match_count
  hash="$(/usr/bin/awk -v name="$artifact_name" '$2 == name { print $1 }' "$manifest")"
  match_count="$(/usr/bin/awk -v name="$artifact_name" '$2 == name { count += 1 } END { print count + 0 }' "$manifest")"
  if [[ "$match_count" != "1" || ! "$hash" =~ '^[0-9a-f]{64}$' ]]; then
    print -u2 -- "Checksum manifest must contain one lowercase SHA-256 entry for $artifact_name."
    exit 2
  fi
  print -r -- "$hash"
}

verify_archive() {
  local archive_path="$1"
  local artifact_name="$2"
  local expected_size="$3"
  local expected_hash="$4"
  local actual_size
  local actual_hash

  if [[ ! -f "$archive_path" || -L "$archive_path" ]]; then
    print -u2 -- "Required archive is missing or is a symbolic link: $archive_path"
    return 1
  fi
  actual_size="$(/usr/bin/stat -f '%z' "$archive_path")"
  if [[ "$actual_size" != "$expected_size" ]]; then
    print -u2 -- "$artifact_name has size $actual_size; expected $expected_size bytes."
    return 1
  fi
  actual_hash="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{ print $1 }')"
  if [[ "$actual_hash" != "$expected_hash" ]]; then
    print -u2 -- "$artifact_name failed SHA-256 verification."
    print -u2 -- "Expected: $expected_hash"
    print -u2 -- "Actual:   $actual_hash"
    return 1
  fi
}

binary_hash="$(manifest_hash "$binary_archive_name")"
source_hash="$(manifest_hash "$source_archive_name")"

if [[ "$mode" == "fetch" ]]; then
  mkdir -p "$archive_directory"
  download_directory="$(mktemp -d "$archive_directory/.download.XXXXXX")"
  trap 'if [[ -n "${download_directory:-}" && -d "$download_directory" ]]; then rm -rf -- "$download_directory"; fi' EXIT INT TERM

  /usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --output "$download_directory/$binary_archive_name" \
    "$binary_archive_url"
  /usr/bin/curl \
    --fail \
    --location \
    --proto '=https' \
    --tlsv1.2 \
    --retry 3 \
    --output "$download_directory/$source_archive_name" \
    "$source_archive_url"

  verify_archive \
    "$download_directory/$binary_archive_name" \
    "$binary_archive_name" \
    "$binary_archive_size" \
    "$binary_hash"
  verify_archive \
    "$download_directory/$source_archive_name" \
    "$source_archive_name" \
    "$source_archive_size" \
    "$source_hash"
  /usr/bin/unzip -tq "$download_directory/$source_archive_name" >/dev/null

  chmod 644 "$download_directory/$binary_archive_name" "$download_directory/$source_archive_name"
  /bin/mv -f "$download_directory/$binary_archive_name" "$archive_directory/$binary_archive_name"
  /bin/mv -f "$download_directory/$source_archive_name" "$archive_directory/$source_archive_name"
fi

verify_archive \
  "$archive_directory/$binary_archive_name" \
  "$binary_archive_name" \
  "$binary_archive_size" \
  "$binary_hash"
verify_archive \
  "$archive_directory/$source_archive_name" \
  "$source_archive_name" \
  "$source_archive_size" \
  "$source_hash"
/usr/bin/unzip -tq "$archive_directory/$source_archive_name" >/dev/null

print -- "Verified pinned ArgyllCMS 3.5.0 archives in $archive_directory"
