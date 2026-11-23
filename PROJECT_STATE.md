# Project state

## Product boundary

- LumaProfile is a macOS 15, Apple Silicon, Swift 6 package.
- `LumaCore` contains domain models, color math, Argyll integration, persistence, and workflow behavior.
- `LumaProfileApp` is the executable UI and depends on `LumaCore`.
- P0 operates on one explicitly selected, directly attached physical display at a time.
- The interface uses one in-repo design system (`DesignSystem.swift`): a fixed dark, hue-free neutral palette with a near-white accent so application chrome does not bias the operator's judgement of the measured display; colour is reserved for status.
- The primary operator path is a four-step **Display & Meter**, **Target & Speed**, **Prepare**, and **Review** guide. The packaged app and About view use the checked-in custom `AppIcon.icns` rather than the generic executable icon.

## Bundled engine

- Release builds bundle the complete, unmodified official ArgyllCMS 3.5.0 macOS ARM64 binary distribution for one-install operation.
- Its binary TGZ and matching source ZIP are pinned by official URL, exact byte size, and checked-in SHA-256; a mismatch stops packaging.
- Downloaded archives are release inputs rather than repository source. The DMG carries allowlisted corresponding LumaProfile source, the matching Argyll source ZIP, and license/notices.
- LumaProfile uses the AGPLv3 public-GitHub distribution route; each binary release must retain access to its exact corresponding source revision.
- The bundled distribution has precedence in an installed app, while explicit developer configuration remains an intentional override.
- Discovery resolves a single coherent `bin` directory containing every required executable.
- Explicit configuration has precedence over environment/PATH and conventional locations.
- Commands use executable URLs and argument arrays, never shell command interpolation.
- Interactive parsing fails closed for unknown prompts and preserves raw diagnostics.
- Packaging preserves upstream Argyll executable bytes and embedded signatures, then signs and verifies the enclosing app and DMG.
- The current DMG is explicitly ad-hoc signed and non-notarized for local/portfolio distribution; Developer ID/Gatekeeper hardening requires a future nested-tool signing and layout design.

## Calibration semantics

- Display identity is a stable fingerprint, not a transient enumeration index.
- Every confirmed Argyll display index is persisted with its exact enumerated description and revalidated immediately before indexed patch, verification, and VideoLUT operations; topology changes fail closed.
- A correction is optional, provenance-bearing, and never substituted silently.
- Video targets configure white point, luminance, and tone response; they do not promise gamut clamping.
- Guided measurement effort couples calibration refinement with a pinned characterization mapping: Quick is the default, shortest, lower-detail 119-patch choice; Balanced is the recommended 220-patch choice; Detailed is the longer, more-detailed 478-patch choice; and Reference is the longest Expert choice at 1,024 patches.
- Those exact characterization counts were generated and verified with the bundled ArgyllCMS 3.5.0 tool. They exclude calibration readings and the separate optional verification pass; the product makes no fixed-minute runtime promise because timing varies with the display, meter mode, prompts, and measurement conditions.
- Guided setup gates hardware progression on coherent engine discovery, an identified and explicitly confirmed display mapping, a selected i1D3-family meter, and acknowledged correction compatibility. Preparation separately requires warm-up, stable lighting, disabled dynamic display features, and intended monitor controls.
- A setup may remember mapping, meter, correction, target, effort, and profile model by display fingerprint after a run starts. A restored mapping is only a suggestion: identification and explicit mapping confirmation reset for each later run.
- Generated profiles remain incomplete until tool success and artifact validation agree.
- A completed calibration run leaves its generated ICC profile as an inactive session artifact; installation, activation, and verification require a separate explicit operator confirmation.
- Explicit activation recomputes the candidate ICC SHA-256 and refuses a missing or changed artifact before any installation mutation.
- The result and history views present the profile active when the run began as **Before** and the generated candidate as **After**. Those profile cards describe session associations and activation history, not measured improvement.
- The optional **Measure White** setup action presents an opaque RGB-white surface on the confirmed physical display before triggering the meter, retains it through the read, exposes edge cancellation, and persists one pre-calibration white-patch reading. The measured comparison pairs its luminance, xy, estimated CCT, and capture time with the white result from the later post-activation verification pass. It is deliberately labeled **Before setup reading** versus **After verification** and is not represented as equivalent full before/after color-accuracy sampling.
- Verification is a distinct measured stage, not inferred from profile generation success.
- Verification compares normalized measured white to a fixed target under an explicit D50/no-adaptation assumption; CCT is guidance, and tone RMS is evaluated against the selected transfer function.

## Safety and recovery

