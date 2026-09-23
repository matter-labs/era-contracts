# v0.33.0 — compiler-only upgrade (stage)

v33 ships the EraVM bytecode rebuilt with zksolc 1.5.17 and the DSE-safe bootloader (root-frame
hooks preserved, #2522). Nothing else changes: no L1 contract is deployed, no facet is cut, and the
fixed-address L2 core contracts keep their code. The force-fail bootloader that was planned as v33
moves to v34.

It has to be a minor upgrade. `BaseZkSyncUpgrade` rejects patch upgrades that set the bootloader,
default account or EVM emulator hash, or that carry an L2 upgrade transaction.

## What the upgrade does

| Where                | Change                                                                                                                                                                                                                                             |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Era CTM (governance) | stage 0 `ChainAssetHandler.pauseMigration()`; stage 1 `setNewVersionUpgrade(v0.32.2 → v0.33.0)` and `setChainCreationParams`; stage 2 `unpauseMigration()`                                                                                         |
| Upgrade cut          | no facet cuts; `initAddress` = the CTM's existing `DefaultUpgrade` (`0x98845F…`, used for v0.32.2) so the storage writes are compiled against the live diamond layout; verifier unchanged                                                          |
| `ProposedUpgrade`    | bootloader / default account / EVM emulator hashes from `configs/genesis/era/latest.json`; L2 tx type 254 from the force deployer to `ContractDeployer.forceDeployOnAddresses` with the 31 system contracts, no constructor calls; 51 factory deps |
| New chains           | the CTM's current creation parameters with only the genesis batch values and the diamond init's three hashes replaced                                                                                                                              |
| Per chain            | the chain admin calls `upgradeChainFromVersion(chain, v0.32.2, cut)`                                                                                                                                                                               |

The fixed-address L2 core contracts (bridgehub, asset router, NTV, message root, …) are not
redeployed. They hold live storage, and the NTV and chain asset handler hold constructor state that
a plain force deployment would reset.

## Files

- `stage.toml` holds the input: the CTM, bytecodes supplier, reused `DefaultUpgrade`, versions, the
  chains to upgrade, and the CTM's current chain-creation parameters as event data. The script checks
  that data against the CTM's stored hashes before using it.
- `output/stage/ecosystem.toml` holds the governance calls per stage, the per-chain ChainAdmin
  calldata, the upgrade cut, the new creation parameters and the factory-dep list.
- `rehearse-stage.sh` runs the whole flow on a Sepolia fork and asserts the L1 end state.

Script: `deploy-scripts/upgrade/v33/CTMUpgrade_v33.s.sol`.

## Running it

The bytecodes must come from the Linux CI build (`build-artifacts` of the branch's l1-contracts-ci
run, placed into `{system,l1,l2}-contracts/zkout`). A macOS zksolc build produces different hashes,
and the script's factory-dep check against the genesis hashes will fail on it.

1. Publish the factory deps on Sepolia. This step is permissionless and idempotent, and it
   regenerates the output as a side effect:

   ```bash
   cd l1-contracts
   forge script deploy-scripts/upgrade/v33/CTMUpgrade_v33.s.sol:CTMUpgrade_v33 \
     --sig 'prepare(string,string)' /upgrade-envs/v0.33.0-compiler/stage.toml \
     /upgrade-envs/v0.33.0-compiler/output/stage/ecosystem.toml \
     --rpc-url "$SEPOLIA_RPC" --broadcast --private-key "$DEPLOYER_KEY" --legacy --slow
   ```

   A fork run costs about 43M gas across the publishing transactions.

2. Execute governance stages 0, 1 and 2 from `output/stage/ecosystem.toml`. On stage they run
   through the emergency upgrade board, as the v0.32.x upgrades did.

3. For each chain, the chain admin's owner sends `chain_upgrades.<id>.chain_admin_calldata` to
   `chain_upgrades.<id>.chain_admin`. `protocol_ops chain upgrade --env stage --chain-id <id>`
   derives the same call from the CTM once stage 1 has executed.

Chain 499 is on v0.32.2 and is included. Chains 6475 and 37111 are still on v0.31.0 and need the
CTM's stored v0.31.x and v0.32.x upgrades first. After that, add them to `chain_ids` and regenerate.

## Server side

The node must know v33 as the v32 VM with the new bootloader:

- The private server's `dev` currently maps `Version33` to `VmMediumInteropForceFail`, the
  force-fail bootloader that is now v34.
- `codex/v32-dse-server` maps `Version33` to `VmMediumInteropUlongremGuard` and pins contracts
  `66ad9d572`, this line.

The chain's first post-upgrade batch has to execute the L2 upgrade transaction on that server.
