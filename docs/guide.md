# LumaProfile guide

The full manual: build steps, packaging, privacy, rollback and limits. For the short version, see the [README](../README.md).

## Requirements

- An Apple Silicon Mac running macOS 15 or newer
- Xcode 16 or a compatible Swift 6 toolchain
- For the current guided calibration path: a supported X-Rite i1Display Pro/Plus (i1D3-family) colorimeter; some meters also need manufacturer-supplied firmware or calibration data
- A stable display mode with automatic appearance features disabled for the run (for example, True Tone, Night Shift, and automatic brightness)

No administrator or root account is required to build or run LumaProfile. The app is designed for user-level operation and user-level ICC profile installation. Do not launch it with `sudo`.

## Build, test, and run

From the repository root:

```sh
swift build
swift test
swift run LumaProfileApp
```

For normal Xcode development, open `App/LumaProfileApp.xcodeproj`, select the `LumaProfileApp` scheme and “My Mac,” then build and run. Opening `Package.swift` directly is also useful for working on the package targets. The deployment target is macOS 15.

The automated suite is hermetic: it uses protocol fakes, temporary directories, shell subprocesses, and explicitly labeled synthetic Argyll-like transcripts. It does not need ArgyllCMS or calibration hardware and does not alter the active display profile.

The checked-in GitHub Actions workflow runs the same build, tests, project-metadata checks, plist/XML validation, shell syntax checks, and release-guard self-test on macOS. See [`CONTRIBUTING.md`](../CONTRIBUTING.md) before proposing a change and [`SECURITY.md`](../SECURITY.md) before reporting security-sensitive behavior.

## Build a one-install local package

Fetch the pinned release inputs, then create a compressed drag-to-Applications disk image:

```sh
Scripts/fetch-argyllcms.sh
swift build -c release --product LumaProfileApp
Scripts/package-dmg.sh
```

The fetch step accepts only the official ArgyllCMS 3.5.0 macOS 11 ARM64 TGZ and matching source ZIP whose exact sizes and SHA-256 values are checked into `ThirdParty/ArgyllCMS/SHA256SUMS`. Packaging verifies them again, checks that the required tools and all upstream Mach-O executables are thin arm64 with valid embedded signatures, and copies the complete extracted distribution to `LumaProfile.app/Contents/Resources/ThirdParty/ArgyllCMS`. It preserves upstream tool bytes, signs the enclosing app so its resource seal covers them, verifies the app and disk image, and writes the DMG plus its SHA-256 file under `outputs/`.

The script intentionally produces an ad-hoc-signed, non-notarized package for local validation. It does not require Git history, so it is not the public-release entry point. Every artifact it creates must be labeled **not notarized and not Gatekeeper-approved**. Downloaded users may need to use Finder’s **Open** context-menu command once or approve the app in **System Settings → Privacy & Security**. Do not claim Developer ID or notarization trust for this artifact.

The DMG contains `LumaProfile.app`, an Applications shortcut, a root-visible **READ ME - Install LumaProfile** notice with the exact non-notarized opening instructions, and a **Source and Licenses** folder containing `LumaProfile-<version>-source.zip`, the exact matching ArgyllCMS source ZIP, upstream license/readme, LumaProfile license, third-party notices, and checksum manifest. Build caches, downloaded vendor artifacts, outputs, work files, and Git metadata are excluded from the LumaProfile source ZIP; the script tests both source archives before imaging. The app also carries runtime notices under `Contents/Resources/Licenses`.

Developer ID signing and notarization are a future release-hardening step. Apple’s hardened-runtime distribution rules also apply to nested executables, while this portfolio packager intentionally preserves the official Argyll tool bytes and linker-generated ad-hoc signatures. A future notarized release therefore needs a separately designed nested-tool signing and bundle-layout workflow; setting an identity on this script is not sufficient.

## Package a prospective GitHub/showcase release

Public portfolio artifacts use a guarded wrapper around the same byte-preserving local packager:

```sh
LUMAPROFILE_VERSION=0.1.2 \
LUMAPROFILE_BUILD_NUMBER=3 \
Scripts/package-github-release.sh
```

The wrapper runs only from a clean Git worktree whose `HEAD` is the exact `v<version>` tag, and only when the plist and Xcode version, build, deployment target, executable, and stable `com.lumaprofile.app` bundle identifier agree. It creates `LumaProfile-<version>-arm64.release.plist`, embeds the same record in the app and DMG compliance folder, and records the full source commit SHA, tag, release kind, bundle identifier, and ArgyllCMS version. This provenance gate does not sign with Developer ID, submit to Apple, notarize, staple, or publish anything.