- The app runs without root privileges and installs profiles at user scope only after explicit confirmation.
- Generation does not change the ColorSync profile association. Because Argyll temporarily loads the run's calibration into the selected display VideoLUT for measurement, a generation-only terminal path asks Argyll to reload calibration from the currently associated profile.
- The previously active profile is captured before any explicit activation.
- Activation checks the selected display identity, candidate validity, and unchanged Before association, then confirms the resulting ColorSync association by readback before verification measurements begin.
- Failure or cancellation after activation attempts idempotent restoration of the previous association and calibration for the same display fingerprint.
- Sessions persist terminal failure/cancellation honestly and retain diagnostics for recovery.
- The latest explicit activation-and-verification attempt is a durable record separate from profile-generation completion. It journals in-progress, verified, failed, or cancelled status; activation/verification timestamps; the error; and a tri-state Before-restored result. A failed rollback remains unconfirmed rather than being reported as restored.
- A session left in a live stage by process or Mac termination becomes **Interrupted** on relaunch and exposes explicit generation-only or post-activation Restore Before recovery. Any nonterminal or unreadable session fails closed until its recovery state can be reconciled.
- One app-owned model and one main window own operation state. Engine reload/removal controls are locked during measurement, calibration, activation, restoration, or hardware refresh, and engine probe plus discovery is one serialized transaction. Quit and last-window close cancel ordinary active work safely; an in-progress Restore Before is allowed to finish. Restore Before persists `restorationRequired` before changing ColorSync or VideoLUT state. Failed or unfinished protected cleanup is tracked per session, reconstructed on relaunch, blocks new profile-changing work and Quit, and clears for each affected session only after its explicit Restore Before succeeds.
- Process activity prevents idle system/display sleep during measurements and profile operations. macOS can still force or honor user/lid sleep; will-sleep requests cancellation and did-wake repeats cancellation or resumes restoration, while durable recovery records remain the fallback. The product does not claim guaranteed rollback before forced sleep.
- Durable session writes use replacement semantics so an interrupted write cannot masquerade as a valid session.

## Local data and privacy

- Calibration measurements, artifacts, session JSON/event logs, raw Argyll diagnostics, and app-managed correction copies stay under the current user's local account; the application contains no calibration-data upload path or account requirement.
- Sessions and corrections default to `~/Library/Application Support/LumaProfile`. A candidate is copied to `~/Library/ColorSync/Profiles/LumaProfile` only during explicit activation.
- Settings exposes **Reveal Local Data**. Recovery-relevant interrupted or installed sessions are protected from in-app deletion until their state is resolved.
- Clipboard diagnostics deliberately omit raw measurements and abbreviate the user's home path. History's explicit **Export Report…** save writes a privacy-reduced plain-text summary with setup/After results, durable activation/restoration outcome, rating criteria/reasons, and artifact filenames; it excludes raw logs/Argyll output, meter serials, hashes, and absolute home paths. Raw session folders remain the technical source of truth.

## Validation policy

- Automated tests require neither ArgyllCMS nor hardware.
- Argyll-like fixtures are recorded-looking synthetic data and are labeled as such.
- Color math uses published known-answer vectors where available.
- Live USB, patch display, generation-only VideoLUT restoration, ICC activation, and rollback require the separate manual hardware checklist.
- No live-hardware acceptance result is claimed until evidence from that checklist exists.

## Repository and release discipline

- GitHub CI runs the repository-owned Swift build/test command plus plist, project metadata, shared-scheme, shell syntax, and release-revision guard validation on macOS.
- The stable application bundle identifier is `com.lumaprofile.app` in both the checked-in package plist and Xcode target configurations.
- Release metadata validation requires the custom `AppIcon.icns` declaration, a valid icon container, and matching Xcode target settings; visual icon behavior remains a manual packaging check.
- `Scripts/package-dmg.sh` remains the ad-hoc-signed, non-notarized local/test packager and intentionally does not require a Git commit or tag.
- `Scripts/package-github-release.sh` is the only documented public portfolio packaging entry point. It requires a clean worktree at exact tag `v<version>`, requires version/build metadata to match, and records the full source commit in a plist embedded in the app, copied onto the DMG, and emitted beside the DMG.
- The release guard does not publish, sign with Developer ID, notarize, staple, or make a Gatekeeper claim. Those actions remain a separately reviewed external gate with nested-code, hardened-runtime, credential, notarization, and clean-machine acceptance requirements.
- No GitHub release, notarized artifact, or broad live-hardware acceptance is implied by the existence of the packaging and CI paths.
- Public artifacts must retain their exact corresponding source tag and the AGPLv3 source/license payload for as long as the binary is distributed.
