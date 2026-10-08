# Creating an upgrade

Upgrade authors use the scripts under `l1-contracts/deploy-scripts/upgrade/` to deploy implementations,
construct the CTM and diamond calldata, and generate the governance stages for a release. The generated
artifacts must match the verifier, bootloader/system-contract bytecode hashes, facet cuts, protocol
version, and any one-time storage migrations described by that release.

The protocol-level sequence is defined in [the upgrade process](./upgrade_process.md). Operational
instructions, configuration fields, and local simulation commands live with the upgrade scripts in
`l1-contracts/deploy-scripts/upgrade/README.md`, so they evolve with the tooling rather than being
duplicated here.
