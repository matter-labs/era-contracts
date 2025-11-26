## Security issues

1. **Settlement layer chain ID comes from untrusted bootloader memory (config‐sensitive, but safe by design)**  
   - **Severity**: Informational  
   - **Impact**:  
     The settlement layer chain ID that is written into `SystemContext` and emitted to L1 is taken directly from bootloader memory, which is fully under the sequencer’s control. A misconfigured or malicious operator can arbitrarily change this ID per batch. This does not by itself violate protocol invariants (the operator is already trusted to build batches), but it is a critical configuration knob for cross‑chain asset and interop logic and should be treated as such.

   **Details**

   In the proved bootloader:

   ```yul
   function SETTLEMENT_LAYER_CHAIN_ID_SLOT() -> ret {
       ret := add(INTEROP_ROOT_ROLLING_HASH_SLOT(), 1)
   }

   function SETTLEMENT_LAYER_CHAIN_ID_BYTE() -> ret {
       ret := mul(SETTLEMENT_LAYER_CHAIN_ID_SLOT(), 32)
   }

   function getSettlementLayerChainId() -> ret {
       ret := mload(SETTLEMENT_LAYER_CHAIN_ID_BYTE())
   }
   ```

   Main entrypoint (simplified):

   ```yul
   let OPERATOR_ADDRESS := mload(0)
   ...
   let SETTLEMENT_LAYER_CHAIN_ID := getSettlementLayerChainId()

   validateOperatorProvidedPrices(FAIR_L2_GAS_PRICE, FAIR_PUBDATA_PRICE)
   baseFee, GAS_PRICE_PER_PUBDATA := getFeeParams(FAIR_PUBDATA_PRICE, FAIR_L2_GAS_PRICE)

   setNewBatch(PREV_BATCH_HASH, NEW_BATCH_TIMESTAMP, NEW_BATCH_NUMBER, EXPECTED_BASE_FEE)
   setSettlementLayerChainId(SETTLEMENT_LAYER_CHAIN_ID)
   ...
   sendToL1Native(true, settlementLayerChainIdLogKey(), getSettlementLayerChainId())
   ```

   The Yul `setSettlementLayerChainId` wrapper:

   ```yul
   function setSettlementLayerChainId(currentSettlementLayerChainId) {
       mstore(0, 0x040203e6...)        // selector
       mstore(4, currentSettlementLayerChainId)

       let success := call(
           gas(),
           SYSTEM_CONTEXT_ADDR(),
           0,
           0,
           36,
           0,
           0
       )
       ...
   }
   ```

   And in `SystemContext`:

   ```solidity
   uint256 internal currentSettlementLayerChainId;

   function setSettlementLayerChainId(
       uint256 _newSettlementLayerChainId
   ) external onlyCallFromBootloader {
       if (currentSettlementLayerChainId != _newSettlementLayerChainId) {
           L2_CHAIN_ASSET_HANDLER.setSettlementLayerChainId(
               currentSettlementLayerChainId,
               _newSettlementLayerChainId
           );
           currentSettlementLayerChainId = _newSettlementLayerChainId;
       }
   }

   function getSettlementLayerChainId()
       external
       view
       onlyL2AssetTrackerOrInteropCenter
       returns (uint256)
   {
       return currentSettlementLayerChainId;
   }
   ```

   Observations:

   * The only “source of truth” for the new settlement‑layer chain ID in a batch is the operator‑supplied word at `SETTLEMENT_LAYER_CHAIN_ID_BYTE()` in bootloader memory.
   * The bootloader does not sanity‑check this value (e.g. non‑zero, matches existing config, or bounded).
   * `SystemContext` persists this value and forwards it to `L2_CHAIN_ASSET_HANDLER`; the bootloader also separately emits it to L1 via `to_l1` using its own memory copy (not via `SystemContext.getSettlementLayerChainId`).

   This is *intentional*: settlement‑layer configuration is a governance/operations concern and must be trusted anyway. However, because it affects asset‑tracking and interop semantics, any tooling that constructs bootloader calldata must treat this field as a privileged configuration parameter and avoid accidental drift.

   **Recommendation (non‑breaking improvement)**

   * Optionally constrain the acceptable value range in the bootloader or `SystemContext` (e.g. disallow zero, or only allow updates within a known set of L1 chain IDs).
   * Consider deriving the bootloader’s initial memory value for this slot from `SystemContext.currentSettlementLayerChainId` rather than from operator input, so that at steady state the operator cannot arbitrarily change it per batch.
   * Ensure operational runbooks and monitoring explicitly track this field to catch misconfiguration quickly.


