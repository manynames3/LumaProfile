## Summary

Describe the user-visible outcome and the smallest relevant implementation details.

## Verification

- [ ] `Scripts/ci/verify.sh` passes.
- [ ] New parser behavior has a clearly synthetic regression fixture.
- [ ] No test requires hardware, administrator access, profile activation, or network access.
- [ ] User-facing documentation was updated when behavior changed.

## Safety and release review

- [ ] Display, meter, activation, and rollback choices remain explicit.
- [ ] Cancellation and failure paths do not promote partial artifacts.
- [ ] No personal paths, meter serials, session data, credentials, or downloaded vendor archives were committed.
- [ ] ArgyllCMS executables remain unmodified and release/license obligations remain intact.
- [ ] Live-device claims are limited to recorded manual-checklist evidence.
