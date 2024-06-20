// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// slither-disable-next-line unused-return
// solhint-disable reason-string, gas-custom-errors

// import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
// import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {DynamicIncrementalMerkle} from "../common/libraries/openzeppelin/IncrementalMerkle.sol"; // todo figure out how to import from OZ

import {IBridgehub} from "./IBridgehub.sol";
// import {IL1SharedBridge} from "../bridge/interfaces/IL1SharedBridge.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
// import {IStateTransitionManager} from "../state-transition/IStateTransitionManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
// import {IZkSyncHyperchain} from "../state-transition/chain-interfaces/IZkSyncHyperchain.sol";
// import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS} from "../common/Config.sol";
// import {BridgehubL2TransactionRequest, L2CanonicalTransaction, L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
// import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";

import {FullMerkle} from "../common/libraries/FullMerkle.sol";

contract MessageRoot is IMessageRoot, ReentrancyGuard {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;
    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    uint256 public chainCount;

    mapping(uint256 chainId => uint256 chainIndex) public chainIndex;

    mapping(uint256 chainIndex => uint256 chainId) public chainIndexToId;

    FullMerkle.FullTree public sharedTree;

    /// @dev the incremental merkle tree storing the chain message roots
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;

    /// @notice only the bridgehub can call
    modifier onlyBridgehub() {
        require(msg.sender == address(BRIDGE_HUB), "MR: only bridgehub");
        _;
    }

    /// @notice only the bridgehub can call
    modifier onlyChain(uint256 _chainId) {
        require(msg.sender == BRIDGE_HUB.getHyperchain(_chainId), "MR: only chain");
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IBridgehub _bridgehub) reentrancyGuardInitializer {
        BRIDGE_HUB = _bridgehub;
        _initialize();
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
    function initialize() external reentrancyGuardInitializer {
        _initialize();
    }

    function _initialize() internal {
        // slither-disable-next-line unused-return
        sharedTree.setup(bytes32(0));
    }

    function addNewChain(uint256 _chainId) external onlyBridgehub {
        chainIndex[_chainId] = chainCount;
        chainIndexToId[chainCount] = _chainId;
        ++chainCount;
        // slither-disable-next-line unused-return
        bytes32 initialHash = chainTree[_chainId].setup(keccak256("New Tree zero hash"));
        // slither-disable-next-line unused-return
        sharedTree.pushNewLeaf(initialHash);
    }

    function chainMessageRoot(uint256 _chainId) external view override returns (bytes32) {
        return chainTree[_chainId].root();
    }

    /// @dev add a new chainBatchRoot to the chainTree
    function addChainBatchRoot(
        uint256 _chainId,
        bytes32 _chainBatchRoot,
        bool _updateFullTree
    ) external onlyChain(_chainId) {
        bytes32 chainRoot;
        // slither-disable-next-line unused-return
        (, chainRoot) = chainTree[_chainId].push(_chainBatchRoot);

        if (_updateFullTree) {
            // slither-disable-next-line unused-return
            sharedTree.updateLeaf(chainIndex[_chainId], chainRoot);
        }
    }

    function updateFullTree() external {
        bytes32[] memory newLeaves;
        for (uint256 i = 0; i < chainCount; ++i) {
            newLeaves[i] = chainTree[chainIndexToId[i]].root();
        }
        // slither-disable-next-line unused-return
        sharedTree.updateAllLeaves(newLeaves);
    }
}
