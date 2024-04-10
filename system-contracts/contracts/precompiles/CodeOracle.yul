/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's `extcodecopy` behavior.
 */
object "CodeOracle" {
    code {
        return(0, 0)
    }
    object "CodeOracle_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @notice The fixed address of the known code storage contract.
            function KNOWN_CODES_CONTRACT_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008004
            }

            /// @notice The maximum value of the `uint32` type.
            function UINT32_MAX() -> ret {
                // 2^32 - 1
                ret := 4294967295
            }

            ////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            ////////////////////////////////////////////////////////////////
            
            /// @notice The function that returns whether a certain versioned hash is marked as `known`
            /// @param versionedHash The versioned hash to check
            /// @return Whether the versioned hash is known
            function isCodeHashKnown(versionedHash) -> ret {
                // 1. Selector for `KnownCodesStorage.getMarker(bytes32)`
                mstore(0, 0x4c6314f000000000000000000000000000000000000000000000000000000000)
                // 2. Input for `KnownCodesStorage.getMarker(bytes32)`
                mstore(4, versionedHash)

                let success := staticcall(
                    gas(),
                    KNOWN_CODES_CONTRACT_ADDR(),
                    0,
                    36,
                    0,
                    32
                )

                if iszero(success) {
                    // For some reason the call to the KnownCodesStorage failed.
                    // Most likely out of gas.
                    revert(0,0)
                }

                ret := mload(0)
            }

            /// @notice The cost for decommitment of a single 32-byte word.
            function decommmitCostPerWord() -> ret {
                ret := 4
            }

            /// @notice The function that performs that `decommit` operation, i.e. 
            /// given a versioned hash (i.e. `commitment` to some blob), it unpacks it 
            /// into the memory and returns it.
            /// @param versionedHash The versioned hash to decommit.
            /// @param lenInWords The length of the data in bytes to decommit.
            function decommit(versionedHash, lenInWords) {
                // The operation below are never expected to overflow since the `lenInWords` is at most 2 bytes long.
                let gasCost := mul(decommmitCostPerWord(), lenInWords)

                // The cost of the decommit operation can not exceed the maximum value of the `uint32` type.
                // This should never happen in practice, since `lenInWords` is an u16 value, but we add this check 
                // just in case.
                if gt(gasCost, UINT32_MAX()) {
                    gasCost := UINT32_MAX()
                }

                // We execute the `decommit` opcode that, given a versioned hash, unpacks the data into the memory.
                // Note, that this memory does not necessarily have to be the memory of this contract. If an unpack 
                // has happened before, we will reuse the memory page where the first unpack happened.
                //
                // This means that we have to be careful with the memory management, since in case this memory page was the first 
                // one where the `decommit` happened, its memory page will be always used as a cache for this versioned hash, 
                // regardless of correctness.
                let success := verbatim_2i_1o("decommit", versionedHash, gasCost)
                if iszero(success) {
                    // Decommitment failed
                    revert(0,0)
                }
                
                // The "real" result of the `decommit` operation is a pointer to the memory page where the data was unpacked.
                // We do not know whether the data was unpacked into the memory of this contract or not.
                //  
                // Also, for technical reasons we can not access pointers directly, so we have to copy the pointer returned by the
                // decommit operation into the `active` pointer. 
                verbatim_0i_0o("decommit_ptr_to_active")

                // This operation is never expected to overflow since the `lenInWords` is at most 2 bytes long.
                let lenInBytes := mul(lenInWords, 32) 

                // To avoid the complexity of calculating the length of the preimage in circuits, the length of the pointer is always fixed to 2^21 bytes.
                // So the amount of data actually copied is determined here.
                // Note, that here we overwrite the first `lenInBytes` bytes of the memory, but it is fine since the written values are equivalent
                // to the bytes previously written there by the `decommit` operation (in case this is the first page where the decommit happened).
                // In the future we won't do this and simply return the pointer returned by the `decommit` operation, shrunk to the `lenInBytes` length.
                verbatim_3i_0o("active_ptr_data_copy", 0, 0, lenInBytes)

                return(0, lenInBytes)
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            let versionedCodeHash := calldataload(0)

            // Can not decommit unknown code
            if iszero(isCodeHashKnown(versionedCodeHash)) {
                revert(0, 0)
            }

            let version := shr(248, versionedCodeHash)
            // Currently, only a single version of the code hash is supported:
            // 1. The standard zkEVM bytecode. It has the following format:
            //   - hash[0] -- version (0x01)
            //   - hash[1] -- whether the contract is being constructed
            //   - hash[2..3] -- big endian length of the bytecode in 32-byte words. This number must be odd.
            //   - hash[4..31] -- the last 28 bytes of the sha256 hash.
            // 
            // Note, that in theory it can represent just some random blob of bytes, while 
            // in practice it only represents only the corresponding bytecodes.

            switch version 
            case 1 {
                // We do not double check whether it is odd, since it assumed that only valid bytecodes
                // can pass the `isCodeHashKnown` check.
                let lengthInWords := and(shr(224, versionedCodeHash), 0xffff)
                decommit(versionedCodeHash, lengthInWords)
            }
            default {
                // Unsupported
                revert(0,0)
            }
        }
    }
}
