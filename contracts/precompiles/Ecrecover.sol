// SPDX-License-Identifier: MIT OR Apache-2.0

pragma solidity ^0.8.0;

import "../libraries/SystemContractHelper.sol";

/**
 * @author Matter Labs
 * @notice The contract used to emulate EVM's ecrecover precompile.
 * @dev It uses `precompileCall` to call the zkEVM built-in precompiles.
 */
contract Ecrecover {
    /// @dev The price in gas for the precompile.
    uint256 constant ECRECOVER_COST_GAS = 1112;
    /// @dev The offset for the data for ecrecover.
    uint32 constant INPUT_OFFSET_IN_WORDS = 4;
    ///@dev The input for the precompile contains 4 words: the signed digest, v, r, s.
    uint32 constant INPUT_LENGTH_IN_WORDS = 4;
    /// @dev The output is written to the first word.
    uint32 constant OUTPUT_OFFSET_IN_WORDS = 0;
    /// @dev The output is a single word -- the address of the account.
    uint32 constant OUTPUT_LENGTH_IN_WORDS = 1;

    uint256 constant SECP256K1_GROUP_SIZE = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    fallback() external {
        address codeAddress = SystemContractHelper.getCodeAddress();
        // Check that we are NOT in delegatecall
        require(codeAddress == address(this));

        // Do manual memory management
        unchecked {
            bytes32 digest;
            uint256 v;
            uint256 r;
            uint256 s;

            bool isValid = true;

            // Manually decode the input
            assembly {
                digest := calldataload(0)
                v := calldataload(32)
                r := calldataload(64)
                s := calldataload(96)
            }

            // Validate the input by the yellow paper rules (Appendix E. Precompiled contracts)
            if (v != 27 && v != 28) {
                isValid = false;
            }
            if (s == 0 || s >= SECP256K1_GROUP_SIZE) {
                isValid = false;
            }
            if (r == 0 || r >= SECP256K1_GROUP_SIZE) {
                isValid = false;
            }

            if (!isValid) {
                assembly {
                    return(0, 0)
                }
            }

            uint256 offset;
            // Get the offset from the free memory pointer and store precompile input there
            assembly {
                // The free memory pointer
                offset := mload(0x40)
                mstore(offset, digest)
                mstore(add(offset, 0x20), sub(v, 27))
                mstore(add(offset, 0x40), r)
                mstore(add(offset, 0x60), s)
                // Note: Do not update the free memory pointer on the purpose
                // Precompile call below doesn't allocate memory, so the written values wouldn't be changed
            }

            // Check the invariant of the expected offset value
            assert(offset == INPUT_OFFSET_IN_WORDS * 32);

            uint256 precompileParams = SystemContractHelper.packPrecompileParams(
                INPUT_OFFSET_IN_WORDS,
                INPUT_LENGTH_IN_WORDS,
                OUTPUT_OFFSET_IN_WORDS,
                OUTPUT_LENGTH_IN_WORDS,
                0
            );

            uint256 gasToPay = ECRECOVER_COST_GAS;
            bool success = SystemContractHelper.precompileCall(precompileParams, uint32(gasToPay));
            require(success);

            // Internal check for the ECRECOVER implementation routine
            uint256 successInternal;
            assembly {
                successInternal := mload(0)
            }

            if (successInternal != 1) {
                // Return empty data
                assembly {
                    return(0, 0)
                }
            }

            // Return the decoded address
            assembly {
                return(32, 32)
            }
        }
    }
}
