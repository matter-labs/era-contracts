# v31 `totalSupply` fix — ZKsync OS upgrade-data patch

Regenerates the v31 **ZKsync OS** CTM upgrade data after the base-token `totalSupply` fix in
`L2AssetTracker` (`_needToForceSetAssetMigrationOnL2` no longer reads the base token
`totalSupply()` before it is backfilled — the bug is specific to `L2BaseTokenZKOS`).

## Why regenerate

The fix changes the L2AssetTracker bytecode and, transitively, the L2 contracts that embed its
hash. Those deployed-bytecode hashes are baked into the v31 upgrade data the CTM stores, and the
corrected preimages must be published — exactly what the normal v31 CTM upgrade prep does.

## Main script (Solidity) — `PatchTotalSupplyV31`

`../PatchTotalSupplyV31UpgradeData.s.sol` extends `CTMUpgrade_v31` and, in `runPatch()`, runs
`noGovernancePrepare(params)` with `isZKsyncOS = true`, which:
- assembles the **full list of factory dependencies** and **publishes** them via the
  `BytecodesSupplier`, and
- rebuilds + serializes the `setNewVersionUpgrade` / `setChainCreationParams` governance calls
  from the freshly-built (fixed) artifacts.

All deployed addresses are read from the stage artifact
`upgrade-envs/v0.31.0-interopB/output/stage/ecosystem.toml` (`[ctms.zksync_os]` / `[core]`); the
ZKsync OS CTM CREATE2 salt comes from the matching `stage.toml` and the L1 RPC env var name is
hardcoded. It records the corrected upgrade-cut hash to `patched-upgrade-cut-hash.toml`.

Run it like the v31 upgrade itself — via `--rpc-url` so forge links the deploy libraries into the
fork (the script asserts the L1 chain id), and with a funded deployer + `--broadcast` to actually
publish the bytecodes:

```bash
forge script deploy-scripts/upgrade/v31/PatchTotalSupplyV31UpgradeData.s.sol \
  --sig "runPatch()" --ffi --rpc-url "$TENDERLY_SEPOLIA" --broadcast
```

Preconditions (same as the original v31 ZKsync OS prep): the CTM's introspection needs at least one
ZKsync OS chain already at the target protocol version (`getUptoDateZkChainAddresses`), and the
create2 factory / deployer must be funded. A `--broadcast`-less run simulates against the fork and
produces the regenerated cut in `patched-upgrade-cut.toml`.

## Double-check (TypeScript) — blake hashes computed in TS

ZKsync OS force-deployments embed, per contract, a `ZKSyncOSBytecodeInfo` whose bytecode hash is
`blake2s256(evmDeployedBytecode)` — the same value `scripts/blake2s256.js` computes and that
`AllContractsHashes.json` stores as `evmDeployedBytecodeBlakeHash`.

`../../../../scripts/patch-total-supply-crosscheck.ts` recomputes those blake2s hashes **fully in
TypeScript** (reusing the `blake2s256.js` logic, via `blakejs`) from the freshly-built `out/*`
artifacts, and:

1. cross-checks each against `AllContractsHashes.json` (artifacts ↔ committed hashes);
2. reads the previous upgrade cut **on chain** from the ZKsync OS CTM (CTM + old protocol version
   from `ecosystem.toml`, verified against `upgradeCutHash`) and confirms the blake hashes of
   *unchanged* force-deployed contracts (`L2AssetRouter`, `L2Bridgehub`, `L2MessageRoot`,
   `BaseTokenHolder`, `InteropCenter`) are present in it — proving the cut embeds these hashes and
   the TS computation matches the prep — while the *affected* contracts' new hashes are absent
   (the chain still has the pre-fix hashes);
3. if the Solidity prep output (`patched-upgrade-cut.toml`) is present, confirms the affected
   contracts' new blake hashes DO land in the regenerated cut (and the unchanged ones still do),
   i.e. the regeneration swapped exactly the changed force-deployment hashes.

```bash
yarn patch-total-supply:crosscheck
```
