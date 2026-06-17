# Patch the ZKsync OS CTM upgrade for the `L2AssetTracker` bytecode change (PR #2224)

[PR #2224](https://github.com/matter-labs/era-contracts/pull/2224) changes the
`L2AssetTracker` bytecode (and, transitively, the bytecode of a handful of other
contracts — see the diff in `AllContractsHashes.json`). The v31 upgrade for
ZKsync OS chains had already been prepared, so its **chain-creation params** and
**upgrade data** embed the _old_ `L2AssetTracker` (and `L2V31Upgrade`) bytecode
descriptors.

These two scripts patch the already-prepared upgrade for the **ZKsync OS chain
type manager (CTM) only**, without redeploying or changing any facets.

## What is patched

Inside the `[ctms.zksync_os]` section of a prepared upgrade output (e.g.
`upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml`):

| Key                                       | Role                  | Contains                                                         |
| ----------------------------------------- | --------------------- | ---------------------------------------------------------------- |
| `contracts_config.force_deployments_data` | chain-creation params | `FixedForceDeploymentsData` (incl. `assetTrackerBytecodeInfo`)   |
| `chain_upgrade_diamond_cut`               | upgrade data          | the upgrade `DiamondCutData` → `ProposedUpgrade` → L2 upgrade tx |
| `contracts_config.diamond_cut_data`       | chain-creation params | left **unchanged** (it embeds no bytecode descriptor)            |

Only two on-chain descriptors actually changed and are referenced by the ZKsync
OS CTM data:

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
`L2V30TestnetSystemProxiesUpgrade`) are genesis-only and are **not** referenced
by the ZKsync OS CTM data, so there is nothing to patch for them. Both scripts
assert this (no stale reference may remain).

A ZKsync OS bytecode descriptor is `abi.encode(bytes32 blake2s, uint32 length,
bytes32 keccak256)` (see `contracts/common/libraries/ZKSyncOSBytecodeInfo.sol`).
Because the descriptor is a fixed 96 bytes, rewriting it never shifts any ABI
offset, so the patch is a layout-preserving in-place substitution.

## The two scripts

### 1. Forge — `PatchZkosCtmAssetTracker.s.sol` (bytecode-based)

Inspired by the CTM upgrade scripts (`CTMUpgrade_v31`). It:

1. fetches the existing ZKsync OS chain-creation params / upgrade data from the
   prepared output (so facets and everything else are untouched);
2. **reconstructs** the new `L2AssetTracker` / `L2V31Upgrade` descriptors from the
   actual compiled deployed bytecode (`out/`), hashing with the same
   `scripts/blake2s256.js` helper and `keccak256` the upgrade flow uses;
3. **sends the message to the bytecode supplier** — `BytecodesSupplier.publishEVMBytecodes`
   for the two changed bytecodes (broadcast only with `BROADCAST=true`);
4. regenerates the full ZKsync OS CTM data and writes it to
   `script-out/zkos-ctm-asset-tracker-patch.forge.json`.

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

### 2. TypeScript — `scripts/patch-zkos-ctm-asset-tracker.ts` (hashes-only)

Does the same patch but **never touches the bytecode**. It decodes the existing
chain-creation params / upgrade data, locates every descriptor that involved the
old upgrade, rewrites them to the new hashes taken **only from
`AllContractsHashes.json`**, and double-checks that:

- every stale descriptor / keccak / delegate address has been replaced, and
- every bytecode reference in the patched data resolves to a hash present in
  `AllContractsHashes.json` (so no changed contract was missed).

```bash
cd l1-contracts
npx ts-node scripts/patch-zkos-ctm-asset-tracker.ts
# Optionally also emit a fully amended ecosystem.toml (zksync_os CTM only):
APPLY=true npx ts-node scripts/patch-zkos-ctm-asset-tracker.ts
```

Output: `script-out/zkos-ctm-asset-tracker-patch.ts.json`.

Environment overrides (both scripts): `ECOSYSTEM_TOML`, `HASHES_JSON` (TS only),
`PATCH_OUTPUT`, `APPLY` / `APPLY_OUTPUT` (TS only), `BROADCAST` (forge only).

## Verifying the two scripts match

The forge script derives the new hashes from the **real bytecode**; the TS
script reads them from **`AllContractsHashes.json`**. If they produce identical
ZKsync OS CTM data, then the hashes file is consistent with the artifacts and the
patch is complete. Reproduce end-to-end with:

```bash
cd l1-contracts
./scripts/patch-zkos-ctm-asset-tracker.reproduce.sh        # builds, runs both, diffs
SKIP_BUILD=1 ./scripts/patch-zkos-ctm-asset-tracker.reproduce.sh   # reuse artifacts
```
