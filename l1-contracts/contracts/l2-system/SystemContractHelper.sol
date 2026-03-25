// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Minimal subset of ZkSync-specific system-contract helper opcodes needed by
 * L2 system contracts housed in l1-contracts.
 * @dev Full version: system-contracts/contracts/libraries/SystemContractHelper.sol.
 * Only the functions actually used by contracts in this package are included here.
 */
library SystemContractHelper {
    /// @dev Address of the ZkSync-specific TO_L1 call opcode.
    address private constant TO_L1_CALL_ADDRESS = address((1 << 16) - 1);

    /// @dev Address of the ZkSync-specific META opcode.
    address private constant META_CALL_ADDRESS = address((1 << 16) - 4);

    /// @notice Send an L2-to-L1 log.
    /// @param _isService The `isService` flag.
    /// @param _key The `key` part of the L2Log.
    /// @param _value The `value` part of the L2Log.
    function toL1(bool _isService, bytes32 _key, bytes32 _value) internal {
        address callAddr = TO_L1_CALL_ADDRESS;
        assembly {
            // Ensuring that the type is bool
            _isService := and(_isService, 1)
            // This `success` is always 0, but the method always succeeds
            // (except for the cases when there is not enough gas)
            // solhint-disable-next-line no-unused-vars
            let success := call(_isService, callAddr, _key, _value, 0xFFFF, 0, 0)
        }
    }

    /// @notice Returns the number of pubdata bytes published so far in the current batch.
    /// @dev Reads the packed meta word from the META opcode; pubdataPublished occupies bits [0..31].
    function getPubdataPublished() internal view returns (uint32 pubdataPublished) {
        address callAddr = META_CALL_ADDRESS;
        uint256 meta;
        assembly {
            meta := staticcall(0, callAddr, 0, 0xFFFF, 0, 0)
        }
        // Pubdata published is in the lowest 32 bits (offset 0, size 32).
        pubdataPublished = uint32(meta);
    }
}
