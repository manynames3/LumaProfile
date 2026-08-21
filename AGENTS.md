# Repository guidance

## Architecture

- Keep this a Swift 6 package with the `LumaCore` library and `LumaProfileApp` executable.
- Put calibration/domain/process logic in `LumaCore`; keep AppKit/SwiftUI presentation in `LumaProfileApp`.
- Target macOS 15 and Apple Silicon. Do not add compatibility shims for other platforms unless the product scope changes.
- Release builds bundle the pinned, unmodified ArgyllCMS 3.5.0 macOS ARM64 distribution. Development builds may use an explicit external directory, but the installed product must remain one self-contained app.

## Safety and privacy

- Never require or invoke the app as root. User-level profile installation is the default.
- Treat display selection, instrument selection, and profile activation as explicit user choices.
- Preserve the previously active profile before activation and make rollback idempotent.
- On cancellation, terminate child processes, persist an honest interrupted/cancelled state, and do not present partial artifacts as complete.
- Keep measurement data and session logs local unless a future feature explicitly obtains consent to export them.

## Argyll integration

- Prefer the coherent ArgyllCMS distribution inside the application resources; explicit developer configuration remains an intentional override.
- Resolve one coherent Argyll `bin` directory; do not mix tools from different installations.
- Build process requests as executable URLs plus argument arrays. Do not construct shell command strings.
- Drain stdout and stderr concurrently, preserve raw diagnostic output, check exit status, and propagate cancellation.
- Parsers must tolerate CR/LF differences, chunk boundaries, unknown informational lines, and truncated output. Unknown interactive prompts must stop safely instead of receiving a guessed response.
- Imported CCSS/CCMX corrections retain provenance and are copied into app-managed storage; never silently substitute a correction.

## Release compliance

- LumaProfile uses the AGPLv3 public-source distribution route. A public binary release must have its exact corresponding LumaProfile source available from the public GitHub revision released with it.
- Fetch only the pinned official ArgyllCMS binary and matching source archives named in `ThirdParty/ArgyllCMS/SHA256SUMS`. A size or digest mismatch is a hard failure.
- Preserve every file and embedded signature in the full upstream binary distribution. Sign the enclosing app; do not rewrite or re-sign the Argyll executables.
- Include exact allowlisted LumaProfile corresponding source, the matching ArgyllCMS source archive, LumaProfile license, third-party notices, upstream Argyll license/readme, and checksum manifest with every DMG.
- The current packager intentionally produces an ad-hoc-signed, non-notarized local/portfolio DMG and must label it accurately. Developer ID/notarization is a future hardening task requiring a dedicated nested-tool signing and bundle-layout workflow; do not bolt notarization onto the byte-preserving script.

## Tests and fixtures

- Prefer deterministic unit tests and protocol fakes. Tests must not require ArgyllCMS, a colorimeter, profile activation, network access, or administrator privileges.
- Every Argyll-like fixture in `Tests/LumaCoreTests/Fixtures` is synthetic and must stay clearly labeled. Do not describe it as captured hardware output.
- Add a regression fixture before loosening a parser for a new transcript shape.
- Live-device behavior is verified only with the manual hardware checklist and must not be claimed until that checklist has actually been run.
- Run `swift test` after relevant changes. Keep production dependencies unchanged unless the user approves a new one. Packaging validation may use the pinned downloaded archives but must not require hardware.

## Documentation

- Keep `README.md` useful to a first-time operator and `PROJECT_STATE.md` limited to durable decisions.
- Document safety limitations plainly, especially external-tool licensing, untested hardware paths, profile rollback, and macOS permissions.
