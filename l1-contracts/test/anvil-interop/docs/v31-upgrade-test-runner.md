# V31 Upgrade Test Runner

## Overview

The v31 upgrade test runner (`v31-upgrade-test-runner.ts`) tests the full v29->v31 and v30->v31
protocol upgrade flow on local Anvil chains. It exercises the **production Solidity upgrade scripts**
end-to-end, but patches around Anvil EVM limitations that prevent the real L2 ZKsync execution
environment from working.

## Production upgrade flow (what the test reproduces)

In production, a v31 protocol upgrade proceeds as:

1. **Deploy new L1 contracts**: `EcosystemUpgrade_v31` deploys new implementation contracts
   (Bridgehub, MessageRoot, Nullifier, AssetRouter, NTV, AssetTracker, CTM, facets, etc.)
   via Create2. Configures the new AssetTracker (calls `setAddresses()`, transfers ownership
   to governance).

2. **Governance stage 0**: Pause gateway migrations (`pauseMigration()` on ChainAssetHandler).

3. **Governance stage 1**: Upgrade all proxy implementations via the TransparentProxyAdmin,
   accept AssetTracker ownership, set AssetTracker reference in NTV, set the new version
   upgrade contract.

4. **Governance stage 2**: Unpause gateway migrations, version-specific post-upgrade calls.

5. **Per-chain upgrade**: For each ZK chain, the chain admin calls
   `upgradeChainFromVersion()` on the diamond proxy. This records an L2 upgrade transaction
   that the server will include in the next batch.

6. **L2 upgrade execution**: The bootloader includes the L2 upgrade tx as a system transaction.
   It calls `ComplexUpgrader.forceDeployAndUpgrade()` which:
   - Force-deploys new L2 system contract bytecodes (via ContractDeployer on Era, or the
     bytecode deployer on ZKsyncOS)
   - Delegatecalls to `L2V31Upgrade.upgrade()` which initializes new contracts (NTV, Bridgehub,
     AssetRouter, AssetTracker, ChainAssetHandler, InteropCenter, BaseToken, etc.)

7. **Stage 3**: Post-governance migration. Registers bridged tokens in NTV and migrates token
   balances from NTV to AssetTracker (shared logic in `TokenMigrationUtils`).

8. **Verification**: Protocol version on each chain is now `0x1f00000000` (v31).

## Architecture notes

### SettlementLayerV31Upgrade split

The original `SettlementLayerV31Upgrade` has been split into:

- **`SettlementLayerV31UpgradeBase`** -- abstract base with shared L1 state updates and
  L2 calldata construction. Reads `s.bridgehub` from diamond storage (no immutables).
- **`EraSettlementLayerV31Upgrade`** -- Era (EraVM) variant. Handles
  `ComplexUpgrader.forceDeployAndUpgrade(ForceDeployment[], address, bytes)`.
- **`ZKsyncOSSettlementLayerV31Upgrade`** -- ZKsyncOS variant. Handles
  `ComplexUpgrader.forceDeployAndUpgradeUniversal(UniversalContractUpgradeInfo[], address, bytes)`.

There is no more single `SettlementLayerV31Upgrade` contract.

### ADDRESS_TO_CONTRACT map

The `ADDRESS_TO_CONTRACT` map in the test runner drives deployment of L2 contracts.
It maps well-known L2 system contract addresses to their contract names. During the
L2 relay phase, the test runner:

1. Decodes the force deployment list from the L2 upgrade calldata.
2. For each address in the list, looks up the contract name in `ADDRESS_TO_CONTRACT`.
3. Uses `anvil_setCode` to place the EVM-compiled bytecode at that address.

This replaces any need for a separate `PREDEPLOY_SYSTEM_CONTRACTS` list.

### MockSystemContractProxyAdmin

On ZKsyncOS chains, `performForceDeployedContractsInit` calls
`SystemContractProxyAdmin.upgrade(proxy, impl)` which requires `owner == ComplexUpgrader`.
The test runner deploys a `MockSystemContractProxyAdmin` (no-op) at the proxy admin address
and sets its owner to `L2_COMPLEX_UPGRADER_ADDR` via `anvil_setStorageAt`.

### L2BaseTokenEra for both Era and ZKsyncOS

