# GitHub/showcase release checklist

This checklist covers the current **ad-hoc-signed, non-notarized portfolio release**. It does not authorize or describe a completed Developer ID/notarized distribution. Do not publish from a dirty worktree, an untagged commit, or a revision whose corresponding source will not remain publicly available.

## 1. Establish the release revision

- [ ] Choose a numeric `X.Y.Z` version and a positive build number.
- [ ] Update `CFBundleShortVersionString` and `CFBundleVersion` in `App/LumaProfileApp/Info.plist` and the matching Xcode `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` values.
- [ ] Keep the bundle identifier exactly `com.lumaprofile.app` in both the checked-in plist and every Xcode target configuration.
- [ ] Review `LICENSE`, `THIRD_PARTY_NOTICES.md`, `ThirdParty/ArgyllCMS/SHA256SUMS`, and all release-facing documentation.
- [ ] Confirm the checked-in `AppIcon.icns` and its Xcode/Info.plist declarations are intentional release assets; do not replace them with an unreviewed generated file during packaging.
- [ ] Remove credentials, signing material, personal paths, device serials, real session data, build outputs, and downloaded vendor archives from the commit.
- [ ] Commit the exact source and create tag `vX.Y.Z` on that commit.
- [ ] Confirm the tag and commit will remain publicly accessible for as long as the binary is distributed.

The release wrapper enforces the clean-tag requirement again. It rejects tracked changes, untracked files, a missing tag, a tag that does not point to `HEAD`, and a version/build mismatch.

## 2. Validate the source

- [ ] Run `Scripts/ci/verify.sh` on the release revision.
- [ ] Confirm GitHub CI passes on macOS for the same commit.
- [ ] Review every warning and known limitation; a green automated run is not live-hardware evidence.
- [ ] Complete `docs/manual-hardware-acceptance.md` for every hardware configuration claimed in the release notes.
- [ ] If the manual checklist remains incomplete, say so plainly in the release notes and do not claim live calibration, activation, verification, disconnect recovery, or rollback acceptance.
- [ ] On the exact packaged build, review the four-step guided setup, all four documented characterization counts, manual-only activation, durable activation/restoration outcome, the full-screen Before-white surface and After-verification caveat, active-operation/quit guards, and privacy-reduced report export. Automated tests alone do not validate their interaction with a real meter or ColorSync.

## 3. Verify pinned third-party inputs

- [ ] Run `Scripts/fetch-argyllcms.sh` or place the two exact pinned archives in the configured artifact directory.
- [ ] Run `Scripts/fetch-argyllcms.sh --verify-only` against that directory.
- [ ] Confirm the binary and matching source archive are still exactly the names, sizes, and SHA-256 values in `ThirdParty/ArgyllCMS/SHA256SUMS`.
- [ ] Do not modify or re-sign any upstream ArgyllCMS executable.

## 4. Package the tagged showcase release

From the clean `vX.Y.Z` checkout, run:

```sh
LUMAPROFILE_VERSION=X.Y.Z \
LUMAPROFILE_BUILD_NUMBER=N \
Scripts/package-github-release.sh
```

- [ ] Do not use `Scripts/package-dmg.sh` directly for a public GitHub artifact. That command remains the convenient local/test packager and intentionally does not require Git history.
- [ ] Confirm the wrapper created the DMG, SHA-256 file, and `LumaProfile-X.Y.Z-arm64.release.plist`.
- [ ] Inspect the release plist and confirm `GitTag`, full `GitCommit`, version, build, bundle identifier, ArgyllCMS version, and `portfolio-ad-hoc-non-notarized` release kind.
- [ ] Mount the DMG at an isolated temporary mount point and confirm the same release metadata is present in the app resources and **Source and Licenses** folder.
- [ ] Confirm **READ ME - Install LumaProfile** is visible at the DMG root and accurately labels the build ad-hoc signed, non-notarized, and not Gatekeeper-approved with only the narrow Finder Open / Privacy & Security instructions.
- [ ] Confirm the corresponding LumaProfile source ZIP and matching ArgyllCMS source ZIP are present and pass archive testing.
- [ ] Confirm the bundled Argyll distribution is complete and upstream executable bytes/signatures remain preserved.
- [ ] Confirm the enclosing app and DMG pass the ad-hoc `codesign` checks and `hdiutil verify` performed by the packager.
- [ ] Install the app from the mounted DMG and confirm the custom icon appears in Finder, the Dock, and **About & Licenses**; metadata validation alone does not prove macOS rendered it correctly.
- [ ] Recompute the DMG SHA-256 and compare it with the emitted checksum file.

## 5. Prepare—but do not automate—GitHub publication

- [ ] Draft release notes that identify the exact tag/commit and list the DMG SHA-256.
- [ ] Label the artifact **ad-hoc signed, not notarized, and not Gatekeeper-approved** near the download link.
- [ ] Explain the narrow Finder **Open** or Privacy & Security exception; never tell users to disable Gatekeeper or broader system protections.
- [ ] State the tested macOS, display, meter, connection, firmware, and measurement mode only when supported by a completed sanitized hardware checklist.
- [ ] Describe Quick/Balanced/Detailed/Reference as 119/220/478/1,024 **characterization** patches, not total readings or fixed-duration promises.
- [ ] State plainly that generation leaves the candidate inactive, activation is a separate confirmation, and the white-card comparison is one optional setup white reading versus post-activation verification—not a full pre/post accuracy comparison.
- [ ] Explain that calibration data remains local by default and that **Export Report…** is privacy-reduced but still requires review before public sharing.
- [ ] Attach the DMG, checksum file, and release plist to the GitHub release for `vX.Y.Z`.
- [ ] Verify the public tag exposes the exact corresponding source and that the DMG also carries its required source/license bundle.
- [ ] Test the downloaded artifacts again before marking the release current.

This repository does not contain an automated publishing credential or release-upload workflow. Publishing remains an explicit maintainer action.

## 6. External Developer ID and notarization gate

The current packager cannot produce a Developer ID/notarized artifact. A future trusted distribution must use a separately reviewed workflow and must not be enabled by simply replacing the ad-hoc identity in `Scripts/package-dmg.sh`.

Before making any Developer ID, notarization, hardened-runtime, or Gatekeeper claim:

- [ ] Obtain an authorized Apple Developer ID Application identity and protect signing/notary credentials outside the repository.
- [ ] Design and review the nested-code signing strategy for the complete upstream ArgyllCMS distribution while preserving license compliance and a verifiable relationship to official upstream bytes.
- [ ] Define entitlements and hardened-runtime behavior for the app and every executable code object; repeat the live meter and rollback acceptance matrix on that exact signed build.
- [ ] Validate the final bundle with strict `codesign` assessment before submission.
- [ ] Submit the exact distributable artifact through Apple’s supported notarization tooling, wait for an accepted result, staple the ticket where supported, and validate it from a clean machine with Gatekeeper enabled.
- [ ] Archive the signing/notarization evidence, artifact hash, source tag, and toolchain details without committing credentials.
- [ ] Update the packaging implementation and documentation in a dedicated review before changing the release label.

Until every external gate is complete for the exact artifact, continue to call it **ad-hoc signed and non-notarized**.
