#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h:h}"
cd "$project_root"

while IFS= read -r -d '' script; do
  /bin/zsh -n "$script"
done < <(/usr/bin/find Scripts -type f -name '*.sh' -print0)

Scripts/ci/check-release-metadata.sh
Scripts/ci/test-release-revision.sh
/usr/bin/plutil -lint App/LumaProfileApp/Info.plist
/usr/bin/plutil -lint App/LumaProfileApp.xcodeproj/project.pbxproj
/usr/bin/xmllint --noout App/LumaProfileApp.xcodeproj/xcshareddata/xcschemes/LumaProfileApp.xcscheme

manifest_sdk_root="${LUMAPROFILE_MANIFEST_SDKROOT:-${LUMAPROFILE_SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}}"
target_sdk_root="${LUMAPROFILE_TARGET_SDKROOT:-$manifest_sdk_root}"
task_cache_root="$project_root/work/cache"
scratch_path="${LUMAPROFILE_SCRATCH_PATH:-$project_root/.build}"
mkdir -p "$task_cache_root/clang" "$task_cache_root/swiftpm" "$task_cache_root/config" "$task_cache_root/security"

export SDKROOT="$manifest_sdk_root"
export CLANG_MODULE_CACHE_PATH="$task_cache_root/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_cache_root/clang"

swift_options=(
  --disable-sandbox
  --sdk "$target_sdk_root"
  --cache-path "$task_cache_root/swiftpm"
  --config-path "$task_cache_root/config"
  --security-path "$task_cache_root/security"
  --scratch-path "$scratch_path"
)

if [[ -n "${LUMAPROFILE_INTERFACE_COMPILER_VERSION:-}" ]]; then
  swift_options+=(
    -Xswiftc -interface-compiler-version
    -Xswiftc "$LUMAPROFILE_INTERFACE_COMPILER_VERSION"
  )
fi

if [[ -n "${LUMAPROFILE_DEVELOPER_FRAMEWORKS:-}" ]]; then
  swift_options+=(
    -Xswiftc -F
    -Xswiftc "$LUMAPROFILE_DEVELOPER_FRAMEWORKS"
    -Xlinker -F
    -Xlinker "$LUMAPROFILE_DEVELOPER_FRAMEWORKS"
    -Xlinker -rpath
    -Xlinker "$LUMAPROFILE_DEVELOPER_FRAMEWORKS"
  )
fi

if [[ -n "${LUMAPROFILE_DEVELOPER_LIBRARY_PATH:-}" ]]; then
  export DYLD_LIBRARY_PATH="$LUMAPROFILE_DEVELOPER_LIBRARY_PATH${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  swift_options+=(
    -Xlinker -rpath
    -Xlinker "$LUMAPROFILE_DEVELOPER_LIBRARY_PATH"
  )
fi

swift build "${swift_options[@]}" --product LumaProfileApp
swift test "${swift_options[@]}"
