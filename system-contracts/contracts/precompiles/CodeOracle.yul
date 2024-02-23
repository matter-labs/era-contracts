/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract used to emulate EVM's ecrecover precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
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

            function KNOWN_CODES_CONTRACT_ADDR() -> ret {
                ret := 0x0000000000000000000000000000000000008004
            }

            ////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            ////////////////////////////////////////////////////////////////
            
            function isCodeHashKnown(versionedHash) -> ret {
                // TODO: double check whether preprocessing can remove the constant for selector

                // 1. Selector for `KnwonCodesStorage.getMarker(bytes32)`
                mstore(0, 0x4c6314f000000000000000000000000000000000000000000000000000000000)
                // 2. Input for `KnwonCodesStorage.getMarker(bytes32)`
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

            function decommmitCostPerWord() -> ret {
                ret := 4
            }

            /// @dev Returns ceil(len / 32)
            function bytesToWords(len) -> ret {
                ret := div(add(len, 31), 32)
            }

            function decommit(versionedHash, lenInBytes) {
                let lenInWords := bytesToWords(lenInBytes)
                let gasCost := mul(decommmitCostPerWord(), lenInWords)
                
                // if lt(gas(), gasCost) {
                //     // Not enough gas to decommit
                //     revert(0,0)
                // }

                // The operations below are never expected to overflow since the `lenInWords` is a most 2 bytes long.
                let success := verbatim_2i_1o("decommit", versionedHash, gasCost)

                // if iszero(success) {
                //     // Decommitment failed
                //     revert(0,0)
                // }
                
                verbatim_0i_0o("decommit_ptr_to_active")

                // The pointer is initially created with 2^16 * 32 bytes in length, so we need to only copy the relevant data.
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
            // zkSync Era supports two versions of the code hash:
            // 1. The standard zkEVM bytecode. It has the following format:
            //   - hash[0] -- version (0x01)
            //   - hash[1] -- whether the contract is being constructed
            //   - hash[2..3] -- big endian length of the bytecode in 32-byte words. This number must be odd.
            //   - hash[4..31] -- the last 28 bytes of the sha256 hash.
            // 2. EVM bytecode. It has the following format:
            //   - hash[0] -- version (0x02)
            //   - hash[1] -- whether the contract is being constructed
            //   - hash[2..3] -- big endian length of the bytecode in bytes. This number can be arbitrary.
            //   - hash[4..31] -- the last 28 bytes of the sha256 hash.
            // 
            // Note, that in theory both values can represent just some random blob of bytes, while 
            // in practice they only represent only the corresponding bytecodes.

            switch version 
            case 1 {
                // We do not double check whether it is odd, since it assumed that only valid bytecodes
                // can pass the `isCodeHashKnown` check.
                let lengthInWords := and(shr(224, versionedCodeHash), 0xffff)
                decommit(versionedCodeHash, mul(lengthInWords, 32))
            }
            case 2 {
                let lengthInBytes := and(shr(224, versionedCodeHash), 0xffff)
                decommit(versionedCodeHash, lengthInBytes)
            }
            default {
                // Unsupported
                revert(0,0)
            }
        }
    }
}
