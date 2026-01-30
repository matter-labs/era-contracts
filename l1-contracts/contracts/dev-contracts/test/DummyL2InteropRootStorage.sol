// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// import {Unauthorized} from "./SystemContractErrors.sol";
// import {BOOTLOADER_FORMAL_ADDRESS} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice InteropRootStorage contract for imported L2 interop roots.
 * @dev
 */
contract DummyL2InteropRootStorage {
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 interopRoot)) public interopRoots;
    mapping(bytes32 interopRoot => uint256 batchNumber) public batchNumberFrominteropRoot;
    mapping(bytes32 interopRoot => uint256 chainId) public chainIdFrominteropRoot;

    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32[] interopRootSides)) public interopRootSides;
    uint256 public pendingMessageRootIdsLength;
    struct PendingMessageRootId {
        uint256 chainId;
        uint256 batchNumber;
    }
    mapping(uint256 index => PendingMessageRootId) public pendingMessageRootIds;
    // mapping(bytes32 interopRoot => uint256 batchNumber) public batchNumberFrominteropRoot;

    event InteropRootAdded(uint256 indexed chainId, uint256 indexed batchNumber, bytes32[] sides);

    function addInteropRoot(uint256 chainId, uint256 batchNumber, bytes32[] memory sides) external {
        emit InteropRootAdded(chainId, batchNumber, sides);
        if (sides.length == 1) {
            interopRoots[chainId][batchNumber] = sides[0];
            batchNumberFrominteropRoot[sides[0]] = batchNumber;
            chainIdFrominteropRoot[sides[0]] = chainId;
        } else {
            // interopRootSides[chainId][batchNumber] = sides;
            // pendingMessageRootIds[pendingMessageRootIdsLength] = PendingMessageRootId({
            //     chainId: chainId,
            //     batchNumber: batchNumber
            // });
            // pendingMessageRootIdsLength++;
        }
    }

    function addThisChainInteropRoot(uint256 batchNumber, bytes32[] memory sides) external {
        interopRoots[block.chainid][batchNumber] = sides[0];
        batchNumberFrominteropRoot[sides[0]] = batchNumber;
        chainIdFrominteropRoot[sides[0]] = block.chainid;
    }
}
