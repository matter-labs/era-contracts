// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehubBase, BaseTokenData} from "./IBridgehubBase.sol";

import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IL1BaseTokenAssetHandler} from "../../bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {ReentrancyGuard} from "../../common/ReentrancyGuard.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";

import {BridgehubL2TransactionRequest, L2Log, L2Message, TxStatus} from "../../common/Messaging.sol";
import {AddressAliasHelper} from "../../vendor/AddressAliasHelper.sol";
import {IMessageRoot} from "../message-root/IMessageRoot.sol";
import {ICTMDeploymentTracker} from "../ctm-deployment/ICTMDeploymentTracker.sol";
import {AlreadyCurrentSL, NotChainAssetHandler, SLNotWhitelisted} from "./L1BridgehubErrors.sol";
import {AssetHandlerNotRegistered, AssetIdAlreadyRegistered, AssetIdNotSupported, BridgeHubAlreadyRegistered, CTMAlreadyRegistered, CTMNotRegistered, ChainIdCantBeCurrentChain, ChainIdNotRegistered, ChainIdTooBig, EmptyAssetId, NoCTMForAssetId, NotCurrentSettlementLayer, SettlementLayersMustSettleOnL1, SharedBridgeNotSet, Unauthorized, ZKChainLimitReached, ZeroAddress, ZeroChainId} from "../../common/L1ContractErrors.sol";
import {L2_COMPLEX_UPGRADER_ADDR, GW_ASSET_TRACKER} from "../../common/l2-helpers/L2ContractAddresses.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
abstract contract BridgehubBase is IBridgehubBase, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view virtual returns (bytes32);

    function _maxNumberOfZKChains() internal view virtual returns (uint256);

    function _l1ChainId() internal view virtual returns (uint256);

    /// @notice all the ether and ERC20 tokens are held by NativeVaultToken managed by the asset router.
    IAssetRouterBase public assetRouter;

    /// @notice ChainTypeManagers that are registered, and ZKchains that use these CTMs can use this bridgehub as settlement layer.
    mapping(address chainTypeManager => bool) public chainTypeManagerIsRegistered;

    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address baseToken => bool) internal __DEPRECATED_tokenIsRegistered;

    /// @notice chainID => ChainTypeManager contract address, CTM that is managing rules for a given ZKchain.
    mapping(uint256 chainId => address) public chainTypeManager;

    /// @notice chainID => baseToken contract address, token that is used as 'base token' by a given child chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => address) internal __DEPRECATED_baseToken;

    /// @dev used to manage non critical updates
    address public admin;

    /// @dev used to accept the admin role
    address private pendingAdmin;

    /// @notice The map from chainId => zkChain contract
    EnumerableMap.UintToAddressMap internal zkChainMap;

    /// @notice The contract that stores the cross-chain message root for each chain and the aggregated root.
    /// @dev Note that the message root does not contain messages from the chain it is deployed on. It may
    /// be added later on if needed.
    IMessageRoot public override messageRoot;

    /// @notice Mapping from chain id to encoding of the base token used for deposits / withdrawals
    mapping(uint256 chainId => bytes32) public baseTokenAssetId;

    /// @notice The deployment tracker for the state transition managers.
    /// @dev The L1 address of the ctm deployer is provided.
    ICTMDeploymentTracker public l1CtmDeployer;

    /// @dev asset info used to identify chains in the Shared Bridge
    mapping(bytes32 ctmAssetId => address ctmAddress) public ctmAssetIdToAddress;

    /// @dev ctmAddress to ctmAssetId
    mapping(address ctmAddress => bytes32 ctmAssetId) public ctmAssetIdFromAddress;

    /// @dev used to indicate the currently active settlement layer for a given chainId
    mapping(uint256 chainId => uint256 activeSettlementLayerChainId) public settlementLayer;

    /// @notice shows whether the given chain can be used as a settlement layer.
    /// @dev the Gateway will be one of the possible settlement layers. The L1 is also a settlement layer.
    /// @dev Sync layer chain is expected to have .. as the base token.
    mapping(uint256 chainId => bool isWhitelistedSettlementLayer) public whitelistedSettlementLayers;

    /// @notice we store registered assetIds (for arbitrary base token)
    mapping(bytes32 baseTokenAssetId => bool) public assetIdIsRegistered;

    /// @notice used to pause the migrations of chains. Used for stopping migrations during upgrades.
    bool public __DEPRECATED_migrationPaused;

    /// @notice the chain asset handler used for chain migration.
    address public chainAssetHandler;

    /// @notice the chain registration sender used for chain registration.
    /// @notice the chainRegistrationSender is only deployed on L1.
    /// @dev If the Bridgehub is on L1 it is the address just the chainRegistrationSender address.
    /// @dev If the Bridgehub is on L2 the address is aliased.
    address public chainRegistrationSender;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[36] private __gap;

    modifier onlyOwnerOrAdmin() {
        if (msg.sender != admin && msg.sender != owner()) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyOwnerOrUpgrader() {
        if (msg.sender != owner() && msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyChainAssetHandler() {
        if (msg.sender != chainAssetHandler) {
            revert NotChainAssetHandler(msg.sender, chainAssetHandler);
        }
        _;
    }

    /// @notice Initializes the contract
    function _initializeInner() internal {
        assetIdIsRegistered[_ethTokenAssetId()] = true;
        whitelistedSettlementLayers[_l1ChainId()] = true;
    }

    //// Initialization and registration

    /// @inheritdoc IBridgehubBase
    /// @dev Please note, if the owner wants to enforce the admin change it must execute both `setPendingAdmin` and
    /// `acceptAdmin` atomically. Otherwise `admin` can set different pending admin and so fail to accept the admin rights.
    function setPendingAdmin(address _newPendingAdmin) external onlyOwnerOrAdmin {
        if (_newPendingAdmin == address(0)) {
            revert ZeroAddress();
        }
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = pendingAdmin;
        // Change pending admin
        pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @inheritdoc IBridgehubBase
    function acceptAdmin() external {
        address currentPendingAdmin = pendingAdmin;
        // Only proposed by current admin address can claim the admin rights
        if (msg.sender != currentPendingAdmin) {
            revert Unauthorized(msg.sender);
        }

        address previousAdmin = admin;
        admin = currentPendingAdmin;
        delete pendingAdmin;

        emit NewPendingAdmin(currentPendingAdmin, address(0));
        emit NewAdmin(previousAdmin, currentPendingAdmin);
    }

    /// @notice To set the addresses of some of the ecosystem contracts, only Owner. Not done in initialize, as
    /// the order of deployment is Bridgehub, other contracts, and then we call this.
    /// @param _assetRouter the shared bridge address
    /// @param _l1CtmDeployer the ctm deployment tracker address. Note, that the address of the L1 CTM deployer is provided.
    /// @param _messageRoot the message root address
    function setAddresses(
        address _assetRouter,
        ICTMDeploymentTracker _l1CtmDeployer,
        IMessageRoot _messageRoot,
        address _chainAssetHandler,
        address _chainRegistrationSender
    ) external virtual;

    function setAddressesV31(address _chainRegistrationSender) external onlyOwnerOrUpgrader {
        chainRegistrationSender = _chainRegistrationSender;
    }

    //// Registry

    /// @notice Chain Type Manager can be any contract with the appropriate interface/functionality
    /// @param _chainTypeManager the state transition manager address to be added
    function addChainTypeManager(address _chainTypeManager) external onlyOwner {
        if (_chainTypeManager == address(0)) {
            revert ZeroAddress();
        }
        if (chainTypeManagerIsRegistered[_chainTypeManager]) {
            revert CTMAlreadyRegistered();
        }
        chainTypeManagerIsRegistered[_chainTypeManager] = true;

        emit ChainTypeManagerAdded(_chainTypeManager);
    }

    /// @notice Chain Type Manager can be any contract with the appropriate interface/functionality
    /// @notice this stops new Chains from using the CTM, old chains are not affected
    /// @param _chainTypeManager the state transition manager address to be removed
    function removeChainTypeManager(address _chainTypeManager) external onlyOwner {
        if (_chainTypeManager == address(0)) {
            revert ZeroAddress();
        }
        if (!chainTypeManagerIsRegistered[_chainTypeManager]) {
            revert CTMNotRegistered();
        }
        chainTypeManagerIsRegistered[_chainTypeManager] = false;

        emit ChainTypeManagerRemoved(_chainTypeManager);
    }

    /// @notice asset id can represent any token contract with the appropriate interface/functionality
    /// @param _baseTokenAssetId asset id of base token to be registered
    function addTokenAssetId(bytes32 _baseTokenAssetId) external onlyOwnerOrAdmin {
        if (assetIdIsRegistered[_baseTokenAssetId]) {
            revert AssetIdAlreadyRegistered();
        }
        assetIdIsRegistered[_baseTokenAssetId] = true;

        emit BaseTokenAssetIdRegistered(_baseTokenAssetId);
    }

    /// @dev Used to set the assetAddress for a given assetInfo.
    /// @param _additionalData the additional data to identify the asset
    /// @param _assetAddress the asset handler address
    function setCTMAssetAddress(bytes32 _additionalData, address _assetAddress) external {
        // It is a simplified version of the logic used by the AssetRouter to manage asset handlers.
        // CTM's assetId is `keccak256(abi.encode(_l1ChainId(), l1CtmDeployer, ctmAddress))`.
        // And the l1CtmDeployer is considered the deployment tracker for the CTM asset.
        //
        // The l1CtmDeployer will call this method to set the asset handler address for the assetId.
        // If the chain is not the same as L1, we assume that it is done via L1->L2 communication and so we unalias the sender.
        //
        // For simpler handling we allow anyone to call this method. It is okay, since during bridging operations
        // it is double checked that `assetId` is indeed derived from the `l1CtmDeployer`.
        // TODO(EVM-703): This logic should be revised once interchain communication with aliasing (either standard trigger or shadow accounts) is implemented.

        address sender = _l1ChainId() == block.chainid ? msg.sender : AddressAliasHelper.undoL1ToL2Alias(msg.sender);
        // This method can be accessed by l1CtmDeployer only
        if (sender != address(l1CtmDeployer)) {
            revert Unauthorized(sender);
        }
        if (!chainTypeManagerIsRegistered[_assetAddress]) {
            revert CTMNotRegistered();
        }

        bytes32 ctmAssetId = DataEncoding.encodeAssetId(_l1ChainId(), _additionalData, sender);
        ctmAssetIdToAddress[ctmAssetId] = _assetAddress;
        ctmAssetIdFromAddress[_assetAddress] = ctmAssetId;
        emit AssetRegistered(ctmAssetId, _assetAddress, _additionalData, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          Chain Registration
    //////////////////////////////////////////////////////////////*/

    /// @notice This function is used to register a new zkChain in the system.
    /// @notice see external counterpart for full natspec.
    function _registerNewZKChain(uint256 _chainId, address _zkChain, bool _checkMaxNumberOfZKChains) internal {
        // slither-disable-next-line unused-return
        zkChainMap.set(_chainId, _zkChain);
        if (_checkMaxNumberOfZKChains && zkChainMap.length() > _maxNumberOfZKChains()) {
            revert ZKChainLimitReached();
        }
    }

    /*//////////////////////////////////////////////////////////////
                             Getters
    //////////////////////////////////////////////////////////////*/

    /// @notice baseToken function, which takes chainId as input, reads assetHandler from AR, and tokenAddress from AH
    function baseToken(uint256 _chainId) public view returns (address) {
        bytes32 baseTokenAssetId = baseTokenAssetId[_chainId];
        address assetHandlerAddress = IAssetRouterBase(assetRouter).assetHandlerAddress(baseTokenAssetId);

        // It is possible that the asset handler is not deployed for a chain on the current layer.
        // In this case we throw an error.
        if (assetHandlerAddress == address(0)) {
            revert AssetHandlerNotRegistered(baseTokenAssetId);
        }
        return IL1BaseTokenAssetHandler(assetHandlerAddress).tokenAddress(baseTokenAssetId);
    }

    /// @notice Returns all the registered zkChain addresses
    function getAllZKChains() public view override returns (address[] memory chainAddresses) {
        uint256[] memory keys = zkChainMap.keys();
        chainAddresses = new address[](keys.length);
        uint256 keysLength = keys.length;
        for (uint256 i = 0; i < keysLength; ++i) {
            chainAddresses[i] = zkChainMap.get(keys[i]);
        }
    }

    /// @notice Returns all the registered zkChain chainIDs
    function getAllZKChainChainIDs() public view override returns (uint256[] memory) {
        return zkChainMap.keys();
    }

    /// @notice Returns the address of the ZK chain with the corresponding chainID
    /// @param _chainId the chainId of the chain
    /// @return chainAddress the address of the ZK chain
    function getZKChain(uint256 _chainId) public view override returns (address chainAddress) {
        // slither-disable-next-line unused-return
        (, chainAddress) = zkChainMap.tryGet(_chainId);
    }

    function ctmAssetIdFromChainId(uint256 _chainId) public view override returns (bytes32) {
        address ctmAddress = chainTypeManager[_chainId];
        if (ctmAddress == address(0)) {
            revert ChainIdNotRegistered(_chainId);
        }
        return ctmAssetIdFromAddress[ctmAddress];
    }

    /*//////////////////////////////////////////////////////////////
                        Mailbox forwarder
    //////////////////////////////////////////////////////////////*/

    /// @notice This function is used to send a request to the ZK chain.
    /// @param _chainId the chainId of the chain
    /// @param _refundRecipient the refund recipient
    /// @param _request the request
    /// @return canonicalTxHash the canonical transaction hash
    function _sendRequest(
        uint256 _chainId,
        address _refundRecipient,
        BridgehubL2TransactionRequest memory _request
    ) internal returns (bytes32 canonicalTxHash) {
        // Although the aliasing might happen in the Mailbox, we still want to determine the refund recipient
        // in the BH, as the Mailbox won't have msg.sender
        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, msg.sender);
        _request.refundRecipient = refundRecipient;
        address zkChain = zkChainMap.get(_chainId);

        canonicalTxHash = IZKChain(zkChain).bridgehubRequestL2Transaction(_request);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the ZK chain where to prove L2 message inclusion.
    /// @param _batchNumber The executed L2 batch number in which the message appeared
    /// @param _index The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _message Information about the sent message: sender address, the message itself, tx index in the L2 batch where the message was sent
    /// @param _proof Merkle proof for inclusion of L2 log that was sent with the message
    /// @return Whether the proof is valid
    function proveL2MessageInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        return
            messageRoot.proveL2MessageInclusionShared({
                _chainId: _chainId,
                _blockOrBatchNumber: _batchNumber,
                _index: _index,
                _message: _message,
                _proof: _proof
            });
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the ZK chain where to prove L2 log inclusion.
    /// @param _batchNumber The executed L2 batch number in which the log appeared
    /// @param _index The position of the l2log in the L2 logs Merkle tree
    /// @param _log Information about the sent log
    /// @param _proof Merkle proof for inclusion of the L2 log
    /// @return Whether the proof is correct and L2 log is included in batch
    function proveL2LogInclusion(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        return
            messageRoot.proveL2LogInclusionShared({
                _chainId: _chainId,
                _blockOrBatchNumber: _batchNumber,
                _index: _index,
                _log: _log,
                _proof: _proof
            });
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the ZK chain where to prove L1->L2 tx status.
    /// @param _l2TxHash The L2 canonical transaction hash
    /// @param _l2BatchNumber The L2 batch number where the transaction was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction
    /// @param _status The execution status of the L1 -> L2 transaction (true - success & 0 - fail)
    /// @return Whether the proof is correct and the transaction was actually executed with provided status
    /// NOTE: It may return `false` for incorrect proof, but it doesn't mean that the L1 -> L2 transaction has an opposite status!
    function proveL1ToL2TransactionStatus(
        uint256 _chainId,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) external view override returns (bool) {
        return
            messageRoot.proveL1ToL2TransactionStatusShared({
                _chainId: _chainId,
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _status: _status
            });
    }

    /// @notice forwards function call to Mailbox based on ChainId
    function l2TransactionBaseCost(
        uint256 _chainId,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        address zkChain = zkChainMap.get(_chainId);
        return IZKChain(zkChain).l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    /*//////////////////////////////////////////////////////////////
                        Chain migration
    //////////////////////////////////////////////////////////////*/

    /// @notice IL1AssetHandler interface, used to migrate (transfer) a chain to the settlement layer.
    /// @param _chainId The chain ID of the migrating chain.
    /// @param _newSettlementLayerChainId The chain ID of the new settlement layer.
    /// @return zkChain The address of the ZK chain.
    /// @return ctm The address of the CTM of the chain.
    function forwardedBridgeBurnSetSettlementLayer(
        uint256 _chainId,
        uint256 _newSettlementLayerChainId
    ) external onlyChainAssetHandler returns (address zkChain, address ctm) {
        if (!whitelistedSettlementLayers[_newSettlementLayerChainId]) {
            revert SLNotWhitelisted();
        }

        if (settlementLayer[_chainId] != block.chainid) {
            revert NotCurrentSettlementLayer();
        }
        settlementLayer[_chainId] = _newSettlementLayerChainId;

        if (whitelistedSettlementLayers[_chainId]) {
            revert SettlementLayersMustSettleOnL1();
        }
        zkChain = zkChainMap.get(_chainId);
        ctm = chainTypeManager[_chainId];
    }

    /// @notice IL1AssetHandler interface, used to migrate (transfer) a chain to the settlement layer.
    /// @param _assetId The asset ID of the chain.
    /// @param _chainId The chain ID of the ZK chain.
    /// @param _baseTokenData The data for the base token.
    /// @return zkChain The address of the ZK chain.
    /// @return ctm The address of the CTM of the chain.
    function forwardedBridgeMint(
        bytes32 _assetId,
        uint256 _chainId,
        BaseTokenData calldata _baseTokenData
    ) external onlyChainAssetHandler returns (address zkChain, address ctm) {
        ctm = ctmAssetIdToAddress[_assetId];
        if (ctm == address(0)) {
            revert NoCTMForAssetId(_assetId);
        }
        if (settlementLayer[_chainId] == block.chainid) {
            revert AlreadyCurrentSL(block.chainid);
        }

        settlementLayer[_chainId] = block.chainid;
        chainTypeManager[_chainId] = ctm;
        baseTokenAssetId[_chainId] = _baseTokenData.assetId;
        // To keep `assetIdIsRegistered` consistent, we'll also automatically register the base token.
        // It is assumed that if the bridging happened, the token was approved on L1 already.
        assetIdIsRegistered[_baseTokenData.assetId] = true;

        if (block.chainid != _l1ChainId()) {
            GW_ASSET_TRACKER.registerBaseTokenOnGateway(_baseTokenData);
        }

        zkChain = getZKChain(_chainId);
    }

    /// @notice Used to recover a failed migration.
    /// @param _chainId The chain ID of the chain.
    /// @return zkChain The address of the ZK chain.
    /// @return ctm The address of the CTM of the chain.
    function forwardedBridgeConfirmTransferResult(
        uint256 _chainId,
        TxStatus _txStatus
    ) external onlyChainAssetHandler returns (address zkChain, address ctm) {
        zkChain = getZKChain(_chainId);
        ctm = chainTypeManager[_chainId];
        if (_txStatus == TxStatus.Failure) {
            settlementLayer[_chainId] = block.chainid;
        }
    }

    /*////////////////////////////////////////////////////////////
                            Chain registration
    //////////////////////////////////////////////////////////////*/

    /// @notice This function is used to register a new zkChain in the system.
    /// @param _chainId The chain ID of the ZK chain
    /// @param _zkChain The address of the ZK chain's DiamondProxy contract.
    /// @param _checkMaxNumberOfZKChains Whether to check that the limit for the number
    /// of chains has not been crossed.
    /// @dev Providing `_checkMaxNumberOfZKChains = false` may be preferable in cases
    /// where we want to guarantee that a chain can be added. These include:
    /// - Migration of a chain from the mapping in the old CTM
    /// - Migration of a chain to a new settlement layer
    function registerNewZKChain(
        uint256 _chainId,
        address _zkChain,
        bool _checkMaxNumberOfZKChains
    ) public onlyChainAssetHandler {
        _registerNewZKChain(_chainId, _zkChain, _checkMaxNumberOfZKChains);
    }

    function _validateChainParams(uint256 _chainId, bytes32 _assetId, address _chainTypeManager) internal view {
        if (_chainId == 0) {
            revert ZeroChainId();
        }

        if (_chainId > type(uint48).max) {
            revert ChainIdTooBig();
        }

        if (_chainId == block.chainid) {
            revert ChainIdCantBeCurrentChain();
        }

        if (_chainTypeManager == address(0)) {
            revert ZeroAddress();
        }
        if (_assetId == bytes32(0)) {
            revert EmptyAssetId();
        }

        if (!chainTypeManagerIsRegistered[_chainTypeManager]) {
            revert CTMNotRegistered();
        }

        if (!assetIdIsRegistered[_assetId]) {
            revert AssetIdNotSupported(_assetId);
        }

        if (address(assetRouter) == address(0)) {
            revert SharedBridgeNotSet();
        }
        if (chainTypeManager[_chainId] != address(0)) {
            revert BridgeHubAlreadyRegistered();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pauses all functions marked with the `whenNotPaused` modifier.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing all functions marked with the `whenNotPaused` modifier to be called again.
    function unpause() external onlyOwner {
        _unpause();
    }

    /*//////////////////////////////////////////////////////////////
                            Legacy functions
    //////////////////////////////////////////////////////////////*/

    /// @notice return the ZK chain contract for a chainId
    function getHyperchain(uint256 _chainId) public view returns (address) {
        return getZKChain(_chainId);
    }

    /// @notice return the asset router
    function sharedBridge() public view returns (address) {
        return address(assetRouter);
    }
}
