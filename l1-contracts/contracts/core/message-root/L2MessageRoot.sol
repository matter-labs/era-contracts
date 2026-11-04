// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MessageRootBase} from "./MessageRootBase.sol";
import {CHAIN_TREE_EMPTY_ENTRY_HASH, SHARED_ROOT_TREE_EMPTY_HASH} from "./IMessageRoot.sol";

import {
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR
} from "../../common/l2-helpers/L2ContractAddresses.sol";

import {OnlyL1} from "../bridgehub/L1BridgehubErrors.sol";
import {MessageHashing, ProofData} from "../../common/libraries/MessageHashing.sol";

import {FullMerkleMemory} from "../../common/libraries/FullMerkleMemory.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {InvalidCaller} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The MessageRoot deployment for settlement-layer L2s. See {protocol-docs/message-root.md#aggregation-structure}.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors. This is needed for compatibility with ZKsyncOS.
contract L2MessageRoot is MessageRootBase {
    using FullMerkleMemory for FullMerkleMemory.FullTree;
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    /// @dev Chain ID of L1 for bridging reasons.
    uint256 internal l1ChainId;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _bridgehub() internal pure override returns (address) {
        return L2_BRIDGEHUB_ADDR;
    }

    function _chainAssetHandler() internal view override returns (address) {
        return L2_CHAIN_ASSET_HANDLER_ADDR;
    }

    // A method for backwards compatibility with the old implementation
    // solhint-disable-next-line func-name-mixedcase
    function BRIDGE_HUB() public pure returns (address) {
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

    /// @notice Initializes the contract.
    /// @dev Expected to be called only once by the ComplexUpgrader and during genesis only, while
    /// for already existing chains an `updateL2` function should be used.
    /// @param _l1ChainId The chain id of L1.
    function initL2(uint256 _l1ChainId) public reentrancyGuardInitializer onlyUpgrader {
        _disableInitializers();
        updateL2(_l1ChainId);
        _initialize();
    }

    function updateL2(uint256 _l1ChainId) public onlyUpgrader {
        l1ChainId = _l1ChainId;
    }

    /// @notice Computes the aggregated root of a message root that contains only `_chainId` with an
    /// empty chain tree.
    function getEmptyMultichainBatchRoot(uint256 _chainId) external pure returns (bytes32) {
        FullMerkleMemory.FullTree memory localSharedTree;
        localSharedTree.createTree(1);
        // slither-disable-next-line unused-return
        localSharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory localChainTree;
        localChainTree.createTree(1);
        bytes32 initialChainTreeHash = localChainTree.setup(CHAIN_TREE_EMPTY_ENTRY_HASH);
        bytes32 leafHash = MessageHashing.chainIdLeafHash(initialChainTreeHash, _chainId);

        return localSharedTree.pushNewLeaf(leafHash);
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
    function _noBatchFallback(uint256, uint256) internal pure override returns (bytes32) {
        return bytes32(0);
    }
}
