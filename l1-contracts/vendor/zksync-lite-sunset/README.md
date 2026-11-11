# ZKsync Lite sunset claim distributor (vendored)

`src/ZkSyncLiteSunsetClaimDistributorL1.sol` is an unchanged copy of the audited Merkle claim distributor used for the
ZKsync Lite sunset. It is the distributor used for chain shutdowns (see `L1AssetTracker.setShutdownDistributor`).

- Upstream: `matter-labs/zksync-lite-sunset` (private), commit `b7ab9f88`,
  path `contracts/zksync-lite-migration-claims/src/ZkSyncLiteSunsetClaimDistributorL1.sol`.
- `foundry.toml` uses the upstream compiler settings (solc 0.8.24, via-IR, 200 runs, `paris`), and the remappings point
  to the same OpenZeppelin commits as upstream (`openzeppelin-contracts-upgradeable` v4.9.6 `2d081f24`,
  `openzeppelin-contracts` `dc44c9f1`).
- `src.sha256` pins the file's hash. `yarn build:shutdown-distributor` in `l1-contracts` (run by `yarn test:foundry`) checks the hash and then builds.

The upstream repository is private, so it cannot be added as a submodule of this public repository. Do not edit the
source here; any change must go through upstream and its audit first.