The test uses `L2BaseTokenEra` (storage-based balance tracking) for both Era and ZKsyncOS
chains. On ZKsyncOS, `L2BaseTokenZKOS.initL2()` would call `MINT_BASE_TOKEN_HOOK` which is
a ZK-VM precompile that does not exist on Anvil. `L2BaseTokenEra` avoids this by reading
`__DEPRECATED_totalSupply` from storage instead.

### Force deployment list from calldata

The force deployment list is extracted directly from the ComplexUpgrader calldata (the outer
encoding). The test runner decodes either the Era `forceDeployAndUpgrade` or ZKsyncOS
`forceDeployAndUpgradeUniversal` selector to extract the deployment list, then pre-deploys
all addresses via `anvil_setCode`.

### ComplexUpgrader reuse

The existing ComplexUpgrader from the v29/v30 state is used as-is. The L1 side constructs
calldata using the matching ABI variant. No fresh ComplexUpgrader replacement is needed, and
there is no `IComplexUpgraderZKsyncOSV29` -- the v30 ComplexUpgrader already supports the
`forceDeployAndUpgradeUniversal` interface directly.

## Test flow and patches

### 1. Load pre-generated chain states

Anvil chains boot from serialized state dumps (`chain-states/v0.29.0/`, `chain-states/v0.30.0/`).
These contain a fully-deployed L1 ecosystem + multiple L2 chains at the source protocol version.
The state dumps are generated once via `setup-and-dump-state.ts` and committed to the repo.

No patches here -- this is equivalent to having a live chain at v29/v30.

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
- Why: `ChainUpgrade_v31` calls the upgrade through the chain admin's `multicall`. Without
  a real ChainAdmin contract, the per-chain upgrade would fail.

### 3. Run production L1 upgrade scripts (Forge)

The test calls the **real** `EcosystemUpgrade_v31` scripts via Forge.

**Patch: Script splitting** (step1 + step2)

- Production: A single `run()` call deploys everything and generates governance calls.
- Test: Split into `step1()` (deploy core L1 contracts, ~12 txns) and `step2()` (re-populate
  addresses, deploy CTM, generate governance calls, ~25 txns).
- Why: Anvil with `--block-time 1` has a broadcast deadlock when too many transactions are
  queued in a single Forge script invocation. Splitting ensures each batch completes before
  the next starts.
- Mechanism: `_EcosystemUpgradeV31ForTests.sol` exposes `step1()` and `step2()` entry points.

**Patch: Idempotent core upgrade** (`CoreUpgradeV31Idempotent`)

- Production: `CoreUpgrade_v31.deployNewEcosystemContractsL1()` deploys contracts AND calls
  `updateContractConnections()` (which runs `AssetTracker.setAddresses()` and
  `transferOwnership(governance)`).
- Test: step1 runs the full flow. step2 needs to re-populate `coreAddresses` (Create2 deploys
  are no-ops since contracts already exist) but must NOT re-run `updateContractConnections()`
  because `setAddresses()` is `onlyOwner` and ownership was already transferred to governance
  in step1.
- Mechanism: `CoreUpgradeV31Idempotent` overrides `deployNewEcosystemContractsL1()` to call
  `deployNewEcosystemContractsL1NoConnections()` -- deploys only, no side effects.

**Patch: Skip factory deps check** (`CTMUpgradeV31ForTests`)

- Production: `CTMUpgrade_v31.prepareCTMUpgrade()` validates that factory dependency bytecodes
  match expected lengths (ZK bytecodes have specific size constraints).
- Test: `CTMUpgradeV31ForTests` calls `setSkipFactoryDepsCheck_TestOnly(true)` before running
  the CTM upgrade.
- Why: The test uses EVM-compiled bytecodes which have completely different sizes from ZK
  bytecodes. The length check would always fail.

### 4. Execute governance calls (stages 0-2)

The generated governance calls are decoded from the Forge output TOML and executed by
impersonating the governance address via `anvil_impersonateAccount`.

No patches. All governance calls (including `pauseMigration()` / `unpauseMigration()` on
ChainAssetHandler) work because the v29 and v30 ChainAssetHandler implementations already
have these functions.

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

**Patch: Seed batch counters** (`seedBatchCounters`)

