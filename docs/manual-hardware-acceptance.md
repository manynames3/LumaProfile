# Manual hardware acceptance

Status: **not executed by the repository's automated validation**.

Use this checklist only on a non-critical Apple Silicon Mac running macOS 15 or later. Profile generation must preserve the active ColorSync association, but Argyll temporarily changes the selected display's VideoLUT while measuring. The optional explicit-activation portion does change the active profile. Keep ColorSync Utility available and know how to restore the current profile before beginning.

## Evidence header

- Date/time and operator:
- Mac model and macOS build:
- LumaProfile revision/build:
- ArgyllCMS version and installation path:
- Display make/model, connection, serial/fingerprint, resolution, refresh rate, and picture mode:
- Meter make/model, serial, firmware, and measurement mode:
- Correction name, checksum, source, and declared display/instrument (or “none”):
- Measurement effort and expected characterization patch count:
- Actual characterization patch count from the generated `.ti1`:
- Previously active ICC profile:
- Ambient-light conditions and warm-up time:
- Exported report filename (if tested):

Do not paste personal home-directory paths or unrelated USB serial numbers into public evidence.

## Preflight and safety

- [ ] The app launches without `sudo` and requests no administrator password.
- [ ] Finder, the Dock after launch, and **About & Licenses** show the custom LumaProfile icon rather than a generic executable icon.
- [ ] The installed app reports the bundled ArgyllCMS 3.5.0 tool set ready without a separate Argyll installation or `PATH` change.
- [ ] The calibration page presents the four setup steps in order: **Display & Meter**, **Target & Speed**, **Prepare**, and **Review**. Required steps cannot be bypassed with Continue or Start.
- [ ] True Tone, Night Shift, automatic brightness, screen dimming, and sleep are disabled for the run.
- [ ] One directly attached, non-mirrored physical display is selected and its fingerprint remains stable across an app relaunch.
- [ ] Adding, removing, moving, or reordering a display after confirmation causes the next indexed Argyll operation to stop before displaying patches or changing a VideoLUT.
- [ ] The reported Argyll version and every required executable come from one expected `bin` directory.
- [ ] With no meter attached, discovery reports an actionable empty state and does not crash.
- [ ] With the meter attached, its model/serial (when available) and capabilities are plausible.
- [ ] Unplugging and reconnecting the i1D3-family meter changes discovery state after **Refresh Meters**; starting a run rechecks that the selected meter is still available.
- [ ] A second application holding the meter produces a safe, actionable failure; no guessed prompt response is sent.
- [ ] After one run has started, revisiting the same display restores the remembered meter, correction, target, effort, profile model, and only a still-matching engine mapping suggestion; physical identification and mapping confirmation are required again.

## Measurement and calibration

- [ ] Spot measurement waits for explicit placement/continue input and produces plausible XYZ, xy, luminance, and warnings.
- [ ] Cancelling at a placement prompt reaches a terminal cancelled state and leaves no complete artifact.
- [ ] **Measure Once** is optional and presents an opaque RGB-white surface on the confirmed physical display before the meter is triggered. It remains visible through the read, **Cancel Reading** closes it promptly, plausible brightness/white-point guidance follows, and exactly one timestamped setup reading persists; skipping it does not invent a Before reading or block calibration.
- [ ] **Adjust Live** keeps the white surface up, updates the bottom-edge gauge after each reading, tracks changes made with the monitor's brightness control, and **Done** closes it promptly while keeping the last completed reading as the Before setup reading.
- [ ] Measurement effort presents Quick as the default, shortest, explicitly lower-detail 119-patch choice; Balanced as the recommended 220-patch choice; Detailed as the longer, more-detailed 478-patch choice; and Reference as the longest Expert choice at 1,024 patches.
- [ ] The generated characterization `.ti1` count matches the selected effort and retained session evidence. The UI identifies this as the characterization count, excludes calibration and optional verification readings, and does not promise a fixed number of minutes.
- [ ] The patch window appears only on the selected display, at the requested geometry, without unrelated UI covering it.
- [ ] Calibration progress is monotonic; stdout and stderr diagnostics remain available.
- [ ] Disconnecting the meter mid-run reaches a terminal failure with an incomplete artifact and a recoverable session.
- [ ] A full calibration and characterization completes without display-mode changes or sleep.

## Profile and verification

