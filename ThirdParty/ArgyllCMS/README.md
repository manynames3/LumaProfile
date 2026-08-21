# ArgyllCMS release inputs

LumaProfile release packages use the unmodified official ArgyllCMS 3.5.0 distribution for macOS 11 ARM64 and its matching source archive:

- `https://www.argyllcms.com/Argyll_V3.5.0_macOS11_arm64_bin.tgz` — 37,235,087 bytes
- `https://www.argyllcms.com/Argyll_V3.5.0_src.zip` — 15,352,322 bytes

`SHA256SUMS` pins independently verified digests for those exact artifacts. `Scripts/fetch-argyllcms.sh` downloads over HTTPS and fails unless both byte sizes and SHA-256 values match. The archives are build inputs, not repository source, so `Artifacts/` ignores downloaded content.

`Scripts/package-dmg.sh` verifies the archives again, extracts the complete binary distribution into the application resources, preserves the upstream files and embedded linker-generated signatures, and places matching ArgyllCMS source, allowlisted LumaProfile source, and license/notice material on the DMG. Updating ArgyllCMS requires a deliberate version, URL, size, checksum, compatibility, license, and hardware-validation review; never replace an archive while retaining the old manifest entry.

ArgyllCMS 3.5.0 identifies itself as licensed under the GNU Affero General Public License version 3. The authoritative license and component-specific terms are contained in the downloaded binary and source distributions. Repository-level attribution is maintained in `THIRD_PARTY_NOTICES.md`.
