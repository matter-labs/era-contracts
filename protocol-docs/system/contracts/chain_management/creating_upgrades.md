# Creating an upgrade

Upgrade authors use the scripts under `l1-contracts/deploy-scripts/upgrade/` to deploy
implementations and the write-once objects of a release (the `CTMRelease`, the `CTMTransition`, and
a `ProxyUpgradeTransition` for each domain whose proxies change); the governance calls that apply
them — one executor call per object, in a fixed order — are derived from those objects, and any
other call is a declared external action. The deployed objects must match the verifier,
bootloader/system-contract bytecode hashes, facet set, protocol version, and any one-time migrations
described by that release; the facet cuts
and the L2 upgrade transaction are derived from the objects rather than authored, and the package is
checked by re-deriving every object's address from reviewed code (see "Provenance and validation" in
[Registry-driven protocol upgrades](../../../../docs/registry-driven-upgrades.md#provenance-and-validation)).

The protocol-level sequence is defined in [the upgrade process](./upgrade_process.md). The pipeline
that turns a release into deployed contracts, a verified package, the governance call and per-chain
upgrades, and the layout of the scripts a release adds, is described in
[Upgrading an ecosystem](../../../ecosystem-upgrade.md). Command-level instructions live with the tooling
(`protocol-ops/README.md`, `l1-contracts/deploy-scripts/upgrade/README.md`) so they evolve with it
rather than being duplicated here.
