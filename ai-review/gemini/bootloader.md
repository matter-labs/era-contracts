## Security issues

### 1. Fragile Backward Compatibility Check in `setSettlementLayerChainId`

- **Title**: Implicit dependence on contract deployment state for system upgrade logic
- **Severity**: Low
- **Impact**: The bootloader contains hardcoded logic to bypass a call to `setSettlementLayerChainId` if the `L2_INTEROP_CENTER_ADDR` is not deployed. If the system enters a state where the interop center is deployed but the `SystemContext` is not yet upgraded to support `setSettlementLayerChainId`, or vice versa, the batch execution could revert unexpectedly or fail to initialize critical parameters.
- **Description**: 
  In `proved_batch.yul`, the function `setSettlementLayerChainId` attempts to call `SYSTEM_CONTEXT_ADDR`. If this call fails, it executes a check to decide whether to revert or ignore the failure:
  ```yul
  if iszero(success) {
      // ...
      let codeSize := getCodeSize(L2_INTEROP_CENTER_ADDR())
      let codeSize2 := getCodeSize(add(L2_INTEROP_ROOT_STORAGE(), 10)) // Arbitrary address check?
      if iszero(eq(codeSize, codeSize2)) {
          revertWithReason(FAILED_TO_SET_NEW_SETTLEMENT_LAYER_CHAIN_ID_ERR_CODE(), 1)
      }
  }
  ```
  This logic infers the system version based on the code size of `L2_INTEROP_CENTER_ADDR`. This coupling makes the bootloader's robustness dependent on the specific order of contract deployments/upgrades, which is a fragile pattern ("feature detection" via side effects).

### 2. Hardcoded Constraint on Interop Root Sides
- **Title**: Mismatch in Interop Root Sides flexibility between Bootloader and Storage
- **Severity**: Informational
- **Impact**: While not an immediate vulnerability, this creates an upgrade hazard. If the Bootloader is updated to support multiple sides (as hinted by the generic loop in `callL2InteropRootStorage`) before `L2InteropRootStorage` is upgraded, batches will revert, causing a denial of service.
- **Description**:
  The Bootloader's `callL2InteropRootStorage` function generic loop handles `sidesLength` of any size. However, the `L2InteropRootStorage.sol` contract strictly enforces:
  ```solidity
  if (sides.length != 1) {
      revert SidesLengthNotOne();
  }
  ```
  The bootloader constructs a call with dynamic sides, but the system contract rejects anything other than 1. This inconsistency implies the Bootloader assumes a capability that the System Contract explicitly denies.

### 3. Potential Batch DoS via L1->L2 Transaction Refund Failure
- **Title**: L1->L2 Transaction processing reverts entire batch if refund fails
- **Severity**: Low
- **Impact**: If an L1->L2 transaction fails execution and the subsequent refund minting also fails, the entire batch will revert. Since L1->L2 transactions are mandatory (priority operations), this could halt the L2 chain processing.
- **Description**:
  In `processL1Tx` (in `proved_batch.yul`), if the transaction execution fails (`success` is 0), the bootloader attempts to refund the user:
  ```yul
  mintEther(refundRecipient, toRefundRecipient, false)
  ```
  The third argument `false` means `useNearCallPanic` is disabled. Inside `mintEther`:
  ```yul
  if iszero(success) {
      switch useNearCallPanic
      case 0 {
          revertWithReason(MINT_ETHER_FAILED_ERR_CODE(), 0)
      }
      // ...
  }
  ```
  If `mintEther` fails (e.g., due to an issue in `ETH_L2_TOKEN_ADDR`), the bootloader reverts with `MINT_ETHER_FAILED_ERR_CODE`, crashing the batch. While `ETH_L2_TOKEN_ADDR` is a system contract and unlikely to fail, this strict dependency creates a theoretical DoS vector for the chain if the token contract enters a state where minting reverts.

### 4. Lack of Validation for `numberOfRoots` in Operator Memory
- **Title**: Reliance on Operator for Interop Root Loop Bounds
- **Severity**: Informational
- **Impact**: A malicious operator can provide an excessively large `numberOfRoots` in the `TX_OPERATOR_L2_BLOCK_INFO` memory region. This would cause the `setInteropRoots` loop in the bootloader to run for many iterations, potentially consuming excessive gas that is not charged to a specific user (as this runs in the bootloader overhead context).
- **Description**:
  In `setInteropRootForBlock`, the loop bound is derived directly from memory:
  ```yul
  let numberOfRoots := getNumberOfInteropRootInCurrentBlock()
  // ...
  let finalInteropRootNumber := add(nextInteropRootNumber, sub(numberOfRoots, 1))
  for {let i := nextInteropRootNumber} lt(i, finalInteropRootNumber) {i := add(i, 1)} { ... }
  ```
  There is no explicit cap on `numberOfRoots` checked against a hardcoded system limit within the loop initialization itself (though `i` is checked against `MAX_INTEROP_ROOTS_IN_BATCH` inside the loop). Relying on the inner check is safe, but essentially allows the operator to waste bootloader execution cycles up to the panic limit.