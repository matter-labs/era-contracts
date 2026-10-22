# v0.34.0 — Era dual proofs (stage)

v34 moves stage's Era CTM from v0.33.0 to v0.34.0. From then on every Era batch needs a Boojum and an
Airbender proof, except that stage's testnet verifier, like v0.33.0's, accepts an empty proof. It also ships an operator force-fail bit for L1→L2 transactions (new bootloader), a 15M
gas cap on user L1→L2 transactions and an EVM emulator fix.

**Status:** generated and checked on a fork, not executed. `output/stage/` comes from generate run
[39414177988](https://github.com/matter-labs/era-contracts/actions/runs/39414177988) (commit `fa8deea33`,
Sepolia fork block 11955011), built on the Airbender v31.5.0 verifier and genesis.

## What the upgrade does

| Where                 | Change                                                                                                                                                                                                                                                                                                                                       |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deployments (CREATE2) | the six facets; `AirbenderVerifierPlonk`; `EraMultiProofTestnetVerifier(live EraVerifierFflonk, new AirbenderVerifierPlonk)`; `EraSettlementLayerV34Upgrade`; new `EraChainTypeManager` and `ServerNotifier` implementations. All 11 go through the CREATE2 factory `0x4e59…956C` with the same salt, `create2_factory_salt` in `stage.toml` |
| Publication           | the L2 factory deps, into the CTM's BytecodesSupplier (`0xdA70…7f6c`); already-published ones are skipped                                                                                                                                                                                                                                    |
| Era CTM (governance)  | stage 0 `ChainAssetHandler.pauseMigration()`; stage 1 `ProxyAdmin.upgrade(CTM, new implementation)`, `setNewVersionUpgrade(cut, v0.33.0, no deadline, v0.34.0, new verifier)`, `setChainCreationParams` (in that order); stage 2 `unpauseMigration()`. One emergency proposal, no timer                                                      |
| ServerNotifier        | `ProxyAdmin.upgrade(ServerNotifier, new implementation)`, outside the proposal: sent by the owner of its ProxyAdmin (the ecosystem admin `0xa6ED…3042`, through its `multicall`). The implementation adds no storage, so no initializer                                                                                                      |
| Upgrade cut           | Remove every selector chain 499 routes, Add the six new facets (Mailbox, Executor, Committer freezable); `initAddress = EraSettlementLayerV34Upgrade`, which requires every committed batch to be executed                                                                                                                                   |
| `ProposedUpgrade`     | the new bootloader and EVM emulator hashes and the unchanged default account hash from `configs/genesis/era/latest.json`; L2 tx type 254, nonce 34, from the force deployer to `ContractDeployer.forceDeployOnAddresses` with the 31 system contracts, no constructor calls                                                                  |
| New chains            | the six new facets, the CTM's current genesis upgrade and `DiamondInit`, the v34 genesis (both batch commitments); force-deployment data rebuilt with this build's L2 bytecode                                                                                                                                                               |
| Per chain             | after stage 1, the chain admin sets the upgrade timestamp (ChainAdmin and ServerNotifier); once the chain is drained, it calls `upgradeChainFromVersion(chain, v0.33.0, cut)`                                                                                                                                                                |

The L2 upgrade transaction is the same for every chain. Its factory deps start with the bootloader,
default account and EVM emulator, which is how the node learns the new base-system bytecode, then list
every force-deployed hash and the L2 core contracts. Of the 31 system contracts only `L2BaseTokenEra`
(`0x800A`) and `SystemContractProxyAdmin` (`0x1000c`) get new hashes, both through shared imports. The
fixed-address L2 core contracts are not redeployed on existing chains: they hold live storage.

