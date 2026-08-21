#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h:h}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/LumaProfile-release-check-test.XXXXXX")"
trap 'if [[ -n "${temporary_root:-}" && -d "$temporary_root" ]]; then rm -rf -- "$temporary_root"; fi' EXIT INT TERM
fixture_root="$temporary_root/repository"

mkdir -p \
  "$fixture_root/App/LumaProfileApp" \
  "$fixture_root/App/LumaProfileApp.xcodeproj" \
  "$fixture_root/Scripts/ci"
/usr/bin/ditto "$project_root/App/LumaProfileApp/Info.plist" "$fixture_root/App/LumaProfileApp/Info.plist"
/usr/bin/ditto "$project_root/App/LumaProfileApp/AppIcon.icns" "$fixture_root/App/LumaProfileApp/AppIcon.icns"
/usr/bin/ditto "$project_root/App/LumaProfileApp.xcodeproj/project.pbxproj" "$fixture_root/App/LumaProfileApp.xcodeproj/project.pbxproj"
/usr/bin/ditto "$project_root/Package.swift" "$fixture_root/Package.swift"
/usr/bin/ditto "$project_root/Scripts/check-release-revision.sh" "$fixture_root/Scripts/check-release-revision.sh"
/usr/bin/ditto "$project_root/Scripts/ci/check-release-metadata.sh" "$fixture_root/Scripts/ci/check-release-metadata.sh"

release_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$fixture_root/App/LumaProfileApp/Info.plist")"
release_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$fixture_root/App/LumaProfileApp/Info.plist")"

/usr/bin/git -C "$fixture_root" init -q
/usr/bin/git -C "$fixture_root" config user.name "LumaProfile CI"
/usr/bin/git -C "$fixture_root" config user.email "ci@example.invalid"
/usr/bin/git -C "$fixture_root" add .
/usr/bin/git -C "$fixture_root" -c commit.gpgsign=false commit --no-verify -qm "Synthetic release fixture"
/usr/bin/git -C "$fixture_root" tag "v$release_version"

metadata="$temporary_root/release.plist"
/bin/zsh "$fixture_root/Scripts/check-release-revision.sh" \
  --version "$release_version" \
  --build-number "$release_build" \
  --metadata-output "$metadata" >/dev/null
expected_commit="$(/usr/bin/git -C "$fixture_root" rev-parse --verify HEAD)"
recorded_commit="$(/usr/bin/plutil -extract GitCommit raw -o - "$metadata")"
[[ "$recorded_commit" == "$expected_commit" ]] || {
  print -u2 -- "Synthetic release metadata did not record HEAD."
  exit 1
}

/usr/bin/touch "$fixture_root/untracked-release-change"
if /bin/zsh "$fixture_root/Scripts/check-release-revision.sh" \
  --version "$release_version" \
  --build-number "$release_build" >/dev/null 2>&1
then
  print -u2 -- "Release revision check accepted a dirty worktree."
  exit 1
fi

print -- "Release revision guard accepts a clean exact tag and rejects a dirty worktree."
