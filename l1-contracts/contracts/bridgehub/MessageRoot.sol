// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-v4/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";

import {DynamicIncrementalMerkle} from "../common/libraries/DynamicIncrementalMerkle.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";

import {IBridgehub} from "./IBridgehub.sol";

import {IMessageRoot} from "./IMessageRoot.sol";
import {InvalidProof, Unauthorized} from "../common/L1ContractErrors.sol";
import {ChainBatchRootAlreadyExists, ChainExists, MessageRootNotRegistered, OnlyAssetTracker, OnlyBridgehubOrChainAssetHandler, OnlyBridgehubOwner, OnlyChain, OnlyPreV30Chain, NotWhitelistedSettlementLayer, OnlyL1, IncorrectFunctionSignature, V30UpgradeGatewayBlockNumberAlreadySet} from "./L1BridgehubErrors.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_MESSAGE_ROOT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {FullMerkle} from "../common/libraries/FullMerkle.sol";
import {FinalizeL1DepositParams} from "../bridge/interfaces/IL1Nullifier.sol";

import {MessageHashing, ProofData} from "../common/libraries/MessageHashing.sol";

import {MessageVerification} from "../common/MessageVerification.sol";
import {SERVICE_TRANSACTION_SENDER} from "../common/Config.sol";

import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant CHAIN_TREE_EMPTY_ENTRY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// The single shared tree consists of the roots of chain trees as its leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant SHARED_ROOT_TREE_EMPTY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The MessageRoot contract is responsible for storing the cross message roots of the chains and the aggregated root of all chains.
contract MessageRoot is IMessageRoot, Initializable, MessageVerification {
    using FullMerkle for FullMerkle.FullTree;
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    uint256 public immutable L1_CHAIN_ID;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @notice The number of chains that are registered.
    uint256 public chainCount;

    /// @notice The mapping from chainId to chainIndex. Note index 0 is maintained for the chain the contract is on.
    mapping(uint256 chainId => uint256 chainIndex) public chainIndex;

    /// @notice The mapping from chainIndex to chainId.
    mapping(uint256 chainIndex => uint256 chainId) public chainIndexToId;

    /// @notice The shared full merkle tree storing the aggregate hash.
    FullMerkle.FullTree public sharedTree;

    /// @dev The incremental merkle tree storing the chain message roots.
    mapping(uint256 chainId => DynamicIncrementalMerkle.Bytes32PushTree tree) internal chainTree;

    /// @notice The mapping from block number to the global message root.
    /// @dev Each block might have multiple txs that change the historical root. You can safely use the final root in the block,
    /// since each new root cumulatively aggregates all prior changes — so the last root always contains (at minimum) everything
    /// from the earlier ones.
    mapping(uint256 blockNumber => bytes32 globalMessageRoot) public historicalRoot;

    /// @notice The mapping from chainId to batchNumber to chainBatchRoot.
    /// @dev These are the same values as the leaves of the chainTree.
    /// @dev We store these values for message verification on L1 and Gateway.
    /// @dev We only update the chainTree on GW as of V30.
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 chainRoot)) public chainBatchRoots;

    /// @notice The address of the asset tracker.
    address public assetTracker;

    /// @notice The mapping storing the batch number at the moment the MessageRoot was updated to V30.
    /// @notice We store this, as we did not store chainBatchRoots prior to V30, so we need to get them from the diamond proxies of the chains.
    mapping(uint256 chainId => uint256 batchNumber) public v30UpgradeChainBatchNumber;

    /// @notice The block number at the moment the MessageRoot was updated to V30.
    /// @notice We store this, as it is used on the L2s to filter out old interop roots.
    uint256 public v30UpgradeGatewayBlockNumber;

    /// @dev The chain type manager for EraVM chains. EraVM chains are upgraded directly by governance,
    /// @dev so they can be trusted more than ZKsync OS chains, or chains from other CTMs.
    /// @dev Introduced with V30.
    address public eraVmChainTypeManager;

    /// @notice Checks that the message sender is the bridgehub or the chain asset handler.
    modifier onlyBridgehubOrChainAssetHandler() {
        if (msg.sender != address(BRIDGE_HUB) && msg.sender != address(BRIDGE_HUB.chainAssetHandler())) {
            revert OnlyBridgehubOrChainAssetHandler(
                msg.sender,
                address(BRIDGE_HUB),
                address(BRIDGE_HUB.chainAssetHandler())
            );
        }
        _;
    }

    /// @notice Checks that the message sender is the specified ZK Chain.
    /// @param _chainId The ID of the chain that is required to be the caller.
    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != BRIDGE_HUB.getZKChain(_chainId)) {
            revert OnlyChain(msg.sender, BRIDGE_HUB.getZKChain(_chainId));
        }
        _;
    }

    /// On L1, the chain can add it directly.
    /// On GW, the asset tracker should add it,
    /// except for PreV30 chains, which can add it directly.
    modifier addChainBatchRootRestriction(uint256 _chainId) {
        if (block.chainid != L1_CHAIN_ID) {
            if (msg.sender == assetTracker) {
                // this case is valid.
            } else if (v30UpgradeChainBatchNumber[_chainId] != 0) {
                address chain = BRIDGE_HUB.getZKChain(_chainId);
                uint32 minor;
                (, minor, ) = IGetters(chain).getSemverProtocolVersion();
                /// This might be a security issue if v29 has prover bugs. We should upgrade GW chains to v30 quickly.
                require(msg.sender == chain, OnlyChain(msg.sender, chain));
                /// we only allow direct addChainBatchRoots for EraVM chains, as only they are governed directly by governance.
                require(BRIDGE_HUB.chainTypeManager(_chainId) == eraVmChainTypeManager, OnlyChain(msg.sender, chain));
                require(minor < 30, OnlyPreV30Chain(_chainId));
            } else {
                revert OnlyAssetTracker(msg.sender, assetTracker);
            }
        } else {
            if (msg.sender != BRIDGE_HUB.getZKChain(_chainId)) {
                revert OnlyChain(msg.sender, BRIDGE_HUB.getZKChain(_chainId));
            }
        }
        _;
    }

    modifier onlyBridgehubOwner() {
        if (msg.sender != Ownable(address(BRIDGE_HUB)).owner()) {
            revert OnlyBridgehubOwner(msg.sender, Ownable(address(BRIDGE_HUB)).owner());
        }
        _;
    }

    modifier onlyServiceTransactionSender() {
        require(msg.sender == SERVICE_TRANSACTION_SENDER, Unauthorized(msg.sender));
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation on L1, but as a system contract on L2.
    /// This means we call the _initialize in both the constructor and the initialize functions.
    /// @dev Initialize the implementation to prevent Parity hack.
    /// @param _bridgehub Address of the Bridgehub.
    constructor(IBridgehub _bridgehub) {
        BRIDGE_HUB = _bridgehub;
        L1_CHAIN_ID = BRIDGE_HUB.L1_CHAIN_ID();
        if (L1_CHAIN_ID != block.chainid) {
            /// On Gateway we save the chain type manager for EraVM chains.
            uint256[] memory allZKChains = BRIDGE_HUB.getAllZKChainChainIDs();
            if (allZKChains.length > 0) {
                // On non-local environments we need to save the eraVM chain type manager to allow v29 chains to finalize.
                eraVmChainTypeManager = BRIDGE_HUB.chainTypeManager(allZKChains[0]);
            }
            /// On Gateway we save the upgrade block number
            v30UpgradeGatewayBlockNumber = block.number;
        }
        _initialize();
        _disableInitializers();
    }

    /// @dev Initializes a contract for later use. Expected to be used in the proxy on L1, on L2 it is a system contract without a proxy.
    function initialize() external initializer {
        _initialize();
    }

    /// @dev The initialized used for the V30 upgrade.
    function initializeV30Upgrade() external initializer {
        uint256[] memory allZKChains = BRIDGE_HUB.getAllZKChainChainIDs();
        uint256 allZKChainsLength = allZKChains.length;
        for (uint256 i = 0; i < allZKChainsLength; ++i) {
            v30UpgradeChainBatchNumber[allZKChains[i]] = IGetters(BRIDGE_HUB.getZKChain(allZKChains[i]))
                .getTotalBatchesExecuted();
        }
        /// If there are no chains, that means we are using the contracts locally.
        if (allZKChainsLength == 0) {
            v30UpgradeGatewayBlockNumber = 1;
        }
    }

    function sendV30UpgradeGatewayBlockNumberFromGateway(uint256) external {
        // Send the message corresponding to the relevant InteropBundle to L1.
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(
            abi.encodeCall(this.sendV30UpgradeGatewayBlockNumber, (v30UpgradeGatewayBlockNumber))
        );
    }

    function saveV30UpgradeGatewayBlockNumberOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        bool success = proveL1DepositParamsInclusion(_finalizeWithdrawalParams, L2_MESSAGE_ROOT_ADDR);
        if (!success) {
            revert InvalidProof();
        }

        require(
            BRIDGE_HUB.whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
            NotWhitelistedSettlementLayer(_finalizeWithdrawalParams.chainId)
        );
        require(block.chainid == L1_CHAIN_ID, OnlyL1());

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_finalizeWithdrawalParams.message, 0);
        require(
            bytes4(functionSignature) == this.sendV30UpgradeGatewayBlockNumber.selector,
            IncorrectFunctionSignature()
        );

        require(v30UpgradeGatewayBlockNumber == 0, V30UpgradeGatewayBlockNumberAlreadySet());
        (uint256 receivedV30UpgradeGatewayBlockNumber, ) = UnsafeBytes.readUint256(
            _finalizeWithdrawalParams.message,
            offset
        );
        v30UpgradeGatewayBlockNumber = receivedV30UpgradeGatewayBlockNumber;
    }

    function saveV30UpgradeGatewayBlockNumberOnL2(
        uint256 _v30UpgradeGatewayBlockNumber
    ) external onlyServiceTransactionSender {
        v30UpgradeGatewayBlockNumber = _v30UpgradeGatewayBlockNumber;
    }

    function setAddresses(address _assetTracker) external onlyBridgehubOwner {
        assetTracker = _assetTracker;
    }

    /// @notice Adds a single chain to the message root.
    /// @param _chainId The ID of the chain that is being added to the message root.
    function addNewChain(uint256 _chainId) external onlyBridgehubOrChainAssetHandler {
        if (chainRegistered(_chainId)) {
            revert ChainExists();
        }
        _addNewChain(_chainId);
    }

    function chainRegistered(uint256 _chainId) public view returns (bool) {
        return (_chainId == block.chainid || chainIndex[_chainId] != 0);
    }

    /// @notice Adds a new chainBatchRoot to the chainTree.
    /// @param _chainId The ID of the chain whose chainBatchRoot is being added to the chainTree.
    /// @param _batchNumber The number of the batch to which _chainBatchRoot belongs.
    /// @param _chainBatchRoot The value of chainBatchRoot which is being added.
    function addChainBatchRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainBatchRoot
    ) external addChainBatchRootRestriction(_chainId) {
        // Make sure that chain is registered.
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }
        require(
            chainBatchRoots[_chainId][_batchNumber] == bytes32(0),
            ChainBatchRootAlreadyExists(_chainId, _batchNumber)
        );

        chainBatchRoots[_chainId][_batchNumber] = _chainBatchRoot;
        if (block.chainid == L1_CHAIN_ID) {
            /// On L1 we only store the chainBatchRoot, but don't update the chainTree or sharedTree.
            return;
        }
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

    /// @notice emit a new message root when committing a new batch
    function _emitRoot(bytes32 _root) internal {
        // What happens here is we query for the current sharedTreeRoot and emit the event stating that new InteropRoot is "created".
        // The reason for the usage of "bytes32[] memory _sides" to store the InteropRoot is explained in L2InteropRootStorage contract.
        bytes32[] memory _sides = new bytes32[](1);
        _sides[0] = _root;
        emit NewInteropRoot(block.chainid, block.number, 0, _sides);
    }

    /// @notice Gets the aggregated root of all chains.
    function getAggregatedRoot() external view returns (bytes32) {
        if (chainCount == 0) {
            return SHARED_ROOT_TREE_EMPTY_HASH;
        }
        return sharedTree.root();
    }

    /// @dev Gets the message root of a single chain.
    /// @param _chainId The ID of the chain whose message root is being queried.
    function getChainRoot(uint256 _chainId) external view returns (bytes32) {
        // Make sure that chain is registered.
        if (!chainRegistered(_chainId)) {
            revert MessageRootNotRegistered();
        }
        return chainTree[_chainId].root();
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

    function _initialize() internal {
        // slither-disable-next-line unused-return
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);
        _addNewChain(block.chainid);
    }

    /// @dev Adds a single chain to the message root.
    /// @param _chainId The ID of the chain that is being added to the message root.
    function _addNewChain(uint256 _chainId) internal {
        uint256 cachedChainCount = chainCount;

        // Since only the bridgehub can add new chains to the message root, it is expected that
        // it will be responsible for ensuring that the number of chains does not exceed the limit.
        ++chainCount;
        chainIndex[_chainId] = cachedChainCount;
        chainIndexToId[cachedChainCount] = _chainId;

        // slither-disable-next-line unused-return
        bytes32 initialHash = chainTree[_chainId].setup(CHAIN_TREE_EMPTY_ENTRY_HASH);

        // slither-disable-next-line unused-return
        sharedTree.pushNewLeaf(MessageHashing.chainIdLeafHash(initialHash, _chainId));

        emit AddedChain(_chainId, cachedChainCount);
    }

    //////////////////////////////
    //// IMessageVerification ////
    //////////////////////////////

    function _proveL2LeafInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal view override returns (bool) {
        ProofData memory proofData = MessageHashing._getProofData({
            _chainId: _chainId,
            _batchNumber: _batchNumber,
            _leafProofMask: _leafProofMask,
            _leaf: _leaf,
            _proof: _proof
        });
        if (proofData.finalProofNode) {
            // For proof based interop this is the SL InteropRoot at block number _batchNumber
            bytes32 correctBatchRoot = _getChainBatchRoot(_chainId, _batchNumber);
            return correctBatchRoot == proofData.batchSettlementRoot && correctBatchRoot != bytes32(0);
        }

        return
            this.proveL2LeafInclusionShared({
                _chainId: proofData.settlementLayerChainId,
                _blockOrBatchNumber: proofData.settlementLayerBatchNumber, // SL block number
                _leafProofMask: proofData.settlementLayerBatchRootMask,
                _leaf: proofData.chainIdLeaf,
                _proof: MessageHashing.extractSliceUntilEnd(_proof, proofData.ptr)
            });
    }

    /// @notice Internal to get the historical batch root for chains before the v30 upgrade.
    function _getChainBatchRoot(uint256 _chainId, uint256 _batchNumber) internal view returns (bytes32) {
        if (v30UpgradeChainBatchNumber[_chainId] >= _batchNumber) {
            return IGetters(BRIDGE_HUB.getZKChain(_chainId)).l2LogsRootHash(_batchNumber);
        }
        return chainBatchRoots[_chainId][_batchNumber];
    }


    /// @notice Extracts and returns proof data for settlement layer verification.
    /// @dev Wrapper function around MessageHashing._getProofData for public access.
    /// @param _chainId The chain ID where the proof was generated.
    /// @param _batchNumber The batch number containing the proof.
    /// @param _leafProofMask The leaf proof mask for merkle verification.
    /// @param _leaf The leaf hash to verify.
    /// @param _proof The merkle proof array.
    /// @return The extracted proof data including settlement layer information.
    function getProofData(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) public pure returns (ProofData memory) {
        return
            MessageHashing._getProofData({
                _chainId: _chainId,
                _batchNumber: _batchNumber,
                _leafProofMask: _leafProofMask,
                _leaf: _leaf,
                _proof: _proof
            });
    }
}