Reused, not deployed: `EraVerifierFflonk` (`0x09D5…A838`), the genesis upgrade (`0xD6C4…BC70`),
`DiamondInit` (`0xb1AC…62cc`), the BytecodesSupplier, ValidatorTimelock, PermissionlessValidator,
EIP-7702 checker and DA contracts. The sources of `DiamondInit`, the genesis upgrade and `EraVerifierFflonk`
are unchanged since stage's v0.33.0 build. The live `EraVerifierFflonk`'s runtime hash differs from
`AllContractsHashes.json` (compiler metadata), so identify it by its VK hash `0xd89b62ac…32bb`, the genesis
`fflonk_snark_wrapper_vk_hash`.

The new chains' force-deployment data carries over the L1 asset router, governance, chain registration
sender, era chain id, chain limit and ZK token asset id from the CTM's stored copy, which is already in the
current `FixedForceDeploymentsData` layout. The script checks all of them except the ZK token asset id
against the bridgehub, the CTM or the input.

## Files

- `stage.toml`: the input. The CTM, every constructor value (each with its source), versions, the chains
  to upgrade, the salt, and the CTM's current chain-creation parameters as event data. The script checks
  the event data against the CTM's stored hashes, and every value that has a getter against live state.
- `output/stage/ecosystem.toml`: written by the prepare, committed from the generate run with
  `EXECUTE.md` and `emergency-upgrade-board.json`. By table:
  - `[governance_calls]`: `stage0_calls`, `stage1_calls`, `stage2_calls`, each an ABI-encoded `Call[]` of
    the emergency proposal.
  - `[ctm_admin_calls]`: the ServerNotifier upgrade, calls that the ChainAdmin `chain_admin` executes
    through `multicall`, sent by its owner `chain_admin_owner`.
  - `[chain_upgrades.499]`: raw calldata the chain's ChainAdmin owner sends to the ChainAdmin, in order:
    `set_upgrade_timestamp_calldata` and `server_notifier_timestamp_calldata` after stage 1, then
    `chain_admin_calldata` (the upgrade) once the chain is drained.
  - `[contracts_config]`: versions, the old and new verifier, the base-system hashes, the genesis values,
    the upgrade cut, the new creation parameters, and the L2 upgrade transaction's hash and factory deps.
  - `[state_transition]`: every state-transition address the upgrade deploys or reuses, under the keys
    `DefaultCTMUpgrade` writes for v31 (`admin_facet_addr`, `verifier_addr`, …).
  - `[deployed_addresses]`: the CTM's ProxyAdmin, the ServerNotifier proxy and the RollupDAManager.
  - `[contracts]`: the CREATE2 factory and the salt.
  - `[test_upgrade_calls]`: for the transaction simulator. `test_create_chain_era` creates chain 555 as the
    bridgehub admin; `test_upgrade_chain_era` is chain 499's upgrade call.
- `rehearse-stage.sh`: the fork checks (below).
- `upgrade.toml`: tells the shared generate and deploy workflows how to prepare and check this upgrade.
  Its `[execution]` table writes `output/<env>/emergency-upgrade-board.json`, which the generate workflow
  replays and renders as `output/<env>/EXECUTE.md`.

Script: `deploy-scripts/upgrade/v34-era/CTMUpgrade_v34Era.s.sol`.

## Fork checks

`rehearse-stage.sh` decodes and encodes with `cast` and derives every expected value itself, from the inputs
(`stage.toml`, `permanent-values/stage.toml`), addresses it reads from the chain, `AllContractsHashes.json`,
the v34 genesis and v33's committed output (for the 31 force deployments). Before anything is sent, it checks
each input it uses against the chain where the chain holds it (the EIP-7702 checker later, against the live
MailboxFacet), and reads the PUH and the ecosystem admin two ways. It needs Foundry and python3 (for TOML and
JSON), but no contract build (the first-batch test builds its own). Apart from the read-only `--published-only` check (every factory dep published, every deployed
contract has code; for the deploy workflow), it runs only against an Anvil fork of Sepolia. It checks:

- every deployer transaction: each CREATE2 deployment uses the env's salt, its init code is a reviewed
  bytecode (`evmBytecodeHash`) plus the expected constructor arguments, and its address is the one in
  `ecosystem.toml`; nothing else is deployed;
- every governance, ServerNotifier, timestamp and chain call, re-encoded from the expected values;
- the upgrade cut, `ProposedUpgrade`, the L2 transaction (fields, the 31 force deployments, the exact
  factory-dep set) and the new creation parameters;
- then on the fork, as the real senders: the ServerNotifier upgrade; stage 0 and the CTM proxy upgrade
  (CTM state unchanged, `initialize` reverts on proxy and implementation); stages 1 and 2 (version,
  verifier and its VKs, cut hash, creation hashes, batch zero, migrations unpaused, no pending owner);
  chain 499's timestamp (the `UpgradeTimestampUpdated` event); its upgrade reverting with
  `NotAllBatchesExecuted`; the drain, by a `REVERTER_ROLE` holder through the ValidatorTimelock; the
  upgrade (version, hashes, verifier, facets, selectors, freezable flags, the L2 tx hash, neither
  proof system disabled, the 15M cap); every factory dep published; and a test chain created with the new
  parameters;
- the new MailboxFacet's address immutables (the ChainAssetHandler and the EIP-7702 checker, which has no
  getter) equal the live facet's, read from both facets' code;
- the 15M cap on user L1→L2 transactions, through the bridgehub. It bounds the body, `l2GasLimit` minus a
  10,000 overhead, so 15,010,001 is accepted before the upgrade and reverts with `TooMuchGas` after it,
  while 15,010,000 is accepted and sent;
- chain 499's first v34 batches (`test/foundry/fork/V34EraStageFirstBatch.t.sol`, which forge runs on a
  fork of the rehearsal's fork): the upgrade batch commits on the last v33 batch, decoded from its execute
  transaction, proves with an empty proof and executes, clearing the pending upgrade; a second batch chains
  on it. A missing or wrong upgrade log, a missing Airbender heap hash, executing before proving, a
  malformed proof, v33's encoding and a v34 predecessor without its Airbender commitment revert. The
  batches are synthetic (calldata DA, no L2 execution), so public inputs and verification keys are not
  checked;
- last, the proof-system switches: through the ChainAdmin, disabling Airbender (both events,
  `disabledProofSystems = (false, true)`), disabling Boojum too (reverts) and re-enabling; sent directly,
  both calls revert.

Not covered: the L2 side, that is, the L2 upgrade transaction's execution and a new chain's genesis
transaction; real batches and proofs.

## Running it

The bytecodes must come from the Linux CI build (`build-artifacts` of the branch's l1-contracts-ci run,
unpacked at the repository root). A macOS zksolc build produces different hashes, and the script's
factory-dep check against the genesis hashes fails on it.

- **CI:** **Ecosystem Upgrade Calldata** with `upgrade = v0.34.0-era`, `environment = stage`. It prepares
  on a Sepolia fork, packs the deployer's transactions into a deploy bundle, replays it and runs
  `rehearse-stage.sh`; `verify-bundle-handoff` replays the bundle on a fresh fork with no build.
- **Locally:** prepare and check on a fork, then replay a copy of the bundle on a fresh fork, which runs
  the fork checks again:

  ```
  protocol_ops ecosystem rehearse-upgrade --upgrade v0.34.0-era --env stage --fork-url <rpc> \
    --deployer-address <deployer> [--fork-block <n>]
  protocol_ops ecosystem replay-bundle --bundle <copy of output/stage/deploy-bundle> --fork-url <rpc>
  ```

  Without protocol_ops, `L1_FORK_URL=<rpc> ./rehearse-stage.sh` prepares and checks on its own Anvil fork.
  Against a real chain, only `L1_RPC_URL=<rpc> ./rehearse-stage.sh --published-only` applies.

- **First-batch test:** on by default with `L1_FORK_URL`; through protocol_ops only with
  `FIRST_BATCH_TEST=1` in its environment (CI doesn't set it; skipped, the run ends
  `REHEARSAL PASSED (1 check skipped)`). It builds `contracts/` and the test (about 470 files, 16 s on a
  laptop) into a temporary directory, or into `FORK_TEST_OUT` to reuse the build; that must be outside
  `out/`, `zkout/` and `cache-forge/`. It needs chain 499 to have executed a batch in the last 50,000 blocks.

Executing it (not done for this dummy) follows `AGENTS.md`, "Executing Stage and Testnet Upgrades": the
deployments, then the emergency proposal, then the ServerNotifier upgrade, then per chain the timestamp
and, once drained, the upgrade.

## Server side

- The node and prover must support v0.34.0 before any chain upgrades: from then on the chain needs both
  proofs.
- The new verifier's no-argument `verificationKeyHash()` returns the Boojum FFLONK key (`0xd89b…`); the
  v0.33.0 verifier returns the PLONK key (`0xbaaa…`). The node stores the no-argument value as the
  version's snark wrapper VK hash.
- The chain's first post-upgrade batch executes the L2 upgrade transaction.

### Grant the node's chain upgrader role

The node account needs `UPGRADER_ROLE` on the ValidatorTimelock for its chain diamond. Setting an
upgrade timestamp does not grant this role. `AdminFunctions.updateValidator` adds every validator
role; use `deploy-scripts/GrantChainUpgrader.s.sol` to grant only the upgrader permission.

The script supports an **Ownable ChainAdmin**. It discovers the diamond and current ChainAdmin owner,
checks the L1 network, chain ID, timelock's Bridgehub and validator registration, and the ChainAdmin's
authority to grant the role. It encodes `grantRole(diamond, UPGRADER_ROLE, account)` inside
`ChainAdmin.multicall(..., true)`, simulates that exact request locally as the owner, and requires the
role to be present afterwards. It never broadcasts and needs no private key. Restriction-based
ChainAdmins and legacy Governance owners need their own execution route.

For stage chain 499, from `l1-contracts/`:

```bash
mkdir -p script-out
forge script deploy-scripts/GrantChainUpgrader.s.sol:GrantChainUpgrader \
  --rpc-url "$L1_RPC_URL" \
  --sig 'run(uint256,address,uint256,address,address,string)' \
  11155111 \
  0x236d1c3ff32bD0Ca26b72Af287E895627c0478cE \
  499 \
  0x7E38a259C353e72eEd3F5136c6E6534eb15C7199 \
  0x62F948cD938B00a7d4E92bc281d51979366C89F3 \
  script-out/chain-499-upgrader.json
```

Review `script-out/chain-499-upgrader.json.md` and the decoded fields in the JSON. In MetaMask on
Sepolia, send **0 ETH** from its `from` address to its `to` address with the exact contents of
`script-out/chain-499-upgrader.json.calldata`. Do not manually assemble or pad the calldata. At the
time of this runbook, the expected sender is `0x1454c35737130eB8700e5d0e7a6C44e8aE00aB10` and target
ChainAdmin is `0x3543055b186b5Fc8B214397955e850c712D831AD`; the script reads both afresh.

After confirmation, check the timelock's `RoleGranted` event for the intended diamond, role and
account, and verify membership on the real chain:

```bash
cast call --rpc-url "$L1_RPC_URL" \
  0x7E38a259C353e72eEd3F5136c6E6534eb15C7199 \
  'hasRole(address,bytes32,address)(bool)' \
  0x35360f304599cD6479978E2734F37B57AD6F1696 \
  0x189ab7a9244df0848122154315af71fe140f3db0fe014031783b0946b8c9d2e3 \
  0x62F948cD938B00a7d4E92bc281d51979366C89F3
```

Require `true` before proceeding. Receipt success alone is insufficient: `addValidatorRoles` with
all six flags false succeeds without granting anything. If the role is already present, the script
stops with `AlreadyGranted()` instead of preparing another transaction. Re-run preparation against
fresh state if the chain admin or owner changes before signing.

The script tests run without a fork:

```bash
forge test --match-path test/foundry/l1/unit/deploy-scripts/GrantChainUpgrader.t.sol
```
