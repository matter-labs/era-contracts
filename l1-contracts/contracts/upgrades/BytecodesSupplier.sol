// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {ZKSyncOSBytecodeInfo} from "../common/libraries/ZKSyncOSBytecodeInfo.sol";
import {EraBytecodeAlreadyPublished, EVMBytecodeAlreadyPublished} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Contract that is used to track published L2 bytecodes.
/// It will be the contract to which the preimages for the factory dependencies protocol upgrade transaction
/// will be submitted to.
/// @dev The contract has no access control as anyone is allowed to publish any bytecode.
contract BytecodesSupplier is Initializable {
    /// @notice Event emitted when an Era bytecode is published.
    /// @dev Named `BytecodePublished` (not `EraBytecodePublished`) for backwards compatibility.
    event BytecodePublished(bytes32 indexed bytecodeHash, bytes bytecode);

    /// @notice Event emitted when an EVM bytecode is published.
    event EVMBytecodePublished(bytes32 indexed bytecodeHash, bytes bytecode);

    /// @notice Mapping of Era bytecode hashes to the block number when they were published.
    /// @dev Named `publishingBlock` (not `eraPublishingBlock`) for backwards compatibility.
    mapping(bytes32 bytecodeHash => uint256 blockNumber) public publishingBlock;

    /// @notice Mapping of EVM bytecode hashes to the block number when they were published.
    mapping(bytes32 bytecodeHash => uint256 blockNumber) public evmPublishingBlock;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract.
    function initialize() external initializer {}

    /// @notice Publishes an Era bytecode hash and the bytecode itself.
    /// @param _bytecode Bytecode to be published.
    function publishEraBytecode(bytes calldata _bytecode) public {
        bytes32 bytecodeHash = L2ContractHelper.hashL2BytecodeCalldata(_bytecode);

        if (publishingBlock[bytecodeHash] != 0) {
            revert EraBytecodeAlreadyPublished(bytecodeHash);
        }

        publishingBlock[bytecodeHash] = block.number;

        emit BytecodePublished(bytecodeHash, _bytecode);
    }

    /// @notice Publishes multiple Era bytecodes.
    /// @param _bytecodes Array of bytecodes to be published.
    function publishEraBytecodes(bytes[] calldata _bytecodes) external {
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _bytecodes.length; ++i) {
            publishEraBytecode(_bytecodes[i]);
        }
    }

    /// @notice Publishes an EVM bytecode hash and the bytecode itself.
    /// @param _bytecode Bytecode to be published.
    function publishEVMBytecode(bytes calldata _bytecode) public {
        bytes32 bytecodeHash = ZKSyncOSBytecodeInfo.hashEVMBytecodeCalldata(_bytecode);

        if (evmPublishingBlock[bytecodeHash] != 0) {
            revert EVMBytecodeAlreadyPublished(bytecodeHash);
        }

        evmPublishingBlock[bytecodeHash] = block.number;

        emit EVMBytecodePublished(bytecodeHash, _bytecode);
    }

    /// @notice Publishes multiple EVM bytecodes.
    /// @param _bytecodes Array of bytecodes to be published.
    function publishEVMBytecodes(bytes[] calldata _bytecodes) external {
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _bytecodes.length; ++i) {
            publishEVMBytecode(_bytecodes[i]);
        }
    }
}
