# Contracts CI Security Review Focus

Applies to CI workflows, build scripts, dependencies, and release automation.

- Keep untrusted changes from accessing credentials, gaining write permissions, or compromising build environments.
- Verify dependency and artifact origins, pinned revisions, and integrity before use.
- Prevent command injection and unsafe handling of paths or workflow inputs.
- Publish the intended revision and artifacts; keep secrets out of logs and outputs.
- Preserve approval boundaries and fail accurately when security checks are incomplete.

Report concrete security impact rather than hardening-only suggestions.
