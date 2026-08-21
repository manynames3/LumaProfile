#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h}"
info_plist="$project_root/App/LumaProfileApp/Info.plist"
version="${LUMAPROFILE_VERSION:-$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")}"
build_number="${LUMAPROFILE_BUILD_NUMBER:-$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_plist")}"
metadata_output=""

usage() {
  print -u2 -- "Usage: Scripts/check-release-revision.sh [--version X.Y.Z] [--build-number N] [--metadata-output PATH]"
}

fail() {
  print -u2 -- "Release revision check failed: $1"
  exit 2
}

while (( $# > 0 )); do
  case "$1" in
    --version)
      (( $# >= 2 )) || { usage; exit 2; }
      version="$2"
      shift 2
      ;;
    --build-number)
      (( $# >= 2 )) || { usage; exit 2; }
      build_number="$2"
      shift 2
      ;;
    --metadata-output)
      (( $# >= 2 )) || { usage; exit 2; }
      metadata_output="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument '$1'."
      ;;
  esac
done

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
  || fail "version must use numeric major.minor.patch form."
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] \
  || fail "build number must be a positive integer."

"$script_directory/ci/check-release-metadata.sh" >/dev/null

plist_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
plist_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info_plist")"
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
[[ "$version" == "$plist_version" ]] \
  || fail "requested version '$version' does not match Info.plist '$plist_version'."
[[ "$build_number" == "$plist_build" ]] \
  || fail "requested build '$build_number' does not match Info.plist '$plist_build'."

[[ "$(/usr/bin/git -C "$project_root" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]] \
  || fail "the project is not inside a Git worktree."

head_commit="$(/usr/bin/git -C "$project_root" rev-parse --verify HEAD 2>/dev/null)" \
  || fail "HEAD does not resolve to a commit. Commit the exact release source first."
[[ "$head_commit" =~ '^[0-9a-f]{40}$' ]] \
  || fail "HEAD did not resolve to a full commit SHA."

worktree_status="$(/usr/bin/git -C "$project_root" status --porcelain=v1 --untracked-files=all)"
if [[ -n "$worktree_status" ]]; then
  print -u2 -- "$worktree_status"
  fail "the worktree is not clean. Commit or remove every tracked and untracked change before release packaging."
fi

expected_tag="v$version"
tag_commit="$(/usr/bin/git -C "$project_root" rev-parse --verify "$expected_tag^{commit}" 2>/dev/null)" \
  || fail "required tag '$expected_tag' does not exist."
[[ "$tag_commit" == "$head_commit" ]] \
  || fail "tag '$expected_tag' does not point to HEAD ($head_commit)."

if [[ -n "$metadata_output" ]]; then
  metadata_output="${metadata_output:A}"
  metadata_parent="${metadata_output:h}"
  [[ -d "$metadata_parent" && ! -L "$metadata_parent" ]] \
    || fail "metadata output parent is missing or unsafe: $metadata_parent"
  [[ ! -L "$metadata_output" ]] \
    || fail "metadata output must not be a symbolic link: $metadata_output"

  metadata_temporary="$(mktemp "$metadata_parent/.LumaProfile-release-metadata.XXXXXX")"
  cleanup_metadata() {
    if [[ -n "${metadata_temporary:-}" && -e "$metadata_temporary" ]]; then
      /bin/unlink "$metadata_temporary"
    fi
  }
  trap cleanup_metadata EXIT INT TERM

  /usr/bin/plutil -create xml1 "$metadata_temporary"
  /usr/bin/plutil -insert SchemaVersion -integer 1 "$metadata_temporary"
  /usr/bin/plutil -insert Product -string "LumaProfile" "$metadata_temporary"
  /usr/bin/plutil -insert ReleaseKind -string "portfolio-ad-hoc-non-notarized" "$metadata_temporary"
  /usr/bin/plutil -insert Version -string "$version" "$metadata_temporary"
  /usr/bin/plutil -insert BuildNumber -string "$build_number" "$metadata_temporary"
  /usr/bin/plutil -insert GitTag -string "$expected_tag" "$metadata_temporary"
  /usr/bin/plutil -insert GitCommit -string "$head_commit" "$metadata_temporary"
  /usr/bin/plutil -insert BundleIdentifier -string "$bundle_identifier" "$metadata_temporary"
  /usr/bin/plutil -insert ArgyllCMSVersion -string "3.5.0" "$metadata_temporary"
  /usr/bin/plutil -lint "$metadata_temporary" >/dev/null
  /bin/mv -f "$metadata_temporary" "$metadata_output"
  metadata_temporary=""
fi

print -- "Release revision verified: $expected_tag at $head_commit"