- Production: Real chains have processed batches, so `totalBatchesExecuted > 0`.
- Test: The state dumps represent freshly-deployed chains that never processed a real batch.
  The upgrade script's `upgradeChainFromVersion()` requires `totalBatchesExecuted >= 1` to
  ensure the chain is operational before upgrading.
- Mechanism: `anvil_setStorageAt` sets `totalBatchesExecuted` (slot 11) and
  `totalBatchesCommitted` (slot 13) to 1 on each diamond proxy.

### 6. Per-chain L1 upgrade + L2 relay

The L1 side runs the **production** `ChainUpgrade_v31` Forge script -- no patches needed.

The L2 relay is the **biggest deviation from production**. In production, the bootloader sends
a system transaction to ComplexUpgrader, which force-deploys new L2 bytecodes via the
ContractDeployer (Era) or the ZKsyncOS bytecode deployer, then delegatecalls to
`L2V31Upgrade.upgrade()`. On Anvil EVM, the ContractDeployer and ZKsyncOS deployer require the
ZKsync VM (bytecode hashing, validation, etc.) and do not work. The test patches around this:

**Patch: Pre-deploy L2 contracts + MockContractDeployer** (`deployL2Contracts`)

- Production: Force deployment happens in two places:
  1. The **outer** force deploys: `ComplexUpgrader.forceDeployAndUpgrade()` (Era) or
     `forceDeployAndUpgradeUniversal()` (ZKsyncOS) iterates `_forceDeployments[]` and calls
     ContractDeployer for each entry.
  2. The **inner** force deploys: `L2V31Upgrade.upgrade()` calls
     `performForceDeployedContractsInit(false)` which calls `conductContractUpgrade()` for
     each contract -- this also calls ContractDeployer (Era) or the ZKsyncOS deployer.

  Both paths go through the ContractDeployer system contract, which is a ZK-VM native that
  can set bytecode at arbitrary addresses. This is impossible from within an EVM contract.

- Test: The runner pre-deploys all contracts via `anvil_setCode` BEFORE sending the upgrade
  transaction, and places a `MockContractDeployer` (no-op fallback) at the ContractDeployer
  address (0x8006). The **original** upgrade calldata is sent unchanged to the existing
  ComplexUpgrader from the v29/v30 state. Both the outer force-deploy calls (from
  `forceDeployAndUpgrade`) and the inner calls (from `performForceDeployedContractsInit`)
  hit the MockContractDeployer which silently succeeds -- the contracts are already at their
  addresses via `anvil_setCode`.

- What gets pre-deployed: All addresses from the force deployment list in the calldata,
  mapped to EVM contract names via the `ADDRESS_TO_CONTRACT` map. Also:
  - `L2V31Upgrade` bytecode at the delegateTo address
  - `MockContractDeployer` at 0x8006
  - `MockSystemContractProxyAdmin` at the proxy admin address (ZKsyncOS only)
  - `L2BaseTokenEra` at the base token address (both Era and ZKsyncOS)

### Patch: L2BaseToken replacement

- Production: `L2V31Upgrade.upgrade()` calls `L2BaseToken.initL2(l1ChainId)`.
  On Era, `L2BaseTokenEra.initL2()` reads `__DEPRECATED_totalSupply` from storage and
  computes the BaseTokenHolder balance -- pure storage operations, no precompiles.
  On ZKsyncOS, `L2BaseTokenZKOS.initL2()` calls `MINT_BASE_TOKEN_HOOK` to mint the
  initial supply -- this is a ZK-VM precompile that doesn't exist on Anvil.
- Test: For both Era and ZKsyncOS chains, `anvil_setCode` places `L2BaseTokenEra` which
  does storage-based balance tracking. This avoids the MINT precompile issue.

### Patch: MockSystemContractProxyAdmin owner (ZKsyncOS chains only)

- Production: On ZKsyncOS chains, `performForceDeployedContractsInit(false)` calls
  `conductContractUpgrade(ZKsyncOSSystemProxyUpgrade, ...)` which calls
  `SystemContractProxyAdmin(PROXY_ADMIN_ADDR).upgrade(proxy, impl)`. This
  requires `owner == ComplexUpgrader` (set during genesis).
- Test: A `MockSystemContractProxyAdmin` (no-op fallback) is deployed via `anvil_setCode` and
  its `_owner` storage slot is set to `L2_COMPLEX_UPGRADER_ADDR` via `anvil_setStorageAt`.

