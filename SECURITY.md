# Security policy

## Reporting a vulnerability

Do not disclose a suspected vulnerability, private calibration data, meter serial number, personal path, credential, or working exploit in a public issue.

Use **Security → Report a vulnerability** in the GitHub repository when private vulnerability reporting is available. If that option is unavailable, open a public issue containing only a request for a private maintainer contact channel; do not include security-sensitive details in that issue.

Include the affected LumaProfile version and release commit, macOS version, impact, reproduction conditions, and the smallest sanitized supporting evidence. State whether the issue could change a display profile, prevent rollback, execute an unexpected process, expose local session data, or alter bundled ArgyllCMS files.

No response-time or remediation-time guarantee is currently offered. Please allow maintainers an opportunity to reproduce and address the issue before public disclosure.

## Supported versions

This showcase project supports only the latest source revision and any release explicitly marked current on GitHub. Older portfolio artifacts may be withdrawn rather than patched. The current local/portfolio DMG is ad-hoc signed and is not notarized or Gatekeeper-approved; that limitation is a distribution-trust boundary, not a security certification.

## Scope

Security reports may cover LumaProfile source, session/privacy handling, process invocation, profile activation and rollback, packaging integrity, or the boundary around bundled ArgyllCMS. Upstream ArgyllCMS vulnerabilities should also be reported to its upstream maintainers through their published process. Do not send real measurement sessions unless a maintainer explicitly requests a private, sanitized reproduction.