Follow [`docs/release-checklist.md`](release-checklist.md) before uploading an artifact. GitHub publication remains a manual maintainer action so the exact public source tag, binary checksum, license/source payload, hardware evidence, and non-notarized labeling can be reviewed together. The existence of this packaging path does not mean a GitHub release has been published or accepted on live hardware.

## Source and license compliance

LumaProfile follows the AGPLv3 public-GitHub distribution route. Every published DMG and checksum must be associated with the exact public source revision used to build it; do not delete or rewrite that revision while its binaries are distributed. The root `LICENSE` governs LumaProfile, and `THIRD_PARTY_NOTICES.md` records third-party attribution.

ArgyllCMS 3.5.0 identifies itself as AGPLv3 software. LumaProfile redistributes the full unmodified official ARM64 binary distribution from the [ArgyllCMS macOS download page](https://www.argyllcms.com/downloadmac.html) and places its matching official [source archive](https://www.argyllcms.com/downloadsrc.html) on the same DMG. The upstream distribution also retains its own license, component notices, documentation, reference data, and readme. Review the upstream [commercial/non-AGPL licensing information](https://www.argyllcms.com/commercialuse.html) before choosing any distribution route other than this public AGPLv3 route.

Open the DMG and drag **LumaProfile** to **Applications**. Nothing else needs to be installed for the calibration engine. If macOS blocks this clearly labeled ad-hoc build, use Finder’s one-time **Open** action or the specific **Privacy & Security** approval instead of disabling system security, applying broad permission changes, or running the application as root.

## Permissions and device access

On first use, macOS may ask for access needed to communicate with an attached USB device or to write a user ColorSync profile. Grant only prompts that match the action you just initiated. LumaProfile should never request an administrator password.

Only one application can usually own a meter at a time. Quit vendor calibration utilities and other color-management tools before discovery. Connect the meter directly when possible, and keep the Mac awake and on power during a calibration. If a device is not found, reconnect it, verify that Argyll can see it from Terminal, and check for a vendor background service holding the USB interface.

## End-to-end use

1. Launch LumaProfile. The setup guide moves through **Display & Meter**, **Target & Speed**, **Prepare**, and **Review**; it does not enable the final start action until the required hardware mapping and preparation confirmations are complete.
2. In **Display & Meter**, select the physical display, show the large identifier on it, and confirm the matching Argyll display description and number. Avoid mirrored, virtual, Sidecar, or AirPlay displays for a P0 run. Select the detected i1D3-family USB meter and use “Auto” measurement mode unless you know whether the panel is refresh or non-refresh.
3. Optionally import a trusted CCSS or CCMX correction that matches both the display technology and meter. Check its displayed provenance; a mismatch requires explicit acknowledgment and can make results worse. LumaProfile remembers the chosen mapping, meter, correction, target, effort, and profile model for that display fingerprint after a run starts, but it still requires physical identification and mapping confirmation on a later run.
4. In **Target & Speed**, choose a preset or supported custom target. The video presets set tone response and white/luminance goals; they do not promise to clamp a wide-gamut panel to Rec.709. Then choose measurement effort: **Quick** is the default and shortest option, with a lower-detail 119-patch characterization; **Balanced** is the recommended routine choice at 220 patches; **Detailed** uses 478 patches for more detail and a longer run; and **Reference** is the longest Expert option at 1,024 patches. These counts cover characterization only. Calibration adds its own readings, and optional verification is a separate pass after explicit activation, so elapsed time varies rather than matching a promised number of minutes.
5. In **Prepare**, confirm warm-up, stable lighting, disabled dynamic display features, and intended hardware controls. The optional **Measure White** action presents a full-screen RGB-white surface on the confirmed physical display before triggering the meter, keeps it visible through the reading, and offers **Cancel Reading** at the lower-right edge. It gives brightness and white-point setup guidance and saves one white-patch reading for the later Before comparison; it is not a full pre-calibration accuracy pass. **Adjust Live** uses the same white surface but keeps taking readings every few seconds and shows a gauge at the bottom edge with the measured luminance, the target, and how far to raise or lower the monitor's own brightness; choose **Done** to keep the last reading. While it runs, the selected display's calibration curve is bypassed so the gauge shows the panel's own output, which is what calibration starts from; the associated profile's calibration is reloaded when you finish. Setting brightness on the monitor first leaves calibration less to correct in software.
6. In **Review**, check the selected display, meter, target, effort, characterization count, manual-activation policy, and every readiness item before starting.
7. Place the meter only when prompted. Follow the interactive black-level, white-point, luminance, and patch-reading instructions. Never guess a response to an unfamiliar prompt—cancel and retain the session log instead.
8. Let calibration and characterization complete without changing display settings, moving the patch window, disconnecting the meter, or allowing the Mac to sleep. Argyll temporarily loads the run's calibration into the selected display's VideoLUT while it measures the profile.
9. Review the completed **Profile Before / After** summary. **Before** is the ColorSync profile association captured when the run began; **After** is the generated ICC candidate and initially reads **Generated; not currently activated by this session**. This records the session's identities and does not by itself claim a visible or measured improvement.
10. If **Measure White** was used, the separate measured comparison shows that single setup reading as **Before setup reading**. **After verification** remains unavailable until the operator activates the candidate and completes verification. The two cards compare white luminance, xy chromaticity, and estimated color temperature only; they are not equivalent full before/after patch sets and do not establish pre-calibration color accuracy.
11. Stop after generation if you only want the profile file. LumaProfile does not automatically install, activate, or verify it. A generation-only run keeps the original ColorSync association and asks ColorSync to reload the currently associated profile's calibration.
12. To use the generated profile, choose **Activate & Verify After** and confirm the named display, Before profile, and candidate. LumaProfile validates the candidate again, installs it at user scope, verifies the ColorSync association, and then performs new verification measurements. A successful attempt leaves After active; cancellation or failure triggers an attempt to restore Before. Inspect Delta E, white point, luminance, gamma, warnings, and the raw technical log.

## Before / After comparison

Once a session has activated its After profile, the result card offers a **Before | After** switch with a neutral reference strip. Choosing **Before** temporarily points the same display back at the profile that was active when the run began so you can judge the change by eye; choosing **After** returns it. This is a viewing aid, not a rollback: the session stays recorded as activated, no file is removed, and LumaProfile puts After back before another profile-changing operation and before quitting. It refuses to switch if the display is on any profile other than those two. If the app is force-quit while Before is showing, the display stays on Before until you activate again or pick the profile in System Settings.

## Local data, privacy, and reports

Measurements, generated profiles, imported correction copies, session JSON, event logs, and raw Argyll diagnostics remain in the current user's local account. Sessions and corrections are stored under `~/Library/Application Support/LumaProfile`; a candidate explicitly activated by the operator is copied under `~/Library/ColorSync/Profiles/LumaProfile`. LumaProfile does not require an account or upload calibration data. **Settings → Reveal Local Data** opens the app-managed data folder.

History retains completed, failed, cancelled, and interrupted outcomes. Activation-and-verification attempts persist their status, timestamps, error, and whether restoration of Before was confirmed. That record survives relaunch for diagnosis and recovery, but it is historical evidence: opening an old session does not perform a fresh ColorSync readback or prove that another application or later user action has not changed the active profile.

Partial artifacts are marked incomplete and must not be treated as valid profiles. Sessions that may still be required for restoration cannot be deleted from the app until their recovery state is resolved. **Copy Diagnostics** produces a reduced clipboard summary that omits raw measurements and shortens the user's home path; review it before sharing publicly.

From a History session, **Export Report…** writes a user-chosen plain-text `.txt` summary with target/setup details, the optional Before white reading, generated-candidate status, explicit activation/verification/rollback outcome, After metrics and rating reasons, and artifact filenames. The export excludes raw logs and Argyll output, meter serial numbers, hashes, and absolute home-folder paths; free-text errors and warnings have the home path replaced. It is a convenient privacy-reduced summary, not a substitute for reviewing the raw local session when diagnosing a failure. Historical sessions without newer outcome fields are labeled as historical rather than having a result inferred for them.

## Cancellation, failures, and profile rollback

Cancellation is cooperative but must leave the display in a safe state: LumaProfile terminates the active child process, records a cancelled/interrupted session, and does not promote partial output as complete. Wait for the cancellation status before unplugging the instrument.

Profile generation and profile activation are separate operations. During calibration and characterization, Argyll may temporarily replace the selected display's VideoLUT contents without changing its ColorSync profile association. A generation-only completion, cancellation, or failure attempts to reload calibration from the profile currently associated with the display—normally the unchanged Before profile. If that restoration cannot be verified, the session retains an actionable warning rather than claiming the display state was restored.

While measurement, calibration, activation, or **Restore Before** is active, LumaProfile prevents engine reloads and keeps an app-owned activity assertion. Engine probe and meter discovery are serialized so a queued refresh cannot publish results for the wrong engine. Closing the only app window follows the normal Quit path: active work must cancel safely, while an already-running **Restore Before** is allowed to finish. Restore Before writes a durable recovery marker before changing ColorSync or the display calibration. If restoration fails or does not finish promptly, the affected session remains marked for recovery; that per-session warning survives relaunch, and Quit and new profile-changing work remain blocked until every affected session has a successful explicit **Restore Before**. An unfinished or unreadable saved session also blocks calibration and activation rather than being silently skipped.

The activity assertion prevents idle system/display sleep; macOS can still sleep because of a closed laptop lid, a user command, power loss, or system policy. A sleep notification requests cancellation, and wake handling repeats that request or resumes Restore Before, but pre-sleep rollback cannot be guaranteed. Keep the Mac awake and on power. If forced sleep interrupts the run, treat an **Interrupted** session as requiring explicit **Restore Before** recovery.

Before every indexed Argyll operation, LumaProfile re-enumerates the engine display list and compares the exact description captured when the operator confirmed the mapping. If a display is added, removed, moved, or reordered, the operation stops before sending patches or VideoLUT commands. Refresh hardware, identify the physical display again, and reconfirm its engine number.

Only explicit activation changes the profile association. Before that change, LumaProfile records the selected display's current profile again. If installation or post-activation verification fails or is cancelled, the workflow attempts to restore both the previous association and its calibration. Restoration is scoped by the display fingerprint so that a profile is not applied to the wrong monitor.

If the application or Mac exits during generation or before automatic rollback completes, LumaProfile marks the live session **Interrupted** on its next launch. After reconnecting the same display topology, use **Restore Before**; generation-only recovery first confirms that the ColorSync association still matches Before, then reloads its calibration without installing the candidate. If in-app recovery cannot be completed, open **ColorSync Utility**, select the affected display, and manually choose the previously active profile recorded in the session. Do not delete that profile until the new profile has been verified. Reopening a session does not by itself prove which profile macOS currently has active.

## Fixture validation

Run the full deterministic validation with:

```sh
swift test
```

Fixtures live in `Tests/LumaCoreTests/Fixtures`. Their manifest and every transcript identify them as synthetic, recorded-looking test data. They cover expected, malformed, truncated, nonzero-exit, and unknown-prompt paths without claiming that any supported meter produced the text. When adapting a parser to real output, remove serial numbers and user paths, add a minimal synthetic regression fixture with the same structure, document its provenance as synthetic, and rerun the full suite.

Real hardware acceptance is intentionally separate; use [`docs/manual-hardware-acceptance.md`](manual-hardware-acceptance.md) and record the exact Mac, display, meter, Argyll version, and outcome. An unchecked checklist is not test evidence.

## Known limitations

- Hardware acceptance so far covers one setup (Mac mini, Dell S3221QS, i1 Display Pro): detection, display mapping, white reading, a Quick calibration, profile build, Activate & Verify, cancel with Restore Before, the Before / After switch and Adjust Live. Meter unplug mid-run, force-quit recovery, sleep handling, other displays and other meters are not yet verified; see the checklist below.
- Packaging validation proves archive identity, executable architecture/signatures, bundle sealing, and disk-image integrity; it does not prove live meter compatibility or calibration accuracy.
- Argyll output can differ by version, instrument, locale, and mode. Unknown prompts fail closed rather than receiving an automatic response.
- P0 targets a single directly attached physical display at a time; mirrored, virtual, Sidecar, AirPlay, HDR, and multi-display reconfiguration during a run are outside the validated path.
- Verification metrics summarize the measured patches; they cannot detect every panel uniformity, viewing-angle, flare, ambient-light, or observer-metamerism issue.
- Verification CCT uses an approximation for operator guidance; white-point Delta E uses normalized XYZ under the documented fixed-D50, no-adaptation comparison in `ColorScience`.
- A CCSS/CCMX correction is not authenticated merely because it parses. The operator remains responsible for its source and display/instrument match.
- The app is not a substitute for a repeatable viewing environment or periodic recalibration.

See [`PROJECT_STATE.md`](../PROJECT_STATE.md) for durable engineering decisions rather than a release-status claim.