- [ ] The ICC artifact opens in ColorSync Utility and its displayed description/model match the request.
- [ ] Completing profile generation does not install or activate the candidate, and the selected display's ColorSync profile association is unchanged from the evidence header.
- [ ] The result screen shows **Before** as the profile captured at the start and **After** as the generated candidate, with the latter clearly labeled **Generated; not currently activated by this session**.
- [ ] The same Before/After identities remain attached to the session after relaunch; neither label claims measured improvement before verification.
- [ ] Before explicit activation, **Before setup reading** shows only the optional single white reading (or clearly says it was not captured), while **After verification** says it is available only after **Activate & Verify**.
- [ ] After verification, the measured comparison shows luminance, xy, and estimated CCT and explicitly says it compares brightness/white point only—not equivalent full pre/post patch sets or full pre-calibration color accuracy.
- [ ] Generation-only completion reloads the previously active profile's calibration into the selected display VideoLUT and does not modify another display.
- [ ] No installation or verification begins until the operator uses the explicit activation action and confirms the selected display, current profile, and generated candidate.
- [ ] After confirmation, installation changes only the selected display, records both installed and previous profile URLs, and confirms the candidate association with a ColorSync readback before measurement verification begins.
- [ ] Verification performs new measurements after activation and reports average, 95th percentile, maximum, white-point, luminance, and gamma results or explicit unavailable fields.
- [ ] Reported values are consistent with the retained raw output within documented rounding.
- [ ] A successful attempt persists **Verified**, activation/verification/finish timestamps, and **Before restored: No — After remains active**. Relaunching loads that outcome and the same artifact identities without treating the historical record as a fresh active-profile readback.
- [ ] In History, **Export Report…** writes a user-selected plain-text file containing setup/After results, activation/restoration outcome, rating version/reasons, and artifact filenames. Confirm that it contains no raw log/Argyll transcript, meter serial, file hash, or absolute home-directory path.
- [ ] An older session without the new durable fields or rating data is labeled as historical/not recorded in the exported report rather than receiving a guessed outcome.

## Before / After comparison

- [ ] After a verified activation, the **Before | After** switch changes only the selected display between the two recorded profiles, ColorSync readback matches each choice, and the reference strip visibly changes.
- [ ] While Before is showing, starting another calibration, activation, Restore Before, or Quit first returns the display to After.
- [ ] The switch is unavailable for sessions that are not currently recorded as activated, and it refuses to act when the display is on a third profile.

## Rollback fault injection

Perform these checks with a deliberately disposable test profile, never the only known-good profile.

- [ ] Cancelling or forcing a failure before explicit activation leaves the ColorSync association unchanged and restores the selected display's previous calibration.
- [ ] Force-quitting during generation produces an **Interrupted** session on relaunch; after the same display mapping is available, **Restore Before** reloads calibration without installing or activating the candidate.
- [ ] Cancelling after installation reactivates the recorded previous profile for the same display.
- [ ] A forced verification failure after installation triggers the same rollback.
- [ ] A failed or cancelled activation attempt persists its finish time, error, and whether Before restoration was confirmed; an unconfirmed rollback is displayed as recovery still required rather than success.
- [ ] Repeating rollback is harmless, and a later successful **Restore Before** updates the durable record with confirmed restoration and its time.
- [ ] Relaunch reconstructs recovery-required state from interrupted sessions. If two sessions require recovery, successfully restoring one does not unlock calibration, activation, or Quit until the other session is also restored.
- [ ] A deliberately unreadable saved session and a failed initial recovery audit both keep calibration and activation unavailable; repairing/removing the unreadable test record and rerunning the audit clears only that fail-closed condition.
- [ ] Force-quit after **Restore Before** begins but before it completes; relaunch still reports restoration required because the recovery marker was saved before ColorSync or VideoLUT changed.
- [ ] Generation-only restoration and post-activation rollback cannot apply a previous profile or calibration to a different display fingerprint after disconnecting or reordering displays.
- [ ] After terminating the app during post-install verification, the session supports manual recovery and clearly names the previous profile.
- [ ] Engine override, measurement-mode save, and correction removal controls are unavailable during measurement, calibration, activation, or Restore Before; they cannot replace the engine that owns an active child process.
- [ ] Quit or closing the only window during measurement/calibration requests safe cancellation. During Restore Before it waits for completion; if restoration fails or does not finish within the bounded wait, Quit is cancelled, new calibration/activation remains blocked, and only a later successful Restore Before clears the recovery warning.
- [ ] Idle sleep is suppressed during active work. Forced lid/user sleep is tested separately: after wake, cancellation/restoration resumes, and any session whose restoration was not confirmed remains **Interrupted** with explicit recovery rather than being reported as safe.
- [ ] Manual restoration in ColorSync Utility succeeds.

## Result

- Outcome: PASS / FAIL / BLOCKED
- Failed checklist item(s):
- Session identifier and sanitized log location:
- Generated profile checksum:
- Screenshots/log excerpts:
- Follow-up issue(s):

An incomplete or blocked checklist is not a pass. Never generalize one display/meter combination to other hardware.
