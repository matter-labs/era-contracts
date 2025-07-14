// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2ContractHelper} from "../common/libraries/L2ContractHelper.sol";
import {BytecodeAlreadyPublished} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Contract that is used to track published L2 bytecodes.
/// It will be the contract to which the preimages for the factory dependencies protocol upgrade transaction
/// will be submitted to.
/// @dev The contract has no access control as anyone is allowed to publish any bytecode.
contract BytecodesSupplier {
    /// @notice Event emitted when a bytecode is published.
    event BytecodePublished(bytes32 indexed bytecodeHash, bytes bytecode);

    /// @notice Mapping of bytecode hashes to the block number when they were published.
    mapping(bytes32 bytecodeHash => uint256 blockNumber) public publishingBlock;

    /// @notice Publishes the bytecode hash and the bytecode itself.
    /// @param _bytecode Bytecode to be published.
    function publishBytecode(bytes calldata _bytecode) public {
        bytes32 bytecodeHash = L2ContractHelper.hashL2BytecodeCalldata(_bytecode);

        if (publishingBlock[bytecodeHash] != 0) {
            revert BytecodeAlreadyPublished(bytecodeHash);
        }

        publishingBlock[bytecodeHash] = block.number;

        emit BytecodePublished(bytecodeHash, _bytecode);
    }

    /// @notice Publishes multiple bytecodes.
    /// @param _bytecodes Array of bytecodes to be published.
    function publishBytecodes(bytes[] calldata _bytecodes) external {
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _bytecodes.length; ++i) {
            publishBytecode(_bytecodes[i]);
        }
    }
}
