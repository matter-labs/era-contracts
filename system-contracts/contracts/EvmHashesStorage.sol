// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IEvmHashesStorage} from "./interfaces/IEvmHashesStorage.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {DEPLOYER_SYSTEM_CONTRACT} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The storage of this contract serves as a mapping for the EVM code hashes (keccak256) corresponding to versioned bytecode hashes.
 */
contract EvmHashesStorage is IEvmHashesStorage, SystemContractBase {
    /// @notice Stores the EVM code hash of the contract
    /// @dev No checks are made for the correctness of the data, this is the responsibility of the caller
    /// @param versionedBytecodeHash The versioned bytecode hash
    /// @param evmBytecodeHash The keccak of bytecode
    function storeEvmCodeHash(
        bytes32 versionedBytecodeHash,
        bytes32 evmBytecodeHash
    ) external override onlyCallFrom(address(DEPLOYER_SYSTEM_CONTRACT)) {
        assembly {
            sstore(versionedBytecodeHash, evmBytecodeHash)
        }
    }

    /// @notice Get the EVM code hash of the contract by it's versioned bytecode hash
    /// @param versionedBytecodeHash The versioned bytecode hash
    function getEvmCodeHash(bytes32 versionedBytecodeHash) external view override returns (bytes32) {
        assembly {
            let res := sload(versionedBytecodeHash)
            mstore(0x0, res)
            return(0x0, 0x20)
        }
    }
}
