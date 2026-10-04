// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import {ZKSyncOSBytecodeInfo} from "../common/libraries/ZKSyncOSBytecodeInfo.sol";
import {EVMBytecodeAlreadyPublished} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Contract that is used to track published L2 bytecodes.
/// It will be the contract to which the preimages for the factory dependencies protocol upgrade transaction
/// will be submitted to.
/// @dev The contract has no access control as anyone is allowed to publish any bytecode.
contract BytecodesSupplier is Initializable {
    /// @notice Event emitted when an EVM bytecode is published.
    event EVMBytecodePublished(bytes32 indexed bytecodeHash, bytes bytecode);

    /// @dev Deprecated slot, retained to preserve the upgradeable storage layout. Formerly
    /// `publishingBlock`, the EraVM bytecode-hash publication registry; the Era publication
    /// path is retired and nothing reads or writes this mapping.
    // slither-disable-next-line uninitialized-state
    mapping(bytes32 bytecodeHash => uint256 blockNumber) private __DEPRECATED_publishingBlock;

    /// @notice Mapping of EVM bytecode hashes to the block number when they were published.
    mapping(bytes32 bytecodeHash => uint256 blockNumber) public evmPublishingBlock;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract.
    function initialize() external initializer {}

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
