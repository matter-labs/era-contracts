# V31 L2 Upgrade: Design analysis

## Two paths for L2 contract initialization

`L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit()` handles **both** genesis and
non-genesis initialization of all L2 system contracts. It takes `_isGenesisUpgrade` flag:

- **Genesis** (`_isGenesisUpgrade=true`): calls `initL2()` on each contract
- **Non-genesis upgrade** (`_isGenesisUpgrade=false`): calls `updateL2()` on each contract

For non-genesis, `performForceDeployedContractsInit` already:

1. Calls `NTV.updateL2()` with all required params from `FixedForceDeploymentsData` + `ZKChainSpecificForceDeploymentsData`
2. Calls `L2Bridgehub.updateL2()` and `setAddresses()`
3. Calls `L2AssetRouter.updateL2()`
4. Calls `L2AssetTracker.initL2()`
5. Calls `L2ChainAssetHandler.updateL2()`
6. Calls `InteropCenter.updateL2()`

## What L2V31Upgrade currently does

`L2V31Upgrade.upgrade()` duplicates a subset of what `performForceDeployedContractsInit(false)`
already does, plus adds v31-specific logic:

1. `acrossRecovery()` — v31-specific, one-time Across protocol fix
2. `NTV.updateL2(...)` — **duplicated** from genesis helper, with circular reads
3. `L2AssetTracker.registerBaseTokenDuringUpgrade()` — v31-specific
4. `L2BaseToken.initL2(l1ChainId)` — v31-specific (only for non-genesis upgrades)

## Problem: duplication and circularity

`L2V31Upgrade` reimplements the NTV `updateL2` call but:

- Reads `L2_TOKEN_PROXY_BYTECODE_HASH`, `L2_LEGACY_SHARED_BRIDGE`, `WETH_TOKEN` from NTV
  and passes them back — circular, wasteful
- Doesn't handle the other contracts (Bridgehub, AssetRouter, ChainAssetHandler, InteropCenter)
- Has a custom `L2V31UpgradeData` struct that duplicates fields from `FixedForceDeploymentsData`
  and `ZKChainSpecificForceDeploymentsData`

Meanwhile, `performForceDeployedContractsInit(false)` already handles NTV.updateL2() correctly
using the L1-provided `FixedForceDeploymentsData`, and it has no circularity because ALL values
come from L1 (the circular reads it does are for `previousL2TokenProxyBytecodeHash` and
`wrappedBaseTokenAddress`, which are passed through but the canonical source is L1).

## Proposed solution

**`L2V31Upgrade.upgrade()` should call `performForceDeployedContractsInit(isGenesisUpgrade=false)`**
for the standard contract initialization, and only add the v31-specific logic on top:

```solidity
function upgrade(
  bool _isZKsyncOS,
  address _ctmDeployer,
  bytes calldata _fixedForceDeploymentsData,
  bytes calldata _additionalForceDeploymentsData
) external {
  acrossRecovery();

  // Standard non-genesis initialization of all L2 system contracts
  L2GenesisForceDeploymentsHelper.performForceDeployedContractsInit(
    _isZKsyncOS,
    _ctmDeployer,
    _fixedForceDeploymentsData,
    _additionalForceDeploymentsData,
    false // isGenesisUpgrade
  );

  // V31-specific: register base token in the new AssetTracker
  IL2AssetTracker(L2_ASSET_TRACKER_ADDR).registerBaseTokenDuringUpgrade();

  // V31-specific: initialize BaseToken (sets L1_CHAIN_ID and BaseTokenHolder balance)
  IL2BaseTokenBase(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(L2AssetTracker(L2_ASSET_TRACKER_ADDR).L1_CHAIN_ID());
}
```

This eliminates:

- The `L2V31UpgradeData` struct entirely
- The circular NTV reads
- Duplication between L2V31Upgrade and L2GenesisForceDeploymentsHelper
- The need for `SettlementLayerV31Upgrade` to have immutables

The L1 side (`SettlementLayerV31Upgrade.getL2V31UpgradeCalldata`) would need to encode the
same `FixedForceDeploymentsData` + `ZKChainSpecificForceDeploymentsData` that the genesis
path already produces, which is available from the CTM's chain creation params.

## What L2GenesisForceDeploymentsHelper non-genesis path does NOT do

These are v31-specific and must remain in `L2V31Upgrade`:

- `acrossRecovery()` — one-time Across protocol fix
- `registerBaseTokenDuringUpgrade()` — registers base token in the new L2AssetTracker
- `baseToken.initL2()` — only called during genesis normally, but v31 needs it for existing chains
  because the BaseToken contract is new (sets `L1_CHAIN_ID`, initializes BaseTokenHolder balance)

## Anvil test implications

With this approach, the Anvil test no longer needs to worry about NTV circularity. The
`FixedForceDeploymentsData` and `ZKChainSpecificForceDeploymentsData` carry all values from L1.
The Anvil L2 state only needs:

1. `MockContractDeployer` at 0x8006 (for Era-style `forceDeployAndUpgrade`)
2. `L2V31Upgrade` bytecode at 0x10001 (the delegateTo target)