2. **Upgrade‑time fallback in `setSettlementLayerChainId` can mask configuration failures**  
   - **Severity**: Low  
   - **Impact**:  
     During (and only during) the v30 upgrade path, failure to call `SystemContext.setSettlementLayerChainId` is silently ignored if `L2_INTEROP_CENTER_ADDR` is not yet deployed. If the placeholder address used in the heuristic is ever repurposed, or if the call starts failing for unexpected reasons, the bootloader will continue without updating `SystemContext.currentSettlementLayerChainId` while still emitting the operator‑supplied chain ID to L1. This can desynchronize L2 state from L1 logs and from `L2_CHAIN_ASSET_HANDLER`, potentially breaking interop or bridging until corrected.

   **Details**

   In the bootloader Yul wrapper:

   ```yul
   function setSettlementLayerChainId(currentSettlementLayerChainId) {
       ...
       let success := call(
           gas(),
           SYSTEM_CONTEXT_ADDR(),
           0,
           0,
           36,
           0,
           0
       )

       if iszero(success) {
           debugLog("Failed to set new settlement layer chain id: ", currentSettlementLayerChainId)

           /// here during the upgrade the setting of the settlement layer chain will fail,
           /// as the system context is not yet upgraded.
           /// todo remove after v30 upgrade.
           /// We want to check if the interop center is deployed or not, i.e. did we execute V30 upgrade.
           let codeSize := getCodeSize(L2_INTEROP_CENTER_ADDR())
           let codeSize2 := getCodeSize(add(L2_INTEROP_ROOT_STORAGE(), 10))
           if iszero(eq(codeSize, codeSize2)) {
               revertWithReason(FAILED_TO_SET_NEW_SETTLEMENT_LAYER_CHAIN_ID_ERR_CODE(), 1)
           }
       }
   }
   ```

   Key points:

   * If the `SYSTEM_CONTEXT.setSettlementLayerChainId` call fails, the bootloader:
     * Reads the code size at `L2_INTEROP_CENTER_ADDR()`.
     * Reads code size at `L2_INTEROP_ROOT_STORAGE() + 10` (a “definitely empty” address in current deployments).
     * Only **reverts** if the two code sizes differ; otherwise it **ignores the failure**.
   * This is meant as a one‑time migration shim for chains where `SystemContext` hasn’t yet been upgraded to include `setSettlementLayerChainId`.

   Risks:

   * If an upgrade or future feature accidentally deploys a contract at `L2_INTEROP_ROOT_STORAGE() + 10`, the equality check (`codeSize == codeSize2`) may no longer correctly distinguish “pre‑upgrade” from “post‑upgrade”, and legitimate failures of `setSettlementLayerChainId` could be silently ignored.
   * In such a case:
     * `SystemContext.currentSettlementLayerChainId` would remain stale.
     * `L2_CHAIN_ASSET_HANDLER.setSettlementLayerChainId` would not be called.
     * The bootloader would still emit the operator-provided chain ID to L1 via `sendToL1Native`, so L1 and L2 views of the settlement layer could diverge.

   While this requires a combination of misconfiguration and a future address collision, it affects critical global configuration.

   **Recommendation**

   * Once all environments are on v30+ (i.e. `SystemContext` is guaranteed to have `setSettlementLayerChainId`), remove this fallback entirely and treat any failure as fatal.
   * In the meantime:
     * Assert that `L2_INTEROP_ROOT_STORAGE() + 10` will not be used by any system contract or predeploy.
     * Add monitoring to detect any batch where `setSettlementLayerChainId` reverts but the bootloader does not, as that indicates this shim path is active when it should no longer be.


3. **Interop roots and per‑tx L2 block info fully rely on operator‑supplied memory (assumption, not a bug)**  
   - **Severity**: Informational  
   - **Impact**:  
     The bootloader trusts the operator to prefill:
     * Per‑transaction L2 block info at `TX_OPERATOR_L2_BLOCK_INFO_*`.
     * Interop‐root counts per block and root entries at `INTEROP_ROOTS_PER_BLOCK_*` and `INTEROP_ROOT_*`.
     
     Incorrect data here can cause the batch to revert (DoS for that batch) or to commit incorrect interop roots / L2 block structure if not caught by other checks. The current implementation performs substantial validation and writes roots only via the `L2InteropRootStorage` system contract under `onlyCallFromBootloader`, but the correctness of the data ultimately depends on the operator and on L1 verification.

   **Details**

   Example: setting L2 block info from operator memory:

   ```yul
   function setL2Block(txId) {
       let txL2BlockPosition := add(
           TX_OPERATOR_L2_BLOCK_INFO_BEGIN_BYTE(),
           mul(TX_OPERATOR_L2_BLOCK_INFO_SIZE_BYTES(), txId)
       )

       let currentL2BlockNumber := mload(txL2BlockPosition)
       let currentL2BlockTimestamp := mload(add(txL2BlockPosition, 32))
       let previousL2BlockHash := mload(add(txL2BlockPosition, 64))
       let virtualBlocksToCreate := mload(add(txL2BlockPosition, 96))

       let isFirstInBatch := iszero(txId)

       mstore(0, 0x06bed036...) // setL2Block selector
       mstore(4, currentL2BlockNumber)
       mstore(36, currentL2BlockTimestamp)
       mstore(68, previousL2BlockHash)
       mstore(100, isFirstInBatch)
       mstore(132, virtualBlocksToCreate)

       let success := call(gas(), SYSTEM_CONTEXT_ADDR(), 0, 0, 164, 0, 0)
       if iszero(success) { revertWithReason(FAILED_TO_SET_L2_BLOCK(), 1) }
   }
   ```

   `SystemContext.setL2Block` then enforces:

   * Monotonic L2 block numbers and timestamps.
   * Correct previous block hash (including legacy hash upgrade path).
   * Consistency with batch timestamp.
   * Correct handling of virtual blocks.

   Similarly, interop roots:

   ```yul
   function setInteropRoots(txId) {
       let txL2BlockPosition := ...
       let currentL2BlockNumber := mload(txL2BlockPosition)
       let lastProcessedBlockNumber := mload(LAST_PROCESSED_BLOCK_NUMBER_BYTE())

       if lt(currentL2BlockNumber, add(lastProcessedBlockNumber, 1)) { leave }

       setInteropRootForBlock(currentL2BlockNumber)
   }

   function setInteropRootForBlock(setForBlockNumber) {
       let nextInteropRootNumber := mload(CURRENT_INTEROP_ROOT_BYTE())
       let numberOfRoots := getNumberOfInteropRootInCurrentBlock()
       if eq(numberOfRoots, 0) { revertWithReason(ZERO_INTEROP_ROOTS(), 0) }

       let finalInteropRootNumber := add(nextInteropRootNumber, sub(numberOfRoots, 1))
       for { let i := nextInteropRootNumber } lt(i, finalInteropRootNumber) { i := add(i, 1) } {
           if gte(i, MAX_INTEROP_ROOTS_IN_BATCH()) { revertWithReason(OVER_MAX_INTEROP_ROOTS(), 0) }

           let interopRootStartByte := getInteropRootByte(i)
           let currentBlockNumber := mload(add(interopRootStartByte, INTEROP_ROOT_PROCESSED_BLOCK_NUMBER_OFFSET()))
           let chainId  := mload(add(interopRootStartByte, INTEROP_ROOT_CHAIN_ID_OFFSET()))
           let blockNumber := mload(add(interopRootStartByte, INTEROP_ROOT_DEPENDENCY_BLOCK_NUMBER_OFFSET()))
           let sidesLength := mload(add(interopRootStartByte, INTEROP_ROOT_SIDE_LENGTH_OFFSET()))

           if iszero(eq(setForBlockNumber, currentBlockNumber)) {
               revertWithReason(INCORRECT_INTEROP_ROOT_BLOCK_NUMBER(), 0)
           }
           if iszero(sidesLength) {
               revertWithReason(EMPTY_SIDES_LENGTH(), 0)
           }

           callL2InteropRootStorage(chainId, blockNumber, sidesLength, interopRootStartByte)
       }

       mstore(CURRENT_INTEROP_ROOT_BYTE(), finalInteropRootNumber)
       mstore(LAST_PROCESSED_BLOCK_NUMBER_BYTE(), setForBlockNumber)
       mstore(NUMBER_OF_PROCESSED_BLOCKS_BYTE(), add(mload(NUMBER_OF_PROCESSED_BLOCKS_BYTE()), 1))
   }
   ```

   And `L2InteropRootStorage.addInteropRoot` enforces:

   ```solidity
   function addInteropRoot(
       uint256 chainId,
       uint256 blockOrBatchNumber,
       bytes32[] calldata sides
   ) external onlyCallFromBootloader {
       if (sides.length != 1) revert SidesLengthNotOne();
       if (sides[0] == bytes32(0)) revert MessageRootIsZero();
       if (interopRoots[chainId][blockOrBatchNumber] != bytes32(0)) {
           revert InteropRootAlreadyExists();
       }
       interopRoots[chainId][blockOrBatchNumber] = sides[0];
       emit InteropRootAdded(chainId, blockOrBatchNumber, sides);
   }
   ```

   So:

   * Malformed operator data generally results in the batch reverting (DoS for that batch), not in silent corruption.
   * The actual root values and block numbers are still ultimately operator‑supplied and only indirectly checked (e.g. via L1 verification of rolling hashes).

   **Recommendation**

   * Treat the L2 block info and interop root memory regions in bootloader calldata as part of the trusted operator input surface in documentation and tooling.
   * On the L1 side, ensure that the `interopRootRollingHash` and transaction status / priority hash logs are fully checked in settlement contracts, so incorrect interop roots or block sequences cannot be finalized even if the operator is malicious.


## Open issues / areas needing external context

The following aspects depend on contracts and components outside the provided scope. They appear consistent but cannot be fully validated without those sources:

1. **L1↔L2 priority queue and hash consistency**
   * The bootloader computes `canonicalL1TxHash` via `getCanonicalL1TxHash` and maintains `PRIORITY_TXS_L1_DATA` as a rolling hash of processed L1→L2 transactions.
   * Final correctness depends on the L1 Executor / Bridgehub / Mailbox contracts verifying:
     * That this rolling hash matches the sequence enqueued on L1.
     * That fields such as `reserved0` (deposit amount) and `gasLimit/maxFeePerGas` have not been tampered with.
   * To fully validate, the L1 contracts (e.g. `Executor.sol`, `Mailbox.sol`, `Bridgehub.sol`) and their specs are required.

2. **ETH_L2_TOKEN and MSG_VALUE_SIMULATOR semantics**
   * The bootloader relies on `ETH_L2_TOKEN_ADDR` and `MSG_VALUE_SIMULATOR_ADDR` to implement native token accounting (`mintEther`, `directETHTransfer`, and L1→L2 value forwarding).
   * Ensuring no minting inflation or mis‑accounting requires the concrete implementations of:
     * `L2BaseToken` (or equivalent ETH_L2_TOKEN contract).
     * `MsgValueSimulator`.
   * These are treated as trusted system contracts here, but they are part of the end‑to‑end security story.

3. **L2 chain asset handler (`L2_CHAIN_ASSET_HANDLER`)**
   * `SystemContext.setSettlementLayerChainId` forwards the old and new IDs to `L2_CHAIN_ASSET_HANDLER.setSettlementLayerChainId`.
   * Correct behavior (e.g. preventing arbitrary reconfiguration that could strand assets) depends on the logic of this handler, which is not included in the scope.
   * Its code and documentation would be needed to fully reason about the security implications of changing `currentSettlementLayerChainId`.

4. **L1 verification of interop roots**
   * The bootloader maintains a rolling hash of processed interop roots (`INTEROP_ROOT_ROLLING_HASH_BYTE()`) and emits it to L1.
   * Ensuring that only correct roots are ever finalized requires:
     * The L1 contracts that consume this rolling hash (e.g. bridge/interop L1 components).
     * Their exact verification logic for roots, blocks, and chain IDs.
   * Those contracts are necessary to fully validate the interop security model.