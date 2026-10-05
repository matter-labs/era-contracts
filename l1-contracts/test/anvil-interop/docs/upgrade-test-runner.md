# Upgrade Test Runner

## Overview

The upgrade test runner (`upgrade-test-runner.ts`, driven by `run-upgrade-test.ts`) always exercises the
upgrade the current release ships, exactly as `protocol-ops ecosystem upgrade-prepare-all` prepares it by
default: no `--core-script-path`, `--ctm-script-path` or `--upgrade-input-path` overrides. The scenario boots
the previous release's ecosystem from `chain-states/<upgradeSourceStateVersion>/` and checks that every target
chain ends at the protocol version in `configs/genesis/zksync-os/latest.json`, the version the default scripts
upgrade to. Nothing in the harness names a release, so a release bump does not touch it (see
[Release bumps](#release-bumps)).

It patches around Anvil EVM limitations that prevent the real L2 ZKsync OS execution environment from working.

## Production upgrade flow (what the test reproduces)

1. **Prepare**: `upgrade-prepare-all` runs the default core and CTM upgrade scripts on a fork of L1. They deploy
   the new implementation contracts via Create2, the per-chain upgrade contract and the new verifier, and emit
   the stage 0/1/2 governance calls into a merged `ecosystem.toml` plus a deployer Safe bundle.

2. **Governance stage 0**: Pause gateway migrations (`pauseMigration()` on ChainAssetHandler).

3. **Governance stage 1**: Upgrade the proxy implementations via the TransparentProxyAdmin and register the new
   protocol version and its diamond cut on the CTM.

4. **Governance stage 2**: Unpause gateway migrations and any version-specific post-upgrade calls.

5. **Per-chain upgrade**: For each ZK chain, `protocol-ops chain upgrade` emits the chain admin's
   `upgradeChainFromVersion()` call on the diamond proxy. This records an L2 upgrade transaction that the server
   includes in the next batch.

6. **L2 upgrade execution**: The bootloader includes the L2 upgrade tx as a system transaction. It calls
   `ComplexUpgrader.forceDeployAndUpgradeUniversal()`, which force-deploys the new L2 system contract bytecodes
   through the ZKsync OS bytecode deployer and delegatecalls to `L2DefaultUpgrade.upgrade()`, which runs
   `updateL2` on the existing contracts.

7. **Verification**: Protocol version on each chain is now the genesis version.

## Architecture notes

### The per-chain upgrade contract

The default upgrade upgrades ZKsync OS chains only, through **`DefaultUpgradeZKsyncOS`** (or a release's thin
subclass of it): the plain
`DefaultUpgrade` plus the per-chain substitution of the force-deployments data inside
`ComplexUpgrader.forceDeployAndUpgradeUniversal(UniversalContractUpgradeInfo[], address, bytes)`.
The substitution itself lives in `L2UpgradeTxLib.rewriteUpgradeTxData`, and the contract reads
`s.bridgehub` / `s.chainId` from diamond storage (no immutables).

### ADDRESS_TO_CONTRACT map

The `ADDRESS_TO_CONTRACT` map in the test runner drives deployment of L2 contracts.
It maps well-known L2 system contract addresses to their contract names. During the
L2 relay phase, the test runner:

1. Decodes the force deployment list from the L2 upgrade calldata.
2. For each address in the list, looks up the contract name in `ADDRESS_TO_CONTRACT`.
3. Uses `anvil_setCode` to place the EVM-compiled bytecode at that address.

This replaces any need for a separate `PREDEPLOY_SYSTEM_CONTRACTS` list.

### SystemContractProxyAdmin

The real `SystemContractProxyAdmin` is deployed at the proxy admin address. Its `_owner` storage
slot is set to `L2_COMPLEX_UPGRADER_ADDR` via
`anvil_setStorageAt` so that `_setupProxyAdmin()` and `upgrade()` calls succeed.

### L2BaseToken

ZKsyncOS chains use `L2BaseToken` deployed behind `SystemContractProxy` at 0x800A.
On Anvil, `MINT_BASE_TOKEN_HOOK` is an empty address, so the mint call in
`L2BaseToken.initL2()` is a no-op.

### Force deployment list from calldata

The force deployment list is extracted directly from the outer ComplexUpgrader calldata. The test
runner decodes `forceDeployAndUpgradeUniversal`, rejects every other selector, and pre-deploys all
listed addresses via `anvil_setCode`.

### ComplexUpgrader reuse

The previous release's ComplexUpgrader already supports `forceDeployAndUpgradeUniversal`, so its existing
implementation can start the production transaction. The force-deployment list upgrades the
ComplexUpgrader's own system proxy to the current implementation during that loop; the already
running old delegatecall frame then finishes the remaining entries and the upgrade delegatecall.
`RemovedTrackerNeutralizationTest` covers this old-to-new self-upgrade directly.

The Anvil harness cannot emulate the OS bytecode deployer, so its predeployment step installs the
current implementation behind the ComplexUpgrader proxy before relay. It therefore validates the
calldata and final state, but not the mid-frame proxy swap itself.

## Test flow and patches

### 1. Load pre-generated chain states

Anvil chains boot from serialized state dumps (`chain-states/<upgradeSourceStateVersion>/`, set in
`config/anvil-config.json`). These contain a fully-deployed L1 ecosystem + multiple L2 chains at the previous
release. They are the previous release's own `chain-states/<stateVersion>/`, generated by
`setup-and-dump-state.ts` on that release's branch and carried over unchanged.

No patches here -- this is equivalent to having a live ecosystem on the previous release.

### 2. Prepare L1 state

**Patch: Ownership transfers** (`transferL1Ownership`)

- Production: Governance already owns Bridgehub, SharedBridge, NTV, CTM, and ChainAssetHandler.
- Test: The state dumps were created with the default Anvil deployer (`0xf39F...`) as owner.
  The runner transfers ownership to the governance address via `transferOwnership()` +
  `acceptOwnership()` (two-step Ownable2Step pattern).
- Why: The upgrade scripts generate governance calls that require `onlyOwner`. Without this
  transfer, all governance calls would revert.

**Patch: ChainAdmin deployment** (`deployChainAdmins`)

- Production: Each ZK chain already has a `ChainAdmin` contract set as its diamond proxy admin.
- Test: The state dumps have the deployer address as the admin. The runner deploys a fresh
  `ChainAdminOwnable` for each target chain, then calls `setPendingAdmin()` +
  `acceptAdmin()` on the diamond proxy to install it.
- Why: `DefaultChainUpgrade` calls the upgrade through the chain admin's `multicall`. Without
  a real ChainAdmin contract, the per-chain upgrade would fail.

### 3. Prepare the upgrade with protocol-ops defaults

The runner calls `protocol-ops ecosystem upgrade-prepare-all` with only the topology (`--bridgehub`,
`--ctm-proxy`, `--deployer-address`, `--l1-rpc-url`, `--out`). Scripts, upgrade input, bytecodes supplier and
rollup DA manager are protocol-ops' defaults or auto-resolved from the CTM, as for a real ecosystem. The deployer
Safe bundle is then executed by impersonating its target.

**No patches** -- the production default scripts run unmodified.

### 4. Execute governance calls (stages 0-2)

The generated governance calls are decoded from the Forge output TOML and executed by
impersonating the governance address via `anvil_impersonateAccount`.

No patches. All governance calls (including `pauseMigration()` / `unpauseMigration()` on
ChainAssetHandler) run against the previous release's implementations.

### 5. Prepare diamond state for chain upgrades

**Patch: Clear genesis upgrade tx hash** (`clearGenesisUpgradeTxHash`)

- Production: After the server processes a previous L2 upgrade, it clears the
  `l2SystemContractsUpgradeTxHash` field in the diamond proxy storage. This field acts as a
  lock -- if non-zero, `upgradeChainFromVersion()` reverts because the previous upgrade hasn't
  been executed yet.
- Test: No server processes batches, so the hash from the previous protocol version's upgrade
  is still set.
- Mechanism: `anvil_setStorageAt(diamondProxy, "0x22", HashZero)` -- directly clears storage
  slot 0x22 which holds `l2SystemContractsUpgradeTxHash`.

### 6. Per-chain L1 upgrade + L2 relay

The L1 side runs the **production** `protocol-ops chain upgrade` bundle -- no patches needed, apart from
`forceBatchExecutedEqualsCommitted` (see the summary table).

The L2 relay is the **biggest deviation from production**. In production, the bootloader sends
a system transaction to ComplexUpgrader, which force-deploys new L2 bytecodes through the ZKsync OS
bytecode deployer and then delegatecalls to `L2DefaultUpgrade.upgrade()`. That deployer requires the
ZKsync VM (bytecode hashing, validation, etc.) and does not work on Anvil EVM. The test patches
around this:

**Patch: Pre-deploy L2 contracts + MockContractDeployer** (`deployL2Contracts`)

- Production: L2 execution has two stages:
  1. The **outer** force deploys: `ComplexUpgrader.forceDeployAndUpgradeUniversal()` iterates
     `_forceDeployments[]` and calls the ZKsync OS bytecode deployer for each entry.
  2. `L2DefaultUpgrade.upgrade()` then calls `performForceDeployedContractsInit(false)` to initialize
     or update the contracts installed by the outer list.

  The outer path goes through the bytecode-deployer system contract, a ZK-VM native that can set
  bytecode at arbitrary addresses. This is impossible from within an EVM contract.

- Test: The runner pre-deploys all contracts via `anvil_setCode` BEFORE sending the upgrade
  transaction, and places a typed `MockContractDeployer` at the bytecode-deployer address (0x8006).
  The **original** upgrade calldata is sent unchanged to the canonical ComplexUpgrader address,
  whose proxy the predeployment step has already pointed at the current implementation. The outer
  force-deploy calls hit the MockContractDeployer and succeed -- the contracts are already at their
  addresses via `anvil_setCode`.

- What gets pre-deployed: All addresses from the force deployment list in the calldata,
  mapped to EVM contract names via the `ADDRESS_TO_CONTRACT` map. Also:
  - `L2DefaultUpgrade` bytecode at the delegateTo address
  - `MockContractDeployer` at 0x8006
  - `SystemContractProxyAdmin` at the proxy admin address (owner set to ComplexUpgrader)
  - `L2ComplexUpgrader` behind SystemContractProxy at 0x800F
  - `L2BaseToken` behind SystemContractProxy (ZKsyncOS) at 0x800A

### L2BaseToken

- Production: the genesis path (`L2GenesisUpgrade`) calls `L2BaseToken.initL2(l1ChainId)`;
  `L2DefaultUpgrade.upgrade()` does not. On ZKsyncOS, `L2BaseToken.initL2()` calls `MINT_BASE_TOKEN_HOOK`.
- Test: ZKsyncOS uses `L2BaseToken` behind `SystemContractProxy` at 0x800A.
  On Anvil, `MINT_BASE_TOKEN_HOOK` is an empty address so the mint call is a no-op.

### SystemContractProxyAdmin owner

- Production: `_setupProxyAdmin()` requires `owner == ComplexUpgrader` (set during genesis).
- Test: The real `SystemContractProxyAdmin` is deployed and its `_owner` slot is set to
  `L2_COMPLEX_UPGRADER_ADDR` via `anvil_setStorageAt`.

### 7. Verification

No patches. Reads on-chain state to assert:

- `L2AssetTracker.L1_CHAIN_ID` is set correctly on each L2 chain
- The base token's bookkeeping is initialized in the L2AssetTracker of each L2 chain
- `getProtocolVersion()` on each diamond proxy returns the genesis config's protocol version
- The recorded `getL2SystemContractsUpgradeTxHash()` equals the hash of the upgrade transaction the
  harness relayed to L2, i.e. the per-chain data really was substituted on L1. This one is asserted during
  step 6, inside `runChainUpgradesAndRelayL2`, and only on the single-CTM path

## Summary table

| #   | Patch                                          | Where                               | Production behavior                                              | Test behavior                                                                                                                                               | Mechanism                                                     |
| --- | ---------------------------------------------- | ----------------------------------- | ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| 1   | Ownership transfers                            | `transferL1Ownership`               | Governance already owns contracts                                | Transfer from deployer to governance                                                                                                                        | `transferOwnership()` + `acceptOwnership()`                   |
| 2   | ChainAdmin deployment                          | `deployChainAdmins`                 | Chain admins already exist                                       | Deploy fresh ChainAdminOwnable                                                                                                                              | `new ChainAdminOwnable()` + `setPendingAdmin` + `acceptAdmin` |
| 3   | Clear genesis upgrade hash                     | `clearGenesisUpgradeTxHash`         | Server clears after batch processing                             | Clear via storage write                                                                                                                                     | `anvil_setStorageAt(proxy, 0x22, 0x0)`                        |
| 4   | Pre-deploy L2 contracts + MockContractDeployer | `deployL2Contracts`                 | ZKsync OS bytecode deployer force-deploys bytecodes              | `anvil_setCode` places EVM bytecodes at addresses from the force deployment calldata; typed MockContractDeployer at 0x8006 makes force-deploy calls succeed | `anvil_setCode` for each address in calldata                  |
| 5   | L2BaseToken                                    | `deployL2Contracts`                 | ZKsyncOS: `L2BaseToken` behind proxy                             | Same as production. On Anvil, MINT_BASE_TOKEN_HOOK is empty (no-op)                                                                                         | `anvil_setCode` + `deployBehindSystemProxy` for ZKsyncOS      |
| 6   | SystemContractProxyAdmin owner                 | `deployL2Contracts`                 | Owner = ComplexUpgrader from genesis                             | Real SystemContractProxyAdmin + set owner via storage write                                                                                                 | `anvil_setStorageAt(proxyAdmin, slot0, upgrader)`             |
| 7   | L1Nullifier ownership                          | `transferL1Ownership`               | Governance already owns it                                       | Transfer from deployer to governance so `setL1InteropHandler` can run in stage 1                                                                            | `transferOwnership()` + `acceptOwnership()`                   |
| 8   | ProxyAdmin owner normalization                 | `normalizeProxyAdminOwnerToEoa`     | ProxyAdmin owned by governance, driven through `ownable_proxies` | Hand the CTM ProxyAdmin to the deployer EOA, since the harness cannot pass `ownable_proxies` to zkstack                                                     | `impersonate` + `transferOwnership()`                         |
| 9   | Force executed == committed                    | `forceBatchExecutedEqualsCommitted` | Real batches are executed before the upgrade                     | Copy `totalBatchesCommitted` onto `totalBatchesExecuted` on each diamond before its upgrade                                                                 | `anvil_setStorageAt(proxy, slot11, committed)`                |

## What IS tested end-to-end (unpatched production code)

- The default L1 upgrade scripts protocol-ops prepares with (`DefaultCoreUpgrade`, the CTM default) and the
  `protocol-ops` prepare, governance and chain-upgrade commands
- Governance call generation and execution (stages 0-2)
- Proxy upgrades for all L1 core contracts
- L2 upgrade initialization logic (`L2DefaultUpgrade.upgrade()` delegatecall path)
- New contract configuration (ownership transfers for newly deployed proxies)
- Protocol version advancement on all target chains, to the genesis version

## Release bumps

The harness has no release-specific code. When a release is cut, `config/anvil-config.json` moves
`upgradeSourceStateVersion` to the outgoing `stateVersion` (whose chain states are kept as the new upgrade
source), `stateVersion` moves to the new release and its chain states are regenerated, and the old source folder
is deleted. The genesis config's protocol version and protocol-ops' default upgrade input move with the release
as well; the runner picks both up without edits.