### 7. Stage 3: post-governance migration

Runs the production `stage3()` Forge script which uses `TokenMigrationUtils` to register
bridged tokens in NTV and migrate token balances from NTV to AssetTracker.
**No patches** -- this is pure L1 logic.

### 8. Verification

No patches. Reads on-chain state to assert:

- `L2AssetTracker.L1_CHAIN_ID` is set correctly on each L2 chain
- The base token is registered in L2AssetTracker on each L2 chain
- `getProtocolVersion()` on each diamond proxy returns `0x1f00000000` (v31)

## Summary table

| #   | Patch                                          | Where                              | Production behavior                                                                       | Test behavior                                                                                                                                                          | Mechanism                                                                             |
| --- | ---------------------------------------------- | ---------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 1   | Ownership transfers                            | `transferL1Ownership`              | Governance already owns contracts                                                         | Transfer from deployer to governance                                                                                                                                   | `transferOwnership()` + `acceptOwnership()`                                           |
| 2   | ChainAdmin deployment                          | `deployChainAdmins`                | Chain admins already exist                                                                | Deploy fresh ChainAdminOwnable                                                                                                                                         | `new ChainAdminOwnable()` + `setPendingAdmin` + `acceptAdmin`                         |
| 3   | Script splitting                               | `_EcosystemUpgradeV31ForTests.sol` | Single `run()` call                                                                       | Split into step1 + step2                                                                                                                                               | Separate Forge invocations                                                            |
| 4   | Idempotent core upgrade                        | `CoreUpgradeV31Idempotent`         | N/A (single run)                                                                          | step2 skips `updateContractConnections()`                                                                                                                              | Override `deployNewEcosystemContractsL1()`                                            |
| 5   | Skip factory deps check                        | `CTMUpgradeV31ForTests`            | Validates ZK bytecode lengths                                                             | Skip validation                                                                                                                                                        | `setSkipFactoryDepsCheck_TestOnly(true)`                                              |
| 6   | Clear genesis upgrade hash                     | `clearGenesisUpgradeTxHash`        | Server clears after batch processing                                                      | Clear via storage write                                                                                                                                                | `anvil_setStorageAt(proxy, 0x22, 0x0)`                                                |
| 7   | Seed batch counters                            | `seedBatchCounters`                | Real batches executed                                                                     | Set counters to 1                                                                                                                                                      | `anvil_setStorageAt(proxy, slot11/13, 1)`                                             |
| 8   | Pre-deploy L2 contracts + MockContractDeployer | `deployL2Contracts`                | ContractDeployer force-deploys ZK bytecodes                                               | `anvil_setCode` places EVM bytecodes at addresses from the force deployment calldata; MockContractDeployer (no-op fallback) at 0x8006 makes force-deploy calls succeed | `anvil_setCode` for each address in calldata                                          |
| 9   | L2BaseTokenEra (both variants)                 | `deployL2Contracts`                | `L2BaseTokenEra.initL2()` reads storage; `L2BaseTokenZKOS.initL2()` calls MINT precompile | Use `L2BaseTokenEra` (storage-based) for both Era and ZKsyncOS                                                                                                         | `anvil_setCode` -- MINT_BASE_TOKEN_HOOK precompile doesn't exist on Anvil             |
| 10  | MockSystemContractProxyAdmin (ZKsyncOS)        | `deployL2Contracts`                | Owner = ComplexUpgrader from genesis                                                      | MockSystemContractProxyAdmin (no-op) + set owner via storage write                                                                                                     | `anvil_setStorageAt(proxyAdmin, slot0, upgrader)` -- `upgrade()` requires `onlyOwner` |

## What IS tested end-to-end (unpatched production code)

- All L1 Solidity upgrade scripts (`EcosystemUpgrade_v31`, `CoreUpgrade_v31`, `CTMUpgrade_v31`, `ChainUpgrade_v31`)
- Governance call generation and execution (stages 0-2)
- Proxy upgrades for all L1 core contracts
- L2 upgrade initialization logic (`L2V31Upgrade.upgrade()` delegatecall path)
- New contract configuration (AssetTracker deployment, `setAddresses`, ownership transfer)
- Token balance migration (stage 3 via `TokenMigrationUtils`)
- Protocol version advancement on all target chains
