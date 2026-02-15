// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MessageRootBase} from "./MessageRootBase.sol";

import {L2_BRIDGEHUB_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";

import {OnlyL1} from "../bridgehub/L1BridgehubErrors.sol";
import {MessageHashing, ProofData} from "../../common/libraries/MessageHashing.sol";

import {FullMerkle} from "../../common/libraries/FullMerkle.sol";
import {DynamicIncrementalMerkle} from "../../common/libraries/DynamicIncrementalMerkle.sol";
import {InvalidCaller, Unauthorized} from "../../common/L1ContractErrors.sol";
import {SERVICE_TRANSACTION_SENDER} from "../../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2MessageRoot is MessageRootBase {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    /// @dev Chain ID of L1 for bridging reasons.
    uint256 internal l1ChainId;

    /// @notice The chain id of the Gateway chain.
    uint256 public ERA_GATEWAY_CHAIN_ID;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _bridgehub() internal view override returns (address) {
        return L2_BRIDGEHUB_ADDR;
    }

    function _eraGatewayChainId() internal view override returns (uint256) {
        return ERA_GATEWAY_CHAIN_ID;
    }

    // A method for backwards compatibility with the old implementation
    // solhint-disable-next-line func-name-mixedcase
    function BRIDGE_HUB() public view returns (address) {
        return L2_BRIDGEHUB_ADDR;
    }

    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() public view override returns (uint256) {
        return l1ChainId;
    }

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    modifier onlyServiceTransactionSender() {
        require(msg.sender == SERVICE_TRANSACTION_SENDER, Unauthorized(msg.sender));
        _;
    }

    /// @notice Initializes the contract.
    /// @dev This function is used to initialize the contract with the initial values.
    /// @param _l1ChainId The chain id of L1.
    function initL2(uint256 _l1ChainId, uint256 _eraGatewayChainId) public onlyUpgrader {
        _disableInitializers();
        ERA_GATEWAY_CHAIN_ID = _eraGatewayChainId;
        l1ChainId = _l1ChainId;
        _initialize();
    }

    /// @notice Adds a new chainBatchRoot to the chainTree.
    /// @param _chainId The ID of the chain whose chainBatchRoot is being added to the chainTree.
    /// @param _batchNumber The number of the batch to which _chainBatchRoot belongs.
    /// @param _chainBatchRoot The value of chainBatchRoot which is being added.
    function addChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _chainBatchRoot) public override {
        super.addChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);

        // Push chainBatchRoot to the chainTree related to specified chainId and get the new root.
        bytes32 chainRoot;
        // slither-disable-next-line unused-return
        (, chainRoot) = chainTree[_chainId].push(MessageHashing.batchLeafHash(_chainBatchRoot, _batchNumber));

        emit AppendedChainBatchRoot(_chainId, _batchNumber, _chainBatchRoot);

        // Update leaf corresponding to the specified chainId with newly acquired value of the chainRoot.
        bytes32 cachedChainIdLeafHash = MessageHashing.chainIdLeafHash(chainRoot, _chainId);
        bytes32 sharedTreeRoot = sharedTree.updateLeaf(chainIndex[_chainId], cachedChainIdLeafHash);

        emit NewChainRoot(_chainId, chainRoot, cachedChainIdLeafHash);

        _emitRoot(sharedTreeRoot);
        historicalRoot[block.number] = sharedTreeRoot;
    }

    function _proveL2LeafInclusionOnSettlementLayer(
        uint256,
        uint256,
        ProofData memory,
        bytes32[] calldata,
        uint256
    ) internal pure override returns (bool) {
        revert OnlyL1();
    }

    /// @inheritdoc MessageRootBase
    function _noBatchFallback(uint256 _chainId, uint256 _batchNumber) internal view override returns (bytes32) {
        return bytes32(0);
    }

    /// @notice emit a new message root when committing a new batch
    function _emitRoot(bytes32 _root) internal {
        // What happens here is we query for the current sharedTreeRoot and emit the event stating that new InteropRoot is "created".
        // The reason for the usage of "bytes32[] memory _sides" to store the InteropRoot is explained in L2InteropRootStorage contract.
        bytes32[] memory _sides = new bytes32[](1);
        _sides[0] = _root;

        uint256 currentCount = totalPublishedInteropRoots;
        totalPublishedInteropRoots = currentCount + 1;

        emit NewInteropRoot(block.chainid, block.number, currentCount, _sides);
    }

    function updateFullTree() public {
        uint256 cachedChainCount = chainCount;
        bytes32[] memory newLeaves = new bytes32[](cachedChainCount);
        for (uint256 i = 0; i < cachedChainCount; ++i) {
            uint256 chainId = chainIndexToId[i];
            newLeaves[i] = MessageHashing.chainIdLeafHash(chainTree[chainId].root(), chainId);
        }
        bytes32 newRoot = sharedTree.updateAllLeaves(newLeaves);
        _emitRoot(newRoot);
        historicalRoot[block.number] = newRoot;
    }
}
