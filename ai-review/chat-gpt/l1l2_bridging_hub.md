## Security issues

1. **Incorrect decoding of v30 upgrade batch number on L1 leads to wrong bookkeeping**
   - **Severity**: Low  
   - **Impact**: When L1 receives the “v30 upgrade batch number” from Gateway, `L1MessageRoot` stores an incorrect value (`chainId` instead of the batch number). This desynchronizes L1’s `v30UpgradeChainBatchNumber` from the settlement layer’s view and can break internal invariants used during migration and future upgrades (e.g. wrong batch boundaries considered “post‑v30”). It does *not* appear to directly enable message forgery or fund theft, but it risks mis-accounting and future migration bugs for affected chains.

   **Details**

   In `L1MessageRoot.saveV30UpgradeChainBatchNumberOnL1` the L2→L1 message from Gateway contains:

   ```solidity
   // L2 side (Gateway)
   // abi.encodeCall(this.sendV30UpgradeBlockNumberFromGateway, (_chainId, sentBlockNumber))
   ```

   On L1 this is decoded as:

   ```solidity
   function saveV30UpgradeChainBatchNumberOnL1(
       FinalizeL1DepositParams calldata _finalizeWithdrawalParams
   ) external {
       require(_finalizeWithdrawalParams.l2Sender == L2_MESSAGE_ROOT_ADDR, OnlyL2MessageRoot());
       bool success = proveL1DepositParamsInclusion(_finalizeWithdrawalParams);
       if (!success) {
           revert InvalidProof();
       }

       require(_finalizeWithdrawalParams.chainId == ERA_GATEWAY_CHAIN_ID, OnlyGateway());
       require(
           IBridgehubBase(BRIDGE_HUB).whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
           NotWhitelistedSettlementLayer(_finalizeWithdrawalParams.chainId)
       );

       (uint32 functionSignature, uint256 offset) =
           UnsafeBytes.readUint32(_finalizeWithdrawalParams.message, 0);
       require(
           bytes4(functionSignature) == L2MessageRoot.sendV30UpgradeBlockNumberFromGateway.selector,
           IncorrectFunctionSignature()
       );

       // BUG: offset is not advanced between the two reads
       (uint256 chainId, ) =
           UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, offset);
       (uint256 receivedV30UpgradeChainBatchNumber, ) =
           UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, offset);

       require(v30UpgradeChainBatchNumber[chainId] == 0, V30UpgradeChainBatchNumberAlreadySet());
       v30UpgradeChainBatchNumber[chainId] = receivedV30UpgradeChainBatchNumber;
   }
   ```

   `UnsafeBytes.readUint256` returns both the decoded value and the *new* offset. However, the function:

   - calls `readUint256` twice with the same `offset` instead of threading the new offset through, so
   - both calls read from the same location in `message`.

   As a result:

   - `receivedV30UpgradeChainBatchNumber` is decoded from the same 32-byte slot as `chainId`, so
   - `receivedV30UpgradeChainBatchNumber == chainId` rather than the actual `_blockNumber` (`sentBlockNumber`) sent from Gateway.

   So for a chain with ID `X` whose real v30 upgrade batch number is `K`, L1 ends up with:

   ```solidity
   v30UpgradeChainBatchNumber[X] = X; // incorrect, should be K
   ```

   **Why this matters**

   - `v30UpgradeChainBatchNumber` is used to track from which batch v30 semantics (and in particular, settlement-layer accountability) start applying for a given chain.
   - This value is expected to be consistent across L1 and settlement layers and is carried across migrations via `ChainAssetHandlerBase.bridgeBurn` / `bridgeMint` and `MessageRootBase.setMigratingChainBatchRoot`.
   - An incorrect value on L1 means subsequent migrations or invariants relying on L1’s view may behave incorrectly (for example, using the wrong cutoff batch when moving a chain between settlement layers).

   Based on the current code:

   - L2→L1 proof verification (`_getChainBatchRoot`, `proveL2*Inclusion*`) does **not** use this mapping, so message inclusion proofs themselves are unaffected.
   - The impact is primarily on upgrade/migration accounting and internal safety checks that assume this value mirrors the settlement layer.

   **Recommendation**

   Fix the decoding logic to correctly advance the offset between reads. For example:

   ```solidity
   (uint32 functionSignature, uint256 offset) =
       UnsafeBytes.readUint32(_finalizeWithdrawalParams.message, 0);
   require(
       bytes4(functionSignature) == L2MessageRoot.sendV30UpgradeBlockNumberFromGateway.selector,
       IncorrectFunctionSignature()
   );

   (uint256 chainId, uint256 newOffset) =
       UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, offset);
   (uint256 receivedV30UpgradeChainBatchNumber, ) =
       UnsafeBytes.readUint256(_finalizeWithdrawalParams.message, newOffset);

   require(v30UpgradeChainBatchNumber[chainId] == 0, V30UpgradeChainBatchNumberAlreadySet());
   v30UpgradeChainBatchNumber[chainId] = receivedV30UpgradeChainBatchNumber;
   ```

   or equivalently:

   ```solidity
   (uint32 functionSignature, uint256 offset) =
       UnsafeBytes.readUint32(_finalizeWithdrawalParams.message, 0);
   require(
       bytes4(functionSignature) == L2MessageRoot.sendV30UpgradeBlockNumberFromGateway.selector,
       IncorrectFunctionSignature()
   );

   bytes memory payload = _finalizeWithdrawalParams.message[offset:];
   (uint256 chainId, uint256 receivedV30UpgradeChainBatchNumber) =
       abi.decode(payload, (uint256, uint256));
   ```

   After fixing, you should:

   - verify that `v30UpgradeChainBatchNumber` on L1 is consistent with the settlement layer for all chains that have already gone through this path, and
   - consider adding a sanity check where `setMigratingChainBatchRoot` or migration logic rejects obviously inconsistent `v30UpgradeChainBatchNumber` values (e.g., too small w.r.t. `currentChainBatchNumber`) to guard against any past misconfiguration.

---

## Open points / assumptions

These are not reported as vulnerabilities, but correctness relies on the following components behaving as expected:

1. **Custom `ReentrancyGuard` and `AssetHandlerModifiers`**
   - Functions like `L1Bridgehub.initialize`, `L2Bridgehub.initL2`, and all `bridgeBurn/bridgeMint` paths rely on `reentrancyGuardInitializer` and `requireZeroValue` semantics.
   - To fully rule out initialization and value‑mismatch bugs, the implementations of:
     - `ReentrancyGuard` (especially `reentrancyGuardInitializer`), and  
     - `AssetHandlerModifiers.requireZeroValue`
   - should be reviewed. Current reasoning assumes they correctly enforce one‑time initialization and exact ETH/value checks.

2. **Message hashing / encoding libraries**
   - Proof verification and nested L2→GW→L1 messaging rely heavily on:
     - `UnsafeBytes`
     - `MessageHashing`
   - The analysis assumes these libraries:
     - implement the documented encodings (e.g., batch roots, leaves) correctly,
     - are collision‑resistant / free of parsing ambiguities.
   - Any deviation could affect message inclusion proofs across L1/L2/settlement layers.