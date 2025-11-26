The analysis of the provided system contracts (scope: `system-contracts/contracts`) identified the following security issue.

## Security issues

### 1. Unbounded L2->L1 Logs causing Batch Denial of Service
- **Severity**: High
- **Impact**: An attacker or a high-traffic batch can create a state where the L1 Batch cannot be finalized (bricked), causing a Denial of Service for the rollup.
- **Description**: 
    The `L1Messenger` contract accumulates L2->L1 logs in a sequential hash (`chainedLogsHash`) and counts them in `numberOfLogsToProcess` via the `_processL2ToL1Log` function. This function is called by `sendToL1`, which is accessible to any user willing to pay the gas/pubdata costs.

    At the end of a batch, the Bootloader calls `publishPubdataAndClearState`. This function validates the logs by reconstructing a Merkle tree. The size of this Merkle tree is hardcoded to `L2_TO_L1_LOGS_MERKLE_TREE_LEAVES` (16,384) in `Constants.sol`.

    ```solidity
    // L1Messenger.sol

    function _processL2ToL1Log(L2ToL1Log memory _l2ToL1Log) internal returns (uint256 logIdInMerkleTree) {
        // ... hashing logic ...
        chainedLogsHash = keccak256(abi.encode(chainedLogsHash, hashedLog));

        logIdInMerkleTree = numberOfLogsToProcess;
        ++numberOfLogsToProcess; // @audit-issue No check against L2_TO_L1_LOGS_MERKLE_TREE_LEAVES
        
        emit L2ToL1LogSent(_l2ToL1Log);
    }
    ```

    If `numberOfLogsToProcess` exceeds 16,384, the batch becomes unfinalizable in `publishPubdataAndClearState`:
    1. The operator must provide the logs to reconstruct `chainedLogsHash`.
    2. If the operator provides > 16,384 logs, the function reverts due to the check: `if (numberOfL2ToL1Logs > L2_TO_L1_LOGS_MERKLE_TREE_LEAVES) revert ...`.
    3. If the operator provides <= 16,384 logs, the reconstructed hash will not match the on-chain `chainedLogsHash` (which includes the excess logs), causing a `ReconstructionMismatch` revert.

    While gas limits restrict the number of logs, a high block gas limit combined with the relatively low cost of emitting logs (approx. 10k gas per log) makes exceeding 16,384 logs feasible within a single batch, leading to a permanent failure to close the batch.

    **Recommendation**:
    Add a requirement in `_processL2ToL1Log` to ensure the log counter does not exceed the Merkle tree capacity:
    ```solidity
    require(numberOfLogsToProcess < L2_TO_L1_LOGS_MERKLE_TREE_LEAVES, "Too many logs");
    ```

## Informational / Design Notes

- **`Create2Factory` System Call Constraint**: 
    The `Create2Factory` is deployed at `USER_CONTRACTS_OFFSET` (`0x10001` per `Constants.sol`), placing it outside the kernel space (`<= 0xffff`). However, it attempts to use `EfficientCall.rawCall` with `_isSystem: true` to call the `ContractDeployer`.
    Standard ZKsync VM rules typically prevent user-space contracts from setting the `isSystem` flag. If strict VM rules apply, `Create2Factory` would revert when attempting this call. If it functions correctly in practice, it implies a specific VM exception or whitelist for this address/bytecode, which is not visible in the provided Solidity sources. This is noted as a potential inconsistency between the code/docs and the enforced permissions.

- **Access Control on `DefaultAccount`**: 
    `DefaultAccount` (the code for EOAs) calls the `ContractDeployer` with `isSystem: true` to perform deployments (`create`, `create2`, etc.). Since EOAs reside in user space, this relies on the VM allowing this specific pattern or `DefaultAccount` logic to set the system flag, which is a privileged operation. The `ignoreNonBootloader` modifier on `executeTransaction` prevents malicious actors from hijacking this privilege directly, but the reliance on system-flag-setting from user space is a notable architectural detail.