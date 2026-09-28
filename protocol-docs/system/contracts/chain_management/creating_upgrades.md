# Creating an upgrade

Upgrade authors use the scripts under `l1-contracts/deploy-scripts/upgrade/` to deploy implementations,
construct the CTM and diamond calldata, and generate the governance stages for a release. The generated
artifacts must match the verifier, bootloader/system-contract bytecode hashes, facet cuts, protocol
version, and any one-time storage migrations described by that release.

The protocol-level sequence is defined in [the upgrade process](./upgrade_process.md). The pipeline
that turns a release into deployed contracts, verified calldata, a governance ceremony and per-chain
upgrades, and the layout of the scripts a release adds, is described in
{protocol-docs/ecosystem-upgrade.md}. Command-level instructions live with the tooling
(`protocol-ops/README.md`, `l1-contracts/deploy-scripts/upgrade/README.md`) so they evolve with it
rather than being duplicated here.
