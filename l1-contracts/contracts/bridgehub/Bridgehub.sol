// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {EnumerableMap} from "@openzeppelin/contracts-v4/utils/structs/EnumerableMap.sol";

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner, BridgehubMintSTMAssetData, BridgehubBurnSTMAssetData} from "./IBridgehub.sol";
import {IL1AssetRouter} from "../bridge/interfaces/IL1AssetRouter.sol";
import {IL1BaseTokenAssetHandler} from "../bridge/interfaces/IL1BaseTokenAssetHandler.sol";
import {IStateTransitionManager} from "../state-transition/IStateTransitionManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IZkSyncHyperchain} from "../state-transition/chain-interfaces/IZkSyncHyperchain.sol";

import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS, SETTLEMENT_LAYER_RELAY_SENDER} from "../common/Config.sol";
import {BridgehubL2TransactionRequest, L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ISTMDeploymentTracker} from "./ISTMDeploymentTracker.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";
import {HyperchainLimitReached, Unauthorized, STMAlreadyRegistered, STMNotRegistered, ZeroChainId, ChainIdTooBig, SharedBridgeNotSet, BridgeHubAlreadyRegistered, AddressTooLow, MsgValueMismatch, WrongMagicValue, ZeroAddress} from "../common/L1ContractErrors.sol";

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

    /// @notice The total number of hyperchains can be created/connected to this STM.
    /// This is the temporary security measure.
    uint256 public immutable MAX_NUMBER_OF_HYPERCHAINS;

    /// @notice all the ether and ERC20 tokens are held by NativeVaultToken managed by this shared Bridge.
    IL1AssetRouter public sharedBridge;

    /// @notice StateTransitionManagers that are registered, and ZKchains that use these STMs can use this bridgehub as settlement layer.
    mapping(address stateTransitionManager => bool) public stateTransitionManagerIsRegistered;

    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address baseToken => bool) public __DEPRECATED_tokenIsRegistered;

    /// @notice chainID => StateTransitionManager contract address, STM that is managing rules for a given ZKchain.
    mapping(uint256 chainId => address) public stateTransitionManager;

    /// @notice chainID => baseToken contract address, token that is used as 'base token' by a given child chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => address) public __DEPRECATED_baseToken;

    /// @dev used to manage non critical updates
    address public admin;

    /// @dev used to accept the admin role
    address private pendingAdmin;

    /// @notice The map from chainId => hyperchain contract
    EnumerableMap.UintToAddressMap internal hyperchainMap;

    /// @notice The contract that stores the cross-chain message root for each chain and the aggregated root.
    /// @dev Note that the message root does not contain messages from the chain it is deployed on. It may
    /// be added later on if needed.
    IMessageRoot public override messageRoot;

    /// @notice Mapping from chain id to encoding of the base token used for deposits / withdrawals
    mapping(uint256 chainId => bytes32) public baseTokenAssetId;

    /// @notice The deployment tracker for the state transition managers.
    ISTMDeploymentTracker public stmDeployer;

    /// @dev asset info used to identify chains in the Shared Bridge
    mapping(bytes32 stmAssetId => address stmAddress) public stmAssetIdToAddress;

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

    modifier onlyChainSTM(uint256 _chainId) {
        require(msg.sender == stateTransitionManager[_chainId], "BH: not chain STM");
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
    constructor(uint256 _l1ChainId, address _owner, uint256 _maxNumberOfHyperchains) reentrancyGuardInitializer {
        _disableInitializers();
        L1_CHAIN_ID = _l1ChainId;
        MAX_NUMBER_OF_HYPERCHAINS = _maxNumberOfHyperchains;

        // Note that this assumes that the bridgehub only accepts transactions on chains with ETH base token only.
        // This is indeed true, since the only methods where this immutable is used are the ones with `onlyL1` modifier.
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
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
    /// @param _stmDeployer the stm deployment tracker address
    /// @param _messageRoot the message root address
    function setAddresses(
        address _sharedBridge,
        ISTMDeploymentTracker _stmDeployer,
        IMessageRoot _messageRoot
    ) external onlyOwner {
        sharedBridge = IL1AssetRouter(_sharedBridge);
        stmDeployer = _stmDeployer;
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
        address stm = stateTransitionManager[_chainId];
        require(stm != address(0), "BH: chain not legacy");
        require(!hyperchainMap.contains(_chainId), "BH: chain already migrated");
        /// Note we have to do this before STM is upgraded.
        address chainAddress = IStateTransitionManager(stm).getHyperchainLegacy(_chainId);
        require(chainAddress != address(0), "BH: chain not legacy 2");
        _registerNewHyperchain(_chainId, chainAddress);
    }

    //// Registry

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    /// @param _stateTransitionManager the state transition manager address to be added
    function addStateTransitionManager(address _stateTransitionManager) external onlyOwner {
        if (_stateTransitionManager == address(0)) {
            revert ZeroAddress();
        }
        if (stateTransitionManagerIsRegistered[_stateTransitionManager]) {
            revert STMAlreadyRegistered();
        }
        stateTransitionManagerIsRegistered[_stateTransitionManager] = true;

        emit StateTransitionManagerAdded(_stateTransitionManager);
    }

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    /// @notice this stops new Chains from using the STF, old chains are not affected
    /// @param _stateTransitionManager the state transition manager address to be removed
    function removeStateTransitionManager(address _stateTransitionManager) external onlyOwner {
        if (_stateTransitionManager == address(0)) {
            revert ZeroAddress();
        }
        if (!stateTransitionManagerIsRegistered[_stateTransitionManager]) {
            revert STMNotRegistered();
        }
        stateTransitionManagerIsRegistered[_stateTransitionManager] = false;

        emit StateTransitionManagerRemoved(_stateTransitionManager);
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
        // STM's assetId is `keccak256(abi.encode(L1_CHAIN_ID, stmDeployer, stmAddress))`.
        // And the STMDeployer is considered the deployment tracker for the STM asset.
        //
        // The STMDeployer will call this method to set the asset handler address for the assetId.
        // If the chain is not the same as L1, we assume that it is done via L1->L2 communication and so we unalias the sender.
        //
        // For simpler handling we allow anyone to call this method. It is okay, since during bridging operations
        // it is double checked that `assetId` is indeed derived from the `stmDeployer`.
        // TODO(EVM-703): This logic should be revised once interchain communication is implemented.

        address sender = L1_CHAIN_ID == block.chainid ? msg.sender : AddressAliasHelper.undoL1ToL2Alias(msg.sender);
        // This method can be accessed by STMDeployer only
        require(sender == address(stmDeployer), "BH: not stm deployer");
        require(stateTransitionManagerIsRegistered[_assetAddress], "STM not registered");

        bytes32 assetInfo = keccak256(abi.encode(L1_CHAIN_ID, sender, _additionalData));
        stmAssetIdToAddress[assetInfo] = _assetAddress;
        emit AssetRegistered(assetInfo, _assetAddress, _additionalData, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          Chain Registration
    //////////////////////////////////////////////////////////////*/

    /// @notice register new chain. New chains can be only registered on Bridgehub deployed on L1. Later they can be moved to any other layer.
    /// @notice for Eth the baseToken address is 1
    /// @param _chainId the chainId of the chain
    /// @param _stateTransitionManager the state transition manager address
    /// @param _baseTokenAssetId the base token asset id of the chain
    /// @param _salt the salt for the chainId, currently not used
    /// @param _admin the admin of the chain
    /// @param _initData the fixed initialization data for the chain
    /// @param _factoryDeps the factory dependencies for the chain's deployment
    function createNewChain(
        uint256 _chainId,
        address _stateTransitionManager,
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
        if (_stateTransitionManager == address(0)) {
            revert ZeroAddress();
        }
        if (_baseTokenAssetId == bytes32(0)) {
            revert ZeroAddress();
        }

        if (!stateTransitionManagerIsRegistered[_stateTransitionManager]) {
            revert STMNotRegistered();
        }

        // if (!tokenIsRegistered[_baseToken]) {
        //     revert TokenNotRegistered(_baseToken);
        // }
        require(assetIdIsRegistered[_baseTokenAssetId], "BH: asset id not registered");

        if (address(sharedBridge) == address(0)) {
            revert SharedBridgeNotSet();
        }
        if (stateTransitionManager[_chainId] != address(0)) {
            revert BridgeHubAlreadyRegistered();
        }

        stateTransitionManager[_chainId] = _stateTransitionManager;

        baseTokenAssetId[_chainId] = _baseTokenAssetId;
        settlementLayer[_chainId] = block.chainid;

        address chainAddress = IStateTransitionManager(_stateTransitionManager).createNewChain({
            _chainId: _chainId,
            _baseTokenAssetId: _baseTokenAssetId,
            _sharedBridge: address(sharedBridge),
            _admin: _admin,
            _initData: _initData,
            _factoryDeps: _factoryDeps
        });
        _registerNewHyperchain(_chainId, chainAddress);
        messageRoot.addNewChain(_chainId);

        emit NewChain(_chainId, _stateTransitionManager, _admin);
        return _chainId;
    }

    /// @dev This internal function is used to register a new hyperchain in the system.
    function _registerNewHyperchain(uint256 _chainId, address _hyperchain) internal {
        // slither-disable-next-line unused-return
        hyperchainMap.set(_chainId, _hyperchain);
        if (hyperchainMap.length() > MAX_NUMBER_OF_HYPERCHAINS) {
            revert HyperchainLimitReached();
        }
    }

    /*//////////////////////////////////////////////////////////////
                             Getters
    //////////////////////////////////////////////////////////////*/

    /// @notice baseToken function, which takes chainId as input, reads assetHandler from AR, and tokenAddress from AH
    function baseToken(uint256 _chainId) public view returns (address) {
        bytes32 baseTokenAssetId = baseTokenAssetId[_chainId];
        IL1BaseTokenAssetHandler assetHandlerAddress = IL1BaseTokenAssetHandler(
            sharedBridge.assetHandlerAddress(baseTokenAssetId)
        );
        return assetHandlerAddress.tokenAddress(baseTokenAssetId);
    }

    /// @notice Returns all the registered hyperchain addresses
    function getAllHyperchains() public view override returns (address[] memory chainAddresses) {
        uint256[] memory keys = hyperchainMap.keys();
        chainAddresses = new address[](keys.length);
        uint256 keysLength = keys.length;
        for (uint256 i = 0; i < keysLength; ++i) {
            chainAddresses[i] = hyperchainMap.get(keys[i]);
        }
    }

    /// @notice Returns all the registered hyperchain chainIDs
    function getAllHyperchainChainIDs() public view override returns (uint256[] memory) {
        return hyperchainMap.keys();
    }

    /// @notice Returns the address of the hyperchain with the corresponding chainID
    /// @param _chainId the chainId of the chain
    /// @return chainAddress the address of the hyperchain
    function getHyperchain(uint256 _chainId) public view override returns (address chainAddress) {
        // slither-disable-next-line unused-return
        (, chainAddress) = hyperchainMap.tryGet(_chainId);
    }

    function stmAssetIdFromChainId(uint256 _chainId) public view override returns (bytes32) {
        address stmAddress = stateTransitionManager[_chainId];
        require(stmAddress != address(0), "chain id not registered");
        return stmAssetId(stateTransitionManager[_chainId]);
    }

    function stmAssetId(address _stmAddress) public view override returns (bytes32) {
        return keccak256(abi.encode(L1_CHAIN_ID, address(stmDeployer), bytes32(uint256(uint160(_stmAddress)))));
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
        // Note: If the hyperchain with corresponding `chainId` is not yet created,
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

        address hyperchain = hyperchainMap.get(_request.chainId);
        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_request.refundRecipient, msg.sender);
        canonicalTxHash = IZkSyncHyperchain(hyperchain).bridgehubRequestL2Transaction(
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

        address hyperchain = hyperchainMap.get(_request.chainId);

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

        canonicalTxHash = IZkSyncHyperchain(hyperchain).bridgehubRequestL2Transaction(
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
    /// @param _transaction the transaction to be forwarded
    /// @param _factoryDeps the factory dependencies for the transaction
    /// @param _canonicalTxHash the canonical transaction hash
    /// @param _expirationTimestamp the expiration timestamp for the transaction
    function forwardTransactionOnGateway(
        uint256 _chainId,
        L2CanonicalTransaction calldata _transaction,
        bytes[] calldata _factoryDeps,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external override onlySettlementLayerRelayedSender {
        require(L1_CHAIN_ID != block.chainid, "BH: not in sync layer mode");
        address hyperchain = hyperchainMap.get(_chainId);
        IZkSyncHyperchain(hyperchain).bridgehubRequestL2TransactionOnGateway(
            _transaction,
            _factoryDeps,
            _canonicalTxHash,
            _expirationTimestamp
        );
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the hyperchain where to prove L2 message inclusion.
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
        address hyperchain = hyperchainMap.get(_chainId);
        return IZkSyncHyperchain(hyperchain).proveL2MessageInclusion(_batchNumber, _index, _message, _proof);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the hyperchain where to prove L2 log inclusion.
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
        address hyperchain = hyperchainMap.get(_chainId);
        return IZkSyncHyperchain(hyperchain).proveL2LogInclusion(_batchNumber, _index, _log, _proof);
    }

    /// @notice forwards function call to Mailbox based on ChainId
    /// @param _chainId The chain ID of the hyperchain where to prove L1->L2 tx status.
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
        address hyperchain = hyperchainMap.get(_chainId);
        return
            IZkSyncHyperchain(hyperchain).proveL1ToL2TransactionStatus({
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
        address hyperchain = hyperchainMap.get(_chainId);
        return IZkSyncHyperchain(hyperchain).l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    /*//////////////////////////////////////////////////////////////
                        Chain migration
    //////////////////////////////////////////////////////////////*/

    /// @notice IL1AssetHandler interface, used to migrate (transfer) a chain to the settlement layer.
    /// @param _settlementChainId the chainId of the settlement chain, i.e. where the message and the migrating chain is sent.
    /// @param _assetId the assetId of the migrating chain's STM
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

        BridgehubBurnSTMAssetData memory bridgeData = abi.decode(_data, (BridgehubBurnSTMAssetData));
        require(_assetId == stmAssetIdFromChainId(bridgeData.chainId), "BH: assetInfo 1");
        require(settlementLayer[bridgeData.chainId] == block.chainid, "BH: not current SL");
        settlementLayer[bridgeData.chainId] = _settlementChainId;

        address hyperchain = hyperchainMap.get(bridgeData.chainId);
        require(hyperchain != address(0), "BH: hyperchain not registered");
        require(_prevMsgSender == IZkSyncHyperchain(hyperchain).getAdmin(), "BH: incorrect sender");

        bytes memory stmMintData = IStateTransitionManager(stateTransitionManager[bridgeData.chainId])
            .forwardedBridgeBurn(bridgeData.chainId, bridgeData.stmData);
        bytes memory chainMintData = IZkSyncHyperchain(hyperchain).forwardedBridgeBurn(
            hyperchainMap.get(_settlementChainId),
            _prevMsgSender,
            bridgeData.chainData
        );
        BridgehubMintSTMAssetData memory bridgeMintStruct = BridgehubMintSTMAssetData({
            chainId: bridgeData.chainId,
            stmData: stmMintData,
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
        BridgehubMintSTMAssetData memory bridgeData = abi.decode(_bridgehubMintData, (BridgehubMintSTMAssetData));

        address stm = stmAssetIdToAddress[_assetId];
        require(stm != address(0), "BH: assetInfo 2");
        require(settlementLayer[bridgeData.chainId] != block.chainid, "BH: already current SL");

        settlementLayer[_chainId] = block.chainid;
        stateTransitionManager[_chainId] = stm;

        address hyperchain = getHyperchain(_chainId);
        bool contractAlreadyDeployed = hyperchain != address(0);
        if (!contractAlreadyDeployed) {
            hyperchain = IStateTransitionManager(stm).forwardedBridgeMint(bridgeData.chainId, bridgeData.stmData);
            require(hyperchain != address(0), "BH: chain not registered");
            _registerNewHyperchain(bridgeData.chainId, hyperchain);
            messageRoot.addNewChain(bridgeData.chainId);
        }

        IZkSyncHyperchain(hyperchain).forwardedBridgeMint(bridgeData.chainData);

        emit MigrationFinalized(bridgeData.chainId, _assetId, hyperchain);
    }

    /// @dev IL1AssetHandler interface, used to undo a failed migration of a chain.
    /// @param _chainId the chainId of the chain
    /// @param _assetId the assetId of the chain's STM
    /// @param _data the data for the recovery.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override onlyAssetRouter onlyL1 {
        BridgehubBurnSTMAssetData memory stmAssetData = abi.decode(_data, (BridgehubBurnSTMAssetData));

        delete settlementLayer[_chainId];

        IStateTransitionManager(stateTransitionManager[_chainId]).forwardedBridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _stmData: stmAssetData.stmData
        });

        IZkSyncHyperchain(getHyperchain(_chainId)).forwardedBridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _assetInfo: _assetId,
            _prevMsgSender: _depositSender,
            _chainData: stmAssetData.chainData
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
}
