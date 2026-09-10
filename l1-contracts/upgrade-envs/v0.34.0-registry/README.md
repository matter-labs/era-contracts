# v0.34.0 (registry-driven upgrades) — upgrade inputs

Per-environment upgrade-input TOMLs for the v34 release land here when the release is cut
(`local.toml` is the local-anvil-fixture default the protocol-ops CLI falls back to; it is
inherited from the previous release's local fixture — the anvil harnesses pass their own
inputs and never read it).

`stage.toml` and `mainnet.toml` are the release scaffolds the protocol-ops CLI (`EnvConfig`) and
its tests read: ecosystem identities carried forward from `v0.31.0-interopB`, fresh CREATE2 salts
for this release (a core salt plus one per CTM), and the v34 version schedule. Revalidate every
value at the release cut; the departing version is informational because the prepare reads it
from the live CTM.
