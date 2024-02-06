/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to interact with EIP-4844 blob versioned hashes before official solidity support.
 * @dev It only should receive 1 uint256 as calldata representing the index of the blob versioned hash to return.
 * @dev If index >= len(versioned_hashes) then bytes32(0) is returned.
 */
 object "blobVersionedHashRetriever" {
    code {
        // Deploy the contract
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }
    object "runtime" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            // Pull index from calldata
            let index := calldataload(0)

            // Call the BLOB_HASH_OPCODE with the given index
            let hash := verbatim_1i_1o(hex"49", index)

            // Store blob versioned hash into memory
            mstore(0, hash)

            // Return blob versioned hash
            return (0, 32)
        }
    }
}
