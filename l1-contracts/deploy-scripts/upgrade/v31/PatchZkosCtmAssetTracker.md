# Patch the ZKsync OS CTM upgrade for the `L2AssetTracker` bytecode change (PR #2224)

[PR #2224](https://github.com/matter-labs/era-contracts/pull/2224) changes the
`L2AssetTracker` bytecode (and, transitively, the bytecode of a handful of other
contracts — see the diff in `AllContractsHashes.json`). The v31 upgrade for
ZKsync OS chains had already been prepared, so its **chain-creation params** and
**upgrade data** embed the _old_ `L2AssetTracker` (and `L2V31Upgrade`) bytecode
descriptors.

The original proposal has **already executed on L1**, so rewriting the prepared
`ecosystem.toml` is pointless. Instead these two scripts emit a **new, dedicated
patch proposal** — the regenerated CTM data plus the `ChainTypeManager` calls
that apply it — for the **ZKsync OS chain type manager (CTM) only**, without
redeploying or changing any facets. The output is written to a separate file:
`upgrade-envs/v0.31.0-interopB/output/stage/zkos-asset-tracker-patch.toml`.

## What is patched

Inside the `[ctms.zksync_os]` section of a prepared upgrade output (e.g.
`upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml`):

| Key                                       | Role                  | Contains                                                         |
| ----------------------------------------- | --------------------- | ---------------------------------------------------------------- |
| `contracts_config.force_deployments_data` | chain-creation params | `FixedForceDeploymentsData` (incl. `assetTrackerBytecodeInfo`)   |
| `chain_upgrade_diamond_cut`               | upgrade data          | the upgrade `DiamondCutData` → `ProposedUpgrade` → L2 upgrade tx |
| `contracts_config.diamond_cut_data`       | chain-creation params | left **unchanged** (it embeds no bytecode descriptor)            |

### Which contracts are actually affected

The scripts do **not** hard-code a contract list. Forge reconstructs the data
from scratch from the real artifacts, and the TypeScript verifier enumerates
every contract whose descriptor is embedded (all ten `FixedForceDeploymentsData`
slots + the v31 delegate) and updates any whose embedded descriptor differs from
`AllContractsHashes.json`. On the current stage env this resolves to exactly two
contracts:

- **`L2AssetTracker`** — force-deployed via `FixedForceDeploymentsData.assetTrackerBytecodeInfo`.
  Appears in `force_deployments_data` and (twice) in `chain_upgrade_diamond_cut`
  (the asset-tracker system-proxy force deployment + the force-deployments data
  embedded in the L2 upgrade calldata), plus once as a `factoryDeps` entry.
- **`L2V31Upgrade`** — the upgrade delegate, force-deployed via the single
  `ZKsyncOSUnsafeForceDeployment` entry. Its descriptor also determines the
  `delegateTo` address (`generateRandomAddress(descriptor)`), which is therefore
  recomputed.

The other contracts whose bytecode changed in the PR (`L2ComplexUpgrader`,
`L2GenesisUpgrade`, `L2GenesisForceDeploymentsHelper`,
`L2V30TestnetSystemProxiesUpgrade`) are genesis-only: they run during chain
genesis and are baked into the off-chain-computed `genesisRoot` /
`genesisBatchCommitment`, not embedded as bytecode descriptors in the CTM
chain-creation params or upgrade data. They are **not** in the ZKsync OS force
deployments (`SystemContractsProcessing.getBaseZKsyncOSForceDeployments` /
`getFixedAddressCoreContracts`) nor in the upgrade `factoryDeps`, so there is
nothing to patch for them here. This is proven, not assumed: because the forge
script rebuilds the data from scratch and its output is byte-identical to the
TypeScript byte-patch (which only touches the differing descriptors), any
contract referenced by the data that had changed would have made the two outputs
diverge. The TypeScript completeness check additionally asserts that **every**
bytecode reference in the patched data resolves to a hash present in
`AllContractsHashes.json`, so a missed contract would fail loudly.

A ZKsync OS bytecode descriptor is `abi.encode(bytes32 blake2s, uint32 length,
bytes32 keccak256)` (see `contracts/common/libraries/ZKSyncOSBytecodeInfo.sol`).
Because the descriptor is a fixed 96 bytes, rewriting it never shifts any ABI
offset, so the patch is a layout-preserving in-place substitution.

## The two scripts

### 1. Forge — `PatchZkosCtmAssetTracker.s.sol` (bytecode-based, from scratch)

Inspired by the CTM upgrade scripts (`CTMUpgrade_v31`). It **reconstructs the
CTM data from scratch** out of the real compiled artifacts, using the same code
paths as the real upgrade:

1. `force_deployments_data` is rebuilt as a fresh `FixedForceDeploymentsData`:
   the non-bytecode config (chain ids, addresses, `zkTokenAssetId`, …) is taken
   from the prepared output, and **every** bytecode descriptor is recomputed from
   `out/` via `CoreOnGatewayHelper.resolve` + `Utils.getZKOSProxyUpgradeBytecodeInfo`
   (exactly as `DeployCTM._buildForceDeploymentsData`);
2. `chain_upgrade_diamond_cut`'s L2 transaction is rebuilt from
   `SystemContractsProcessing.getBaseZKsyncOSForceDeployments()` + the v31 unsafe
   delegate + `CoreOnGatewayHelper.getFullListOfFactoryDependencies()` (the
   `factoryDeps`), mirroring `CTMUpgrade_v31`. The facet cuts, init address and
   every non-bytecode scalar field are kept from the prepared output — **facets
   are not changed**;
3. it **sends the message to the bytecode supplier** —
   `BytecodesSupplier.publishEVMBytecodes` for the changed bytecodes (broadcast
   only with `BROADCAST=true`);
4. it **generates the `ChainTypeManager` calls** that apply the patch (see
   [below](#the-generated-calls)) and writes the whole patch proposal —
   regenerated data + calls — to
   `upgrade-envs/v0.31.0-interopB/output/stage/zkos-asset-tracker-patch.toml`.

Because it reconstructs from the live force-deployment / factory-dep builders,
any affected contract is picked up automatically — there is no hard-coded list.

```bash
cd l1-contracts
# Build with the SAME toolchain that produced AllContractsHashes.json:
#   foundryup-zksync -i 0.1.5
forge build
forge script deploy-scripts/upgrade/v31/PatchZkosCtmAssetTracker.s.sol --ffi --sig "run()"
```

> The `--ffi` flag is required for the Blake2s256 helper. The build **must** use
> foundry-zksync `v0.1.5` (commit `807f47ace`, see `recompute_hashes.sh`);
> a different toolchain emits different solc metadata and the deployed-bytecode
> hashes would not match `AllContractsHashes.json`.

### 2. TypeScript — `scripts/patch-zkos-ctm-asset-tracker.ts` (hashes-only, on-chain verifier)

**Checks** the proposal the forge script produced — it does not regenerate it,
**never touches bytecode**, and **does not trust the prepared ecosystem outputs
for data**. It:

1. reads ONLY the ZKsync OS CTM address from the ecosystem output, then pulls the
   _original_ chain-creation params / upgrade cut straight from the CTM's own
   on-chain events (`NewChainCreationParams`, `NewUpgradeCutData`,
   `NewProtocolVersion` — scanned backwards in 10k-block windows);
2. enumerates every embedded descriptor of those on-chain originals (the ten
   `FixedForceDeploymentsData` slots + the v31 delegate), compares each to
   `AllContractsHashes.json`, and — via a high-level byte substitution (take every
   substring that should have changed and replace it) — asserts the proposal's
   `force_deployments_data` / `chain_upgrade_diamond_cut` are the on-chain
   originals with **only** those descriptors swapped (and `diamond_cut_data`
   byte-identical to on-chain);
3. asserts the `ChainTypeManager` calls are correctly constructed:
   `setChainCreationParams` carries the on-chain params with only
   `forceDeploymentsData` swapped, `setUpgradeDiamondCut` carries the patched cut
   at the on-chain old protocol version, both target the CTM, and
   `governance_calls` bundles exactly those two.

```bash
cd l1-contracts
L1_RPC=$TENDERLY_SEPOLIA npx ts-node scripts/patch-zkos-ctm-asset-tracker.ts
```

Environment overrides: `L1_RPC` (or `TENDERLY_SEPOLIA`), `ECOSYSTEM_TOML` (CTM
address only), `HASHES_JSON`, `PATCH_TOML`.

## The generated calls

The patch is applied by a new governance proposal that calls the
`ChainTypeManager` (the original proposal already advanced the on-chain protocol
version, so it must not be re-run). The forge script emits — and the TypeScript
verifier checks — in the same `Call` / `abi.encode(Call[])` format the CTM
upgrade scripts use:

| Call                                 | Method                                                     | Fixes                                |
| ------------------------------------ | ---------------------------------------------------------- | ------------------------------------ |
| `set_chain_creation_params_calldata` | `setChainCreationParams(ChainCreationParams)`              | chain-creation params for new chains |
| `set_upgrade_diamond_cut_calldata`   | `setUpgradeDiamondCut(DiamondCutData, oldProtocolVersion)` | the stored upgrade cut (old → v31)   |

plus the permissionless `publish_bytecodes_calldata`
(`BytecodesSupplier.publishEVMBytecodes`) that publishes the new bytecodes, and a
`governance_calls` blob = `abi.encode([setChainCreationParams, setUpgradeDiamondCut])`.

> **Why `setUpgradeDiamondCut`, not `setNewVersionUpgrade`?** The original
> `provideSetNewVersionUpgradeCall` calls `setNewVersionUpgrade`, which requires
> the CTM's current `protocolVersion` to equal the supplied `_oldProtocolVersion`
> and then advances it. Since the original proposal already advanced the version
> to v31, re-running it would revert with `OutdatedProtocolVersion`.
> `setUpgradeDiamondCut(cutData, oldProtocolVersion)` rewrites
> `upgradeCutHash[oldProtocolVersion]` in place without touching the version — the
> correct primitive for patching an already-applied upgrade.

In the forge script, `ChainCreationParams` reuses the prepared diamond cut
verbatim (facets unchanged) and the ZKsyncOS genesis fields from
`configs/genesis/zksync-os/latest.json` (`genesisRoot`, unit batch commitment,
zero repeated-storage index — matching `ChainCreationParamsLib`), swapping in only
the regenerated `forceDeploymentsData`. The TypeScript verifier independently
confirms those same fields against the on-chain `NewChainCreationParams` event.

## How the two scripts corroborate each other

The forge script reconstructs the proposal from the **real compiled bytecode**;
the TypeScript verifier independently checks it against the **on-chain CTM state**
(the original data, via events) using **only `AllContractsHashes.json`** for the
new hashes. They share no inputs other than the hashes file and the CTM address,
so a green verifier proves the proposal touches nothing but the changed bytecode
descriptors, references only current hashes, and wires up the `ChainTypeManager`
calls correctly. Reproduce + verify end-to-end with:

```bash
cd l1-contracts
# requires foundry-zksync v0.1.5 on PATH and L1_RPC / TENDERLY_SEPOLIA set
./scripts/patch-zkos-ctm-asset-tracker.reproduce.sh               # build, generate, verify
SKIP_BUILD=1 ./scripts/patch-zkos-ctm-asset-tracker.reproduce.sh  # reuse artifacts
```
