// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner, BridgehubMintCTMAssetData, BridgehubBurnCTMAssetData} from "./IBridgehub.sol";
import {IL1AssetRouter} from "../bridge/interfaces/IL1AssetRouter.sol";
import {IL1BaseTokenAssetHandler} from "../bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";

import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "../common/Config.sol";
import {BridgehubL2TransactionRequest, L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ICTMDeploymentTracker} from "./ICTMDeploymentTracker.sol";
import {AssetHandlerNotRegistered, ZKChainLimitReached, Unauthorized, CTMAlreadyRegistered, CTMNotRegistered, ZeroChainId, ChainIdTooBig, SharedBridgeNotSet, BridgeHubAlreadyRegistered, AddressTooLow, MsgValueMismatch, WrongMagicValue, ZeroAddress} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1<->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
/// Bridgehub is also an IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
contract Bridgehub is IBridgehub, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /// @notice the asset id of Eth
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice The total number of ZK chains can be created/connected to this CTM.
    /// This is the temporary security measure.
    uint256 public immutable MAX_NUMBER_OF_ZK_CHAINS;

    /// @notice all the ether and ERC20 tokens are held by NativeVaultToken managed by this shared Bridge.
    IL1AssetRouter public sharedBridge;

    /// @notice ChainTypeManagers that are registered, and ZKchains that use these CTMs can use this bridgehub as settlement layer.
    mapping(address chainTypeManager => bool) public chainTypeManagerIsRegistered;

    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address baseToken => bool) public __DEPRECATED_tokenIsRegistered;

    /// @notice chainID => ChainTypeManager contract address, CTM that is managing rules for a given ZKchain.
    mapping(uint256 chainId => address) public chainTypeManager;

    /// @notice chainID => baseToken contract address, token that is used as 'base token' by a given child chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => address) public __DEPRECATED_baseToken;

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

    /// @dev used to indicate the currently active settlement layer for a given chainId
    mapping(uint256 chainId => uint256 activeSettlementLayerChainId) public settlementLayer;

    /// @notice shows whether the given chain can be used as a settlement layer.
    /// @dev the Gateway will be one of the possible settlement layers. The L1 is also a settlement layer.
    /// @dev Sync layer chain is expected to have .. as the base token.
    mapping(uint256 chainId => bool isWhitelistedSettlementLayer) public whitelistedSettlementLayers;

    /// @notice we store registered assetIds (for arbitrary base token)
    mapping(bytes32 baseTokenAssetId => bool) public assetIdIsRegistered;

    /// @notice used to pause the migrations of chains. Used for upgrades.
    bool public migrationPaused;

    modifier onlyOwnerOrAdmin() {
        if (msg.sender != admin && msg.sender != owner()) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyChainCTM(uint256 _chainId) {
        require(msg.sender == chainTypeManager[_chainId], "BH: not chain CTM");
        _;
    }

    modifier onlyL1() {
        require(L1_CHAIN_ID == block.chainid, "BH: not L1");
        _;
    }

    modifier onlySettlementLayerRelayedSender() {
        /// There is no sender for the wrapping, we use a virtual address.
        require(msg.sender == SETTLEMENT_LAYER_RELAY_SENDER, "BH: not relayed senser");
        _;
    }

    modifier onlyAssetRouter() {
        require(msg.sender == address(sharedBridge), "BH: not asset router");
        _;
    }

    modifier whenMigrationsNotPaused() {
        require(!migrationPaused, "BH: migrations paused");
        _;
    }

    /// @notice to avoid parity hack
    constructor(uint256 _l1ChainId, address _owner, uint256 _maxNumberOfZKChains) reentrancyGuardInitializer {
        _disableInitializers();
        L1_CHAIN_ID = _l1ChainId;
        MAX_NUMBER_OF_ZK_CHAINS = _maxNumberOfZKChains;

        // Note that this assumes that the bridgehub only accepts transactions on chains with ETH base token only.
        // This is indeed true, since the only methods where this immutable is used are the ones with `onlyL1` modifier.
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
        _transferOwnership(_owner);
        whitelistedSettlementLayers[_l1ChainId] = true;
    }

    /// @notice used to initialize the contract
    /// @notice this contract is also deployed on L2 as a system contract there the owner and the related functions will not be used
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);

        whitelistedSettlementLayers[L1_CHAIN_ID] = true;
    }

    //// Initialization and registration

    /// @inheritdoc IBridgehub
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

    /// @inheritdoc IBridgehub
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
    /// @param _sharedBridge the shared bridge address
    /// @param _l1CtmDeployer the ctm deployment tracker address. Note, that the address of the L1 CTM deployer is provided.
    /// @param _messageRoot the message root address
    function setAddresses(
        address _sharedBridge,
        ICTMDeploymentTracker _l1CtmDeployer,
        IMessageRoot _messageRoot
    ) external onlyOwner {
        sharedBridge = IL1AssetRouter(_sharedBridge);
        l1CtmDeployer = _l1CtmDeployer;
        messageRoot = _messageRoot;
    }

    /// @notice Used for the upgrade to set the baseTokenAssetId previously stored as baseToken.
    /// @param _chainId the chainId of the chain.
    function setLegacyBaseTokenAssetId(uint256 _chainId) external {
        if (baseTokenAssetId[_chainId] == bytes32(0)) {
            return;
        }
        address token = __DEPRECATED_baseToken[_chainId];
        require(token != address(0), "BH: token not set");
        baseTokenAssetId[_chainId] = DataEncoding.encodeNTVAssetId(block.chainid, token);
    }

    /// @notice Used to set the legacy chain address for the upgrade.
    /// @param _chainId The chainId of the legacy chain we are migrating.
    function setLegacyChainAddress(uint256 _chainId) external {
        address ctm = chainTypeManager[_chainId];
        require(ctm != address(0), "BH: chain not legacy");
        require(!zkChainMap.contains(_chainId), "BH: chain already migrated");
        /// Note we have to do this before CTM is upgraded.
        address chainAddress = IChainTypeManager(ctm).getZKChainLegacy(_chainId);
        require(chainAddress != address(0), "BH: chain not legacy 2");
        _registerNewZKChain(_chainId, chainAddress);
    }

    //// Registry

    /// @notice State Transition can be any contract with the appropriate interface/functionality
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

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    /// @notice this stops new Chains from using the STF, old chains are not affected
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
    function addTokenAssetId(bytes32 _baseTokenAssetId) external onlyOwner {
        require(!assetIdIsRegistered[_baseTokenAssetId], "BH: asset id already registered");
        assetIdIsRegistered[_baseTokenAssetId] = true;

        emit BaseTokenAssetIdRegistered(_baseTokenAssetId);
    }

    /// @notice Used to register a chain as a settlement layer.
    /// @param _newSettlementLayerChainId the chainId of the chain
    /// @param _isWhitelisted whether the chain is a whitelisted settlement layer
    function registerSettlementLayer(
        uint256 _newSettlementLayerChainId,
        bool _isWhitelisted
    ) external onlyOwner onlyL1 {
        whitelistedSettlementLayers[_newSettlementLayerChainId] = _isWhitelisted;
        emit SettlementLayerRegistered(_newSettlementLayerChainId, _isWhitelisted);
    }

    /// @dev Used to set the assetAddress for a given assetInfo.
    /// @param _additionalData the additional data to identify the asset
    /// @param _assetAddress the asset handler address
    function setAssetHandlerAddress(bytes32 _additionalData, address _assetAddress) external {
        // It is a simplified version of the logic used by the AssetRouter to manage asset handlers.
        // CTM's assetId is `keccak256(abi.encode(L1_CHAIN_ID, l1CtmDeployer, ctmAddress))`.
        // And the l1CtmDeployer is considered the deployment tracker for the CTM asset.
        //
        // The l1CtmDeployer will call this method to set the asset handler address for the assetId.
        // If the chain is not the same as L1, we assume that it is done via L1->L2 communication and so we unalias the sender.
        //
        // For simpler handling we allow anyone to call this method. It is okay, since during bridging operations
        // it is double checked that `assetId` is indeed derived from the `l1CtmDeployer`.
        // TODO(EVM-703): This logic should be revised once interchain communication is implemented.

        address sender = L1_CHAIN_ID == block.chainid ? msg.sender : AddressAliasHelper.undoL1ToL2Alias(msg.sender);
        // This method can be accessed by l1CtmDeployer only
        require(sender == address(l1CtmDeployer), "BH: not ctm deployer");
        require(chainTypeManagerIsRegistered[_assetAddress], "CTM not registered");

        bytes32 assetInfo = keccak256(abi.encode(L1_CHAIN_ID, sender, _additionalData));
        ctmAssetIdToAddress[assetInfo] = _assetAddress;
        emit AssetRegistered(assetInfo, _assetAddress, _additionalData, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          Chain Registration
    //////////////////////////////////////////////////////////////*/

    /// @notice register new chain. New chains can be only registered on Bridgehub deployed on L1. Later they can be moved to any other layer.
    /// @notice for Eth the baseToken address is 1
    /// @param _chainId the chainId of the chain
    /// @param _chainTypeManager the state transition manager address
    /// @param _baseTokenAssetId the base token asset id of the chain
    /// @param _salt the salt for the chainId, currently not used
    /// @param _admin the admin of the chain
    /// @param _initData the fixed initialization data for the chain
    /// @param _factoryDeps the factory dependencies for the chain's deployment
    function createNewChain(
        uint256 _chainId,
        address _chainTypeManager,
        bytes32 _baseTokenAssetId,
        // solhint-disable-next-line no-unused-vars
        uint256 _salt,
        address _admin,
        bytes calldata _initData,
        bytes[] calldata _factoryDeps
    ) external onlyOwnerOrAdmin nonReentrant whenNotPaused onlyL1 returns (uint256) {
        if (_chainId == 0) {
            revert ZeroChainId();
        }
        if (_chainId > type(uint48).max) {
            revert ChainIdTooBig();
        }
        require(_chainId != block.chainid, "BH: chain id must not match current chainid");
        if (_chainTypeManager == address(0)) {
            revert ZeroAddress();
        }
        if (_baseTokenAssetId == bytes32(0)) {
            revert ZeroAddress();
        }

        if (!chainTypeManagerIsRegistered[_chainTypeManager]) {
            revert CTMNotRegistered();
        }

        require(assetIdIsRegistered[_baseTokenAssetId], "BH: asset id not registered");

        if (address(sharedBridge) == address(0)) {
            revert SharedBridgeNotSet();
        }
        if (chainTypeManager[_chainId] != address(0)) {
            revert BridgeHubAlreadyRegistered();
        }

        chainTypeManager[_chainId] = _chainTypeManager;

        baseTokenAssetId[_chainId] = _baseTokenAssetId;
        settlementLayer[_chainId] = block.chainid;

        address chainAddress = IChainTypeManager(_chainTypeManager).createNewChain({
            _chainId: _chainId,
            _baseTokenAssetId: _baseTokenAssetId,
            _sharedBridge: address(sharedBridge),
            _admin: _admin,
            _initData: _initData,
            _factoryDeps: _factoryDeps
        });
        _registerNewZKChain(_chainId, chainAddress);
        messageRoot.addNewChain(_chainId);

        emit NewChain(_chainId, _chainTypeManager, _admin);
        return _chainId;
    }

    /// @dev This internal function is used to register a new zkChain in the system.
    function _registerNewZKChain(uint256 _chainId, address _zkChain) internal {
        // slither-disable-next-line unused-return
        zkChainMap.set(_chainId, _zkChain);
        if (zkChainMap.length() > MAX_NUMBER_OF_ZK_CHAINS) {
            revert ZKChainLimitReached();
        }
    }

    /*//////////////////////////////////////////////////////////////
                             Getters
    //////////////////////////////////////////////////////////////*/

    /// @notice baseToken function, which takes chainId as input, reads assetHandler from AR, and tokenAddress from AH
    function baseToken(uint256 _chainId) public view returns (address) {
        bytes32 baseTokenAssetId = baseTokenAssetId[_chainId];
        address assetHandlerAddress = sharedBridge.assetHandlerAddress(baseTokenAssetId);

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
        require(ctmAddress != address(0), "chain id not registered");
        return ctmAssetId(chainTypeManager[_chainId]);
    }

    function ctmAssetId(address _ctmAddress) public view override returns (bytes32) {
        return keccak256(abi.encode(L1_CHAIN_ID, address(l1CtmDeployer), bytes32(uint256(uint160(_ctmAddress)))));
    }

    /*//////////////////////////////////////////////////////////////
                        Mailbox forwarder
    //////////////////////////////////////////////////////////////*/

    /// @notice the mailbox is called directly after the sharedBridge received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the nativeTokenVault.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token.
    /// In case allowance is provided to the Shared Bridge, then it will be transferred to NTV.
    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable override nonReentrant whenNotPaused onlyL1 returns (bytes32 canonicalTxHash) {
        // Note: If the ZK chain with corresponding `chainId` is not yet created,
        // the transaction will revert on `bridgehubRequestL2Transaction` as call to zero address.
        {
            bytes32 tokenAssetId = baseTokenAssetId[_request.chainId];
            if (tokenAssetId == ETH_TOKEN_ASSET_ID) {
                if (msg.value != _request.mintValue) {
                    revert MsgValueMismatch(_request.mintValue, msg.value);
                }
            } else {
                if (msg.value != 0) {
                    revert MsgValueMismatch(0, msg.value);
                }
            }

            // slither-disable-next-line arbitrary-send-eth
            sharedBridge.bridgehubDepositBaseToken{value: msg.value}(
                _request.chainId,
                tokenAssetId,
                msg.sender,
                _request.mintValue
            );
        }

        address zkChain = zkChainMap.get(_request.chainId);
        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_request.refundRecipient, msg.sender);
        canonicalTxHash = IZKChain(zkChain).bridgehubRequestL2Transaction(
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _request.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: _request.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: _request.factoryDeps,
                refundRecipient: refundRecipient
            })
        );
    }

    /// @notice After depositing funds to the sharedBridge, the secondBridge is called
    ///  to return the actual L2 message which is sent to the Mailbox.
    ///  This assumes that either ether is the base token or
    ///  the msg.sender has approved the nativeTokenVault with the mintValue,
    ///  and also the necessary approvals are given for the second bridge.
    ///  In case allowance is provided to the Shared Bridge, then it will be transferred to NTV.
    /// @notice The logic of this bridge is to allow easy depositing for bridges.
    /// Each contract that handles the users ERC20 tokens needs approvals from the user, this contract allows
    /// the user to approve for each token only its respective bridge
    /// @notice This function is great for contract calls to L2, the secondBridge can be any contract.
    /// @param _request the request for the L2 transaction
    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable override nonReentrant whenNotPaused onlyL1 returns (bytes32 canonicalTxHash) {
        require(
            _request.secondBridgeAddress > BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS,
            "BH: second bridge address too low"
        ); // to avoid calls to precompiles

        {
            bytes32 tokenAssetId = baseTokenAssetId[_request.chainId];
            uint256 baseTokenMsgValue;
            if (tokenAssetId == ETH_TOKEN_ASSET_ID) {
                if (msg.value != _request.mintValue + _request.secondBridgeValue) {
                    revert MsgValueMismatch(_request.mintValue + _request.secondBridgeValue, msg.value);
                }
                baseTokenMsgValue = _request.mintValue;
            } else {
                if (msg.value != _request.secondBridgeValue) {
                    revert MsgValueMismatch(_request.secondBridgeValue, msg.value);
                }
                baseTokenMsgValue = 0;
            }

            // slither-disable-next-line arbitrary-send-eth
            sharedBridge.bridgehubDepositBaseToken{value: baseTokenMsgValue}(
                _request.chainId,
                tokenAssetId,
                msg.sender,
                _request.mintValue
            );
        }

        address zkChain = zkChainMap.get(_request.chainId);

        IZkSyncHyperchain(hyperchain).bridghehubCheckTransactionAllowed(msg.sender);

        if (_request.secondBridgeAddress <= BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS) {
            revert AddressTooLow(_request.secondBridgeAddress);
        }

        // slither-disable-next-line arbitrary-send-eth
        L2TransactionRequestTwoBridgesInner memory outputRequest = IL1AssetRouter(_request.secondBridgeAddress)
            .bridgehubDeposit{value: _request.secondBridgeValue}(
            _request.chainId,
            msg.sender,
            _request.l2Value,
            _request.secondBridgeCalldata
        );

        if (outputRequest.magicValue != TWO_BRIDGES_MAGIC_VALUE) {
            revert WrongMagicValue(uint256(TWO_BRIDGES_MAGIC_VALUE), uint256(outputRequest.magicValue));
        }

        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_request.refundRecipient, msg.sender);

        canonicalTxHash = IZKChain(zkChain).bridgehubRequestL2Transaction(
            BridgehubL2TransactionRequest({
                sender: _request.secondBridgeAddress,
                contractL2: outputRequest.l2Contract,
                mintValue: _request.mintValue,
                l2Value: _request.l2Value,
                l2Calldata: outputRequest.l2Calldata,
                l2GasLimit: _request.l2GasLimit,
                l2GasPerPubdataByteLimit: _request.l2GasPerPubdataByteLimit,
                factoryDeps: outputRequest.factoryDeps,
                refundRecipient: refundRecipient
            })
        );

        IL1AssetRouter(_request.secondBridgeAddress).bridgehubConfirmL2Transaction(
            _request.chainId,
            outputRequest.txDataHash,
            canonicalTxHash
        );
    }

    /// @notice Used to forward a transaction on the gateway to the chains mailbox (from L1).
    /// @param _chainId the chainId of the chain
    /// @param _canonicalTxHash the canonical transaction hash
    /// @param _expirationTimestamp the expiration timestamp for the transaction
    function forwardTransactionOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external override onlySettlementLayerRelayedSender {
        require(L1_CHAIN_ID != block.chainid, "BH: not in sync layer mode");
        address zkChain = zkChainMap.get(_chainId);
        IZKChain(zkChain).bridgehubRequestL2TransactionOnGateway(_canonicalTxHash, _expirationTimestamp);
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
        address zkChain = zkChainMap.get(_chainId);
        return IZKChain(zkChain).proveL2MessageInclusion(_batchNumber, _index, _message, _proof);
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
        address zkChain = zkChainMap.get(_chainId);
        return IZKChain(zkChain).proveL2LogInclusion(_batchNumber, _index, _log, _proof);
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
        address zkChain = zkChainMap.get(_chainId);
        return
            IZKChain(zkChain).proveL1ToL2TransactionStatus({
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
    /// @param _settlementChainId the chainId of the settlement chain, i.e. where the message and the migrating chain is sent.
    /// @param _assetId the assetId of the migrating chain's CTM
    /// @param _prevMsgSender the previous message sender
    /// @param _data the data for the migration
    function bridgeBurn(
        uint256 _settlementChainId,
        uint256, // mintValue
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override onlyAssetRouter whenMigrationsNotPaused returns (bytes memory bridgehubMintData) {
        require(whitelistedSettlementLayers[_settlementChainId], "BH: SL not whitelisted");

        BridgehubBurnCTMAssetData memory bridgeData = abi.decode(_data, (BridgehubBurnCTMAssetData));
        require(_assetId == ctmAssetIdFromChainId(bridgeData.chainId), "BH: assetInfo 1");
        require(settlementLayer[bridgeData.chainId] == block.chainid, "BH: not current SL");
        settlementLayer[bridgeData.chainId] = _settlementChainId;

        address zkChain = zkChainMap.get(bridgeData.chainId);
        require(zkChain != address(0), "BH: zkChain not registered");
        require(_prevMsgSender == IZKChain(zkChain).getAdmin(), "BH: incorrect sender");

        bytes memory ctmMintData = IChainTypeManager(chainTypeManager[bridgeData.chainId]).forwardedBridgeBurn(
            bridgeData.chainId,
            bridgeData.ctmData
        );
        bytes memory chainMintData = IZKChain(zkChain).forwardedBridgeBurn(
            zkChainMap.get(_settlementChainId),
            _prevMsgSender,
            bridgeData.chainData
        );
        BridgehubMintCTMAssetData memory bridgeMintStruct = BridgehubMintCTMAssetData({
            chainId: bridgeData.chainId,
            baseTokenAssetId: baseTokenAssetId[bridgeData.chainId],
            ctmData: ctmMintData,
            chainData: chainMintData
        });
        bridgehubMintData = abi.encode(bridgeMintStruct);

        emit MigrationStarted(bridgeData.chainId, _assetId, _settlementChainId);
    }

    function bridgeMint(
        uint256, // originChainId
        bytes32 _assetId,
        bytes calldata _bridgehubMintData
    ) external payable override onlyAssetRouter whenMigrationsNotPaused {
        BridgehubMintCTMAssetData memory bridgeData = abi.decode(_bridgehubMintData, (BridgehubMintCTMAssetData));

        address ctm = ctmAssetIdToAddress[_assetId];
        require(ctm != address(0), "BH: assetInfo 2");
        require(settlementLayer[bridgeData.chainId] != block.chainid, "BH: already current SL");

        settlementLayer[bridgeData.chainId] = block.chainid;
        chainTypeManager[bridgeData.chainId] = ctm;
        baseTokenAssetId[bridgeData.chainId] = bridgeData.baseTokenAssetId;
        // To keep `assetIdIsRegistered` consistent, we'll also automatically register the base token.
        // It is assumed that if the bridging happened, the token was approved on L1 already.
        assetIdIsRegistered[bridgeData.baseTokenAssetId] = true;

        address zkChain = getZKChain(bridgeData.chainId);
        bool contractAlreadyDeployed = zkChain != address(0);
        if (!contractAlreadyDeployed) {
            zkChain = IChainTypeManager(ctm).forwardedBridgeMint(bridgeData.chainId, bridgeData.ctmData);
            require(zkChain != address(0), "BH: chain not registered");
            _registerNewZKChain(bridgeData.chainId, zkChain);
            messageRoot.addNewChain(bridgeData.chainId);
        }

        IZKChain(zkChain).forwardedBridgeMint(bridgeData.chainData, contractAlreadyDeployed);

        emit MigrationFinalized(bridgeData.chainId, _assetId, zkChain);
    }

    /// @dev IL1AssetHandler interface, used to undo a failed migration of a chain.
    /// @param _chainId the chainId of the chain
    /// @param _assetId the assetId of the chain's CTM
    /// @param _data the data for the recovery.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override onlyAssetRouter onlyL1 {
        BridgehubBurnCTMAssetData memory ctmAssetData = abi.decode(_data, (BridgehubBurnCTMAssetData));

        delete settlementLayer[_chainId];

        IChainTypeManager(chainTypeManager[_chainId]).forwardedBridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _ctmData: ctmAssetData.ctmData
        });

        IZKChain(getZKChain(_chainId)).forwardedBridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _assetInfo: _assetId,
            _prevMsgSender: _depositSender,
            _chainData: ctmAssetData.chainData
        });
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

    /// @notice Pauses migration functions.
    function pauseMigration() external onlyOwner {
        migrationPaused = true;
    }

    /// @notice Unpauses migration functions.
    function unpauseMigration() external onlyOwner {
        migrationPaused = false;
    }

    /*//////////////////////////////////////////////////////////////
                            Legacy functions
    //////////////////////////////////////////////////////////////*/

    /// @notice return the ZK chain contract for a chainId
    function getHyperchain(uint256 _chainId) public view returns (address) {
        return getZKChain(_chainId);
    }
}
