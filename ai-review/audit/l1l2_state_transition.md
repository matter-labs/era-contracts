## Security issues

No security issues were identified in the reviewed L1/L2 state‑transition contracts within this scope. The access control, upgrade, DA, and L1↔L2 finality logic are all internally consistent and guarded against obvious misuse (including malicious operator / bootloader behavior) based on the provided code and documentation.

---

## Open verification points / assumptions

These are not findings against the reviewed contracts, but places where correctness depends on external components whose code was not provided:

1. **Manual ABI encoding for `DiamondInit.initialize`**
   - `ChainTypeManagerBase._deployNewChain` manually builds `diamondCut.initCalldata` via `bytes.concat` for `IDiamondInit.initialize`.
   - To be fully certain no storage misalignment occurs at genesis, we would need the exact definition of:
     - `IDiamondInit.InitializeData`
     - `IDiamondInit.InitializeDataNewChain`
   - Source needed: `l1-contracts/contracts/state-transition/chain-interfaces/IDiamondInit.sol`.

2. **Bridgehub and ChainAssetHandler correctness**
   - Many critical flows assume:
     - `IL1Bridgehub.getZKChain`, `baseTokenAssetId`, `whitelistedSettlementLayers`, `chainAssetHandler`, `assetRouter`, and `messageRoot` are correctly implemented and immutable / governance‑controlled.
     - `IL1ChainAssetHandler` correctly orchestrates `forwardedBridgeBurn` / `forwardedBridgeMint` / `forwardedBridgeConfirmTransferResult` without reentrancy into unexpected paths.
   - Any bugs or malicious behavior in these components could break:
     - Chain migration safety (`AdminFacet.forwardedBridgeBurn/forwardedBridgeMint/...`)
     - Deposit pausing semantics (`MailboxFacet.depositsPaused`)
     - Settlement‑layer authorization checks.
   - Sources needed:
     - `bridgehub/IL1Bridgehub.sol` implementation
     - `bridgehub/IChainAssetHandler.sol` implementation
     - `bridgehub/ChainAssetHandler` concrete contract.

3. **Message verification libraries**
   - Inclusion proofs rely on:
     - `MessageVerification` / `MessageHashing`
     - `IMessageRoot.historicalRoot` and `addChainBatchRoot`
   - Correctness of L2→L1 message and log inclusion, and of cross‑chain dependency roots (`ExecutorFacet._verifyDependencyInteropRoots`), depends on these components.
   - Sources needed:
     - `common/MessageVerification.sol`
     - `common/libraries/MessageHashing.sol`
     - `bridgehub/MessageRoot` implementation.

4. **DA validator implementations**
   - The contracts assume the following L1/L2 DA validators are correct and non‑reentrant in dangerous ways:
     - `IL1DAValidator` implementations (`RollupL1DAValidator`, `RelayedSLDAValidator`, `ValidiumL1DAValidator`, etc.)
     - `L2DAValidator` library on L2
   - Incorrect implementations could allow inconsistent pubdata vs commitments despite on‑chain checks.
   - Sources needed:
     - All concrete `IL1DAValidator` implementations used in production (especially Rollup DA).
     - L2 `L2DAValidator` library / system contract code.

5. **TransparentUpgradeableProxy behavior with zero admin**
   - `GatewayCTMDeployer` relies on OZ `TransparentUpgradeableProxy` semantics when constructing:
     - `validatorTimelock` proxy
     - `serverNotifierProxy`
     - `chainTypeManagerProxy`
   - Security assumptions:
     - Constructor reverts if `admin_` is zero or otherwise misconfigured.
     - Upgrade and admin controls behave as in standard OZ v4.
   - Source needed:
     - Exact version of `@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol` used.