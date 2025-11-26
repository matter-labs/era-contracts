## Security issues

1. **Incorrect pointer arithmetic in `getCurrentCompressedBytecodeHash` (currently unused)**  
   - **Severity**: Low  
   - **Impact**: If this helper is ever used in production logic, it will read from the wrong memory location and return an incorrect compressed bytecode hash. That could break invariants around factory-deps publication and, depending on how it is used, could either incorrectly treat valid compressed data as invalid (DoS) or skip validation on malicious data.  
   - **Details**:  
     ```yul
     function getCurrentCompressedBytecodeHash() -> ret {
         let compressionPtr := mload(COMPRESSED_BYTECODES_BEGIN_BYTE())

         ret := mload(add(COMPRESSED_BYTECODES_BEGIN_BYTE(), compressionPtr))
     }
     ```  
     In the bootloader:
     - `COMPRESSED_BYTECODES_BEGIN_BYTE()` is the base of the dedicated compressed-bytecode region.
     - The slot at `COMPRESSED_BYTECODES_BEGIN_BYTE()` is used to store an **absolute pointer** (`dataInfoPtr`) into that region:
       ```yul
       // At the COMPRESSED_BYTECODES_BEGIN_BYTE() the pointer to the newest bytecode to be published
       // is stored.
       mstore(COMPRESSED_BYTECODES_BEGIN_BYTE(), add(COMPRESSED_BYTECODES_BEGIN_BYTE(), 32))
       ...
       let dataInfoPtr := mload(COMPRESSED_BYTECODES_BEGIN_BYTE())
       ...
       // On success:
       mstore(COMPRESSED_BYTECODES_BEGIN_BYTE(), newCompressedFactoryDepsPointer)
       ```
     - `dataInfoPtr` is therefore an absolute memory address, not an offset from `COMPRESSED_BYTECODES_BEGIN_BYTE()`.

     `getCurrentCompressedBytecodeHash` incorrectly does:
     ```yul
     mload(add(COMPRESSED_BYTECODES_BEGIN_BYTE(), compressionPtr))
     ```
     interpreting `compressionPtr` as a relative offset instead of an absolute pointer. The correct read, consistent with the rest of the code, would be:
     ```yul
     mload(compressionPtr)
     ```

     As of the provided code, `getCurrentCompressedBytecodeHash` is **never called**, so the bug is inert. However, it is easy for future code to start using this helper assuming it is correct.

   - **Recommendation**:  
     - Fix the helper to read from the absolute pointer:
       ```yul
       function getCurrentCompressedBytecodeHash() -> ret {
           let compressionPtr := mload(COMPRESSED_BYTECODES_BEGIN_BYTE())
           ret := mload(compressionPtr)
       }
       ```
     - Alternatively, remove the function entirely until there is a concrete use case, to avoid accidental misuse later.
     - If any out-of-tree tooling/debugging already uses this function, update it accordingly.


2. **Settlement layer chain ID is fully operator‑controlled with no in‑bootloader validation**  
   - **Severity**: Informational  
   - **Impact**: A malicious or misconfigured operator can freely choose the `currentSettlementLayerChainId` for a batch. The bootloader accepts this value from its initial memory, forwards it to `SystemContext.setSettlementLayerChainId`, and publishes the same value to L1 via a native log. This is *by design* today (and `SystemContext` explicitly documents that external contracts should not rely on this value), but any future code that assumes this field is trustless or L1‑validated could be misled.  
   - **Details**:  
     - The bootloader reads the settlement layer chain id from an operator‑initialized memory slot:
       ```yul
       function SETTLEMENT_LAYER_CHAIN_ID_SLOT() -> ret {
           ret := add(INTEROP_ROOT_ROLLING_HASH_SLOT(), 1)
       }

       function getSettlementLayerChainId() -> ret {
           ret := mload(SETTLEMENT_LAYER_CHAIN_ID_BYTE())
       }
       ```
     - At the start of the batch:
       ```yul
       let SETTLEMENT_LAYER_CHAIN_ID := getSettlementLayerChainId()
       ...
       setNewBatch(PREV_BATCH_HASH, NEW_BATCH_TIMESTAMP, NEW_BATCH_NUMBER, EXPECTED_BASE_FEE)
       setSettlementLayerChainId(SETTLEMENT_LAYER_CHAIN_ID)
       ```
     - For non‑priority L1 upgrade transactions:
       ```yul
       // inside processL1Tx, default branch (isPriorityOp == 0)
       let SETTLEMENT_LAYER_CHAIN_ID := getSettlementLayerChainId()
       setSettlementLayerChainId(SETTLEMENT_LAYER_CHAIN_ID)
       ```
     - At the end of the batch, the same memory value is sent to L1:
       ```yul
       sendToL1Native(true, settlementLayerChainIdLogKey(), getSettlementLayerChainId())
       ```

     On the `SystemContext` side:
     ```solidity
     uint256 public currentSettlementLayerChainId;

     function setSettlementLayerChainId(uint256 _newSettlementLayerChainId) external onlyCallFromBootloader {
         /// Before the genesis upgrade is processed, the block.chainid is wrong. So we skip ...
         if (currentSettlementLayerChainId != _newSettlementLayerChainId && block.chainid != HARD_CODED_CHAIN_ID) {
             L2_CHAIN_ASSET_HANDLER.setSettlementLayerChainId(currentSettlementLayerChainId, _newSettlementLayerChainId);
             currentSettlementLayerChainId = _newSettlementLayerChainId;
         }
     }
     ```
     There is no cross‑check between the operator‑supplied value in bootloader memory and any L1 or protocol‑level source of truth; the operator effectively chooses the new settlement layer chain id.

     The comment in `SystemContext` clarifies this is **not intended to be a trustless signal for external contracts**:
     ```solidity
     /// @notice The chainId of the settlement layer.
     /// @notice This value will be deprecated in the future, it should not be used by external contracts.
     uint256 public currentSettlementLayerChainId;
     ```

     So **today** this is safe by design, provided that:
     - Only the protocol’s own contracts (e.g. `L2_CHAIN_ASSET_HANDLER`) rely on it, and
     - They treat it as operator‑controlled configuration, not as a cryptographic commitment.

   - **Recommendation**:  
     - Document more prominently (in both the bootloader docs and `SystemContext`/bridging docs) that:
       - `currentSettlementLayerChainId` and the corresponding L1 log are *operator‑provided configuration*, not a trustless signal.
     - If in the future any contract (on L1 or L2) intends to treat this value as trustless, add:
       - A cross‑check against L1 configuration/state, and/or
       - A commitment scheme in L1 contracts that ensures the operator cannot unilaterally change it.


## Open issues / areas requiring out‑of‑scope code

The following aspects look security‑sensitive but cannot be fully validated with the provided sources:

1. **L1↔L2 settlement layer handling and `L2_CHAIN_ASSET_HANDLER`**  
   - We see calls from `SystemContext.setSettlementLayerChainId` to `L2_CHAIN_ASSET_HANDLER.setSettlementLayerChainId(current, new)`, but the implementation of `L2_CHAIN_ASSET_HANDLER` is not in scope.  
   - To validate that malicious settings of `currentSettlementLayerChainId` cannot cause fund loss or cross‑chain misrouting, we would need:
     - The full code of `L2_CHAIN_ASSET_HANDLER` (and related bridge contracts), and  
     - The L1 contracts that consume the `settlementLayerChainIdLogKey()` log.

2. **Correctness of L1–L2 priority transaction hashing and validation**  
   - The bootloader computes:
     - `canonicalL1TxHash` via `getCanonicalL1TxHash`, and  
     - A rolling hash of priority L1→L2 transactions in `PRIORITY_TXS_L1_DATA`, which is later emitted to L1 via native logs.  
   - Ensuring this exactly matches what the L1 `Executor`/priority queue facets expect would require:
     - The L1 `Executor` / priority queue code, and  
     - Any spec or tests that tie `canonicalL1TxHash` to the L1 encoding.

3. **Only‑bootloader access control in system contracts**  
   - The security of many calls (`SystemContext.setNewBatch/setL2Block/...`, `L2InteropRootStorage.addInteropRoot`, etc.) relies on `onlyCallFromBootloader` / `onlySystemCall` modifiers inside `SystemContractBase` and related helpers.  
   - To confirm there is no way for a user contract to spoof a bootloader/system call, we would need:
     - The implementation of `SystemContractBase`, `SystemContractHelper`, and `SystemContractsCaller`, and  
     - The VM semantics for `isSystem` calls (already partially documented, but full verification would need the actual code).

4. **Bytecode compression and `BYTECODE_COMPRESSOR_ADDR`**  
   - The bootloader’s `sendCompressedBytecode` enforces ABI structure and re-checks the returned hash, but the safety of bytecode publication ultimately also depends on:
     - `BYTECODE_COMPRESSOR` implementation, and  
     - `KNOWN_CODES_CONTRACT`’s rules for marking code as known/valid.  
   - These are not included, so we cannot fully audit the end‑to‑end invariants around code publication.

If you can provide these additional contracts/specs, I can extend the analysis to cover those invariants more rigorously.