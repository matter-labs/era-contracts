# v0.34.0 (registry-driven upgrades) — upgrade inputs

Per-environment upgrade-input TOMLs for the v34 release land here when the release is cut
(`local.toml` is the local-anvil-fixture default the protocol-ops CLI falls back to; it is
inherited from the previous release's local fixture — the anvil harnesses pass their own
inputs and never read it).
