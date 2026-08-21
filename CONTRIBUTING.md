# Contributing to LumaProfile

LumaProfile welcomes focused bug fixes, tests, documentation, and narrowly scoped product improvements. Changes must preserve the safety boundary around physical display selection, meter input, ColorSync activation, and rollback.

## Development setup

Use an Apple Silicon Mac with macOS 15 and a Swift 6/Xcode 16-compatible toolchain. From the repository root:

```sh
Scripts/ci/verify.sh
```

The automated suite is intentionally hardware-free. It must not activate profiles, require administrator privileges, download vendor files, or depend on a connected meter. Argyll-like transcripts in tests are synthetic fixtures, never captured-device evidence.

## Pull requests

Keep each pull request reviewable and limited to one outcome. Explain user impact, failure behavior, and the verification performed. Add deterministic tests for domain, parser, workflow, persistence, or process changes. If a parser must accept a new transcript shape, first add a minimal redacted fixture that is visibly labeled synthetic.

Run `Scripts/ci/verify.sh` before requesting review. A passing automated suite does not establish live hardware compatibility; use `docs/manual-hardware-acceptance.md` for that separate evidence and report only what the completed checklist demonstrates.

## Safety and privacy

- Never require or invoke LumaProfile as root.
- Keep display selection, meter selection, profile activation, and restoration explicit.
- Preserve the previous profile and fail closed when display or prompt identity is uncertain.
- Do not commit session folders, real measurements, personal filesystem paths, hardware serial numbers, credentials, downloaded Argyll archives, build products, or signing material.
- Do not rewrite, thin, re-sign, or otherwise modify bundled ArgyllCMS executables in the current byte-preserving portfolio workflow.

## Release-affecting changes

Read `docs/release-checklist.md` before changing versions, identifiers, packaging, licenses, checksums, or GitHub release material. Public binaries must remain tied to their exact public source tag under the documented AGPLv3 route. Developer ID signing and notarization are a separate, currently unimplemented external release gate.
