// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {IBridgehub, L2TransactionRequestDirect, L2TransactionRequestTwoBridgesOuter, L2TransactionRequestTwoBridgesInner} from "./IBridgehub.sol";
import {IL1AssetRouter} from "../bridge/interfaces/IL1AssetRouter.sol";
import {IStateTransitionManager} from "../state-transition/IStateTransitionManager.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {IZkSyncHyperchain} from "../state-transition/chain-interfaces/IZkSyncHyperchain.sol";
import {ETH_TOKEN_ADDRESS, TWO_BRIDGES_MAGIC_VALUE, BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS} from "../common/L2ContractAddresses.sol";
import {BridgehubL2TransactionRequest, L2Message, L2Log, TxStatus} from "../common/Messaging.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {ISTMDeploymentTracker} from "./ISTMDeploymentTracker.sol";
import {L2CanonicalTransaction} from "../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The Bridgehub contract serves as the primary entry point for L1<->L2 communication,
/// facilitating interactions between end user and bridges.
/// It also manages state transition managers, base tokens, and chain registrations.
/// Bridgehub is also an IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
contract Bridgehub is IBridgehub, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    /// @notice the asset id of Eth
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @dev The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 public immutable L1_CHAIN_ID;

    /// @notice all the ether and ERC20 tokens are held by NativeVaultToken managed by this shared Bridge.
    IL1AssetRouter public sharedBridge;

    /// @notice StateTransitionManagers that are registered, and ZKchains that use these STMs can use this bridgehub as settlement layer.
    mapping(address stateTransitionManager => bool) public stateTransitionManagerIsRegistered;
    /// @notice we store registered tokens (for arbitrary base token)
    mapping(address token => bool) public tokenIsRegistered;

    /// @notice chainID => StateTransitionManager contract address, STM that is managing rules for a given ZKchain.
    mapping(uint256 chainId => address) public stateTransitionManager;

    /// @notice chainID => baseToken contract address, token that is used as 'base token' by a given child chain.
    mapping(uint256 chainId => address) public baseToken;

    /// @dev used to manage non critical updates
    address public admin;

    /// @dev used to accept the admin role
    address private pendingAdmin;

    // FIXME: `messageRoot` DOES NOT contain messages that come from the current layer and go to the settlement layer.
    // it may make sense to store the final root somewhere for interop purposes.
    // THough maybe it can be postponed.
    IMessageRoot public override messageRoot;

    /// @notice Mapping from chain id to encoding of the base token used for deposits / withdrawals
    mapping(uint256 chainId => bytes32 baseTokenAssetId) public baseTokenAssetId;

    ISTMDeploymentTracker public stmDeployer;

    /// @dev asset info used to identify chains in the Shared Bridge
    mapping(bytes32 stmAssetId => address stmAddress) public stmAssetIdToAddress;

    /// @dev used to indicate the currently active settlement layer for a given chainId
    mapping(uint256 chainId => uint256 activeSettlementLayerChainId) public settlementLayer;

    /// @dev Sync layer chain is expected to have .. as the base token.
    mapping(uint256 chainId => bool isWhitelistedSyncLayer) public whitelistedSettlementLayers;

    /// @notice to avoid parity hack
    constructor(uint256 _l1ChainId, address _owner) reentrancyGuardInitializer {
        _disableInitializers();
        L1_CHAIN_ID = _l1ChainId;
        // TODO: this assumes that the bridgehub is deployed only on the chains that have ETH as base token.
        ETH_TOKEN_ASSET_ID = keccak256(abi.encode(block.chainid, L2_NATIVE_TOKEN_VAULT_ADDRESS, ETH_TOKEN_ADDRESS));
        _transferOwnership(_owner);
    }

    /// @notice used to initialize the contract
    /// @notice this contract is also deployed on L2 as a system contract there the owner and the related functions will not be used
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    modifier onlyOwnerOrAdmin() {
        require(msg.sender == admin || msg.sender == owner(), "Bridgehub: not owner or admin");
        _;
    }

    modifier onlyChainSTM(uint256 _chainId) {
        require(msg.sender == stateTransitionManager[_chainId], "BH: not chain STM");
        _;
    }

    //// Initialization and registration

    /// @inheritdoc IBridgehub
    /// @dev Please note, if the owner wants to enforce the admin change it must execute both `setPendingAdmin` and
    /// `acceptAdmin` atomically. Otherwise `admin` can set different pending admin and so fail to accept the admin rights.
    function setPendingAdmin(address _newPendingAdmin) external onlyOwnerOrAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = pendingAdmin;
        // Change pending admin
        pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @inheritdoc IBridgehub
    function acceptAdmin() external {
        address currentPendingAdmin = pendingAdmin;
        require(msg.sender == currentPendingAdmin, "n42"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = admin;
        admin = currentPendingAdmin;
        delete pendingAdmin;

        emit NewPendingAdmin(currentPendingAdmin, address(0));
        emit NewAdmin(previousAdmin, currentPendingAdmin);
    }

    /// @notice To set stmDeploymetTracker, only Owner. Not done in initialize, as
    /// the order of deployment is Bridgehub, Shared bridge, and then we call this
    function setSTMDeployer(ISTMDeploymentTracker _stmDeployer) external onlyOwner {
        stmDeployer = _stmDeployer;
    }

    /// @notice To set shared bridge, only Owner. Not done in initialize, as
    /// the order of deployment is Bridgehub, Shared bridge, and then we call this
    function setAddresses(
        address _sharedBridge,
        ISTMDeploymentTracker _stmDeployer,
        IMessageRoot _messageRoot
    ) external onlyOwner {
        sharedBridge = IL1AssetRouter(_sharedBridge);
        stmDeployer = _stmDeployer;
        messageRoot = _messageRoot;
    }

    //// Registry

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    function addStateTransitionManager(address _stateTransitionManager) external onlyOwner {
        require(
            !stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition already registered"
        );
        stateTransitionManagerIsRegistered[_stateTransitionManager] = true;
    }

    /// @notice State Transition can be any contract with the appropriate interface/functionality
    /// @notice this stops new Chains from using the STF, old chains are not affected
    function removeStateTransitionManager(address _stateTransitionManager) external onlyOwner {
        require(
            stateTransitionManagerIsRegistered[_stateTransitionManager],
            "Bridgehub: state transition not registered yet"
        );
        stateTransitionManagerIsRegistered[_stateTransitionManager] = false;
    }

    /// @notice token can be any contract with the appropriate interface/functionality
    function addToken(address _token) external onlyOwner {
        require(!tokenIsRegistered[_token], "Bridgehub: token already registered");
        tokenIsRegistered[_token] = true;
    }

    /// @notice To set shared bridge, only Owner. Not done in initialize, as
    /// the order of deployment is Bridgehub, Shared bridge, and then we call this
    function setSharedBridge(address _sharedBridge) external onlyOwner {
        sharedBridge = IL1AssetRouter(_sharedBridge);
    }

    function registerSyncLayer(
        uint256 _newSyncLayerChainId,
        bool _isWhitelisted
    ) external onlyChainSTM(_newSyncLayerChainId) {
        whitelistedSettlementLayers[_newSyncLayerChainId] = _isWhitelisted;

        // TODO: emit event
    }

    /// @dev Used to set the assetAddress for a given assetInfo.
    // TODO: add better explanation of this method.
    function setAssetHandlerAddressInitial(bytes32 _additionalData, address _assetAddress) external {
        address sender = L1_CHAIN_ID == block.chainid ? msg.sender : AddressAliasHelper.undoL1ToL2Alias(msg.sender); // Todo: this might be dangerous. We should decide based on the tx type.
        bytes32 assetInfo = keccak256(abi.encode(L1_CHAIN_ID, sender, _additionalData)); /// todo make other asse
        stmAssetIdToAddress[assetInfo] = _assetAddress;
        emit AssetRegistered(assetInfo, _assetAddress, _additionalData, msg.sender);
    }

    ///// Getters

    /// @notice return the state transition chain contract for a chainId
    function getHyperchain(uint256 _chainId) public view returns (address) {
        return IStateTransitionManager(stateTransitionManager[_chainId]).getHyperchain(_chainId);
    }

    function stmAssetIdFromChainId(uint256 _chainId) public view override returns (bytes32) {
        return stmAssetId(stateTransitionManager[_chainId]);
    }

    function stmAssetId(address _stmAddress) public view override returns (bytes32) {
        require(stateTransitionManagerIsRegistered[_stmAddress] == true, "BH: STM not registered");
        return keccak256(abi.encode(L1_CHAIN_ID, address(stmDeployer), bytes32(uint256(uint160(_stmAddress)))));
    }

    /// New chain

    /// @notice register new chain. New chains can be only registered on Bridgehub deployed on L1. Later they can be moved to any other layer.
    /// @notice for Eth the baseToken address is 1
    function createNewChain(
        uint256 _chainId,
        address _stateTransitionManager,
        address _baseToken,
        // solhint-disable-next-line no-unused-vars
        uint256 _salt,
        address _admin,
        bytes calldata _initData,
        bytes[] calldata _factoryDeps
    ) external onlyOwnerOrAdmin nonReentrant whenNotPaused returns (uint256) {
        require(L1_CHAIN_ID == block.chainid, "BH: New chain registration only allowed on L1");
        require(_chainId != 0, "BH: chainId cannot be 0");
        require(_chainId <= type(uint48).max, "BH: chainId too large");
        require(_chainId != block.chainid, "BH: chain id must not match current chainid");

        require(stateTransitionManagerIsRegistered[_stateTransitionManager], "BH: state transition not registered");
        require(tokenIsRegistered[_baseToken], "BH: token not registered");
        require(address(sharedBridge) != address(0), "BH: weth bridge not set");

        require(stateTransitionManager[_chainId] == address(0), "BH: chainId already registered");

        stateTransitionManager[_chainId] = _stateTransitionManager;
        baseToken[_chainId] = _baseToken;
        /// For now all base tokens have to use the NTV.
        baseTokenAssetId[_chainId] = sharedBridge.nativeTokenVault().getAssetId(_baseToken);
        settlementLayer[_chainId] = block.chainid;

        IStateTransitionManager(_stateTransitionManager).createNewChain({
            _chainId: _chainId,
            _baseToken: _baseToken,
            _sharedBridge: address(sharedBridge),
            _admin: _admin,
            _initData: _initData,
            _factoryDeps: _factoryDeps
        });
        messageRoot.addNewChain(_chainId);

        emit NewChain(_chainId, _stateTransitionManager, _admin);
        return _chainId;
    }

    /*//////////////////////////////////////////////////////////////
                        Mailbox forwarder
    //////////////////////////////////////////////////////////////*/

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
        address hyperchain = getHyperchain(_chainId);
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
        address hyperchain = getHyperchain(_chainId);
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
        address hyperchain = getHyperchain(_chainId);
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
        address hyperchain = getHyperchain(_chainId);
        return IZkSyncHyperchain(hyperchain).l2TransactionBaseCost(_gasPrice, _l2GasLimit, _l2GasPerPubdataByteLimit);
    }

    /// @notice the mailbox is called directly after the sharedBridge received the deposit
    /// this assumes that either ether is the base token or
    /// the msg.sender has approved mintValue allowance for the sharedBridge.
    /// This means this is not ideal for contract calls, as the contract would have to handle token allowance of the base Token
    function requestL2TransactionDirect(
        L2TransactionRequestDirect calldata _request
    ) external payable override nonReentrant whenNotPaused returns (bytes32 canonicalTxHash) {
        // Note: If the hyperchain with corresponding `chainId` is not yet created,
        // the transaction will revert on `bridgehubRequestL2Transaction` as call to zero address.
        {
            bytes32 tokenAssetId = baseTokenAssetId[_request.chainId];
            if (tokenAssetId == ETH_TOKEN_ASSET_ID) {
                require(msg.value == _request.mintValue, "Bridgehub: msg.value mismatch 1");
            } else {
                require(msg.value == 0, "Bridgehub: non-eth bridge with msg.value");
            }

            // slither-disable-next-line arbitrary-send-eth
            sharedBridge.bridgehubDepositBaseToken{value: msg.value}(
                _request.chainId,
                tokenAssetId,
                msg.sender,
                _request.mintValue
            );
        }

        address hyperchain = getHyperchain(_request.chainId);
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
    ///  the msg.sender has approved the sharedBridge with the mintValue,
    ///  and also the necessary approvals are given for the second bridge.
    /// @notice The logic of this bridge is to allow easy depositing for bridges.
    /// Each contract that handles the users ERC20 tokens needs approvals from the user, this contract allows
    /// the user to approve for each token only its respective bridge
    /// @notice This function is great for contract calls to L2, the secondBridge can be any contract.
    function requestL2TransactionTwoBridges(
        L2TransactionRequestTwoBridgesOuter calldata _request
    ) external payable override nonReentrant whenNotPaused returns (bytes32 canonicalTxHash) {
        {
            bytes32 tokenAssetId = baseTokenAssetId[_request.chainId];
            uint256 baseTokenMsgValue;
            if (tokenAssetId == ETH_TOKEN_ASSET_ID) {
                require(
                    msg.value == _request.mintValue + _request.secondBridgeValue,
                    "Bridgehub: msg.value mismatch 2"
                );
                baseTokenMsgValue = _request.mintValue;
            } else {
                require(msg.value == _request.secondBridgeValue, "Bridgehub: msg.value mismatch 3");
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

        address hyperchain = getHyperchain(_request.chainId);

        // slither-disable-next-line arbitrary-send-eth
        L2TransactionRequestTwoBridgesInner memory outputRequest = IL1AssetRouter(_request.secondBridgeAddress)
            .bridgehubDeposit{value: _request.secondBridgeValue}(
            _request.chainId,
            msg.sender,
            _request.l2Value,
            _request.secondBridgeCalldata
        );

        require(outputRequest.magicValue == TWO_BRIDGES_MAGIC_VALUE, "Bridgehub: magic value mismatch");

        address refundRecipient = AddressAliasHelper.actualRefundRecipient(_request.refundRecipient, msg.sender);

        require(
            _request.secondBridgeAddress > BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS,
            "Bridgehub: second bridge address too low"
        ); // to avoid calls to precompiles
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

    function forwardTransactionOnSyncLayer(
        uint256 _chainId,
        L2CanonicalTransaction calldata _transaction,
        bytes[] calldata _factoryDeps,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external override {
        require(L1_CHAIN_ID != block.chainid, "BH: not in sync layer mode");
        address hyperchain = getHyperchain(_chainId);
        IZkSyncHyperchain(hyperchain).bridgehubRequestL2TransactionOnSyncLayer(
            _transaction,
            _factoryDeps,
            _canonicalTxHash,
            _expirationTimestamp
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Chain migration
    //////////////////////////////////////////////////////////////

    Methods below are used when we're moving a 'child' chain between different layers
    For example from L1 to Gateway.
    In these cases, we treat the child chain as an 'NFT' (and STM as assetId / NFT contract) - where we burn it
    in the 'source bridgehub' and then we mint it in the destination bridgehub.
    */

    /// @dev "burns" the child chain on this bridgehub for the migration. Packages all the necessary child
    /// chain state (like committed batches etc) into bridehubMintData.
    function bridgeBurn(
        uint256 _settlementChainId,
        uint256, // mintValue
        bytes32 _assetId,
        address _prevMsgSender,
        bytes calldata _data
    ) external payable override returns (bytes memory bridgehubMintData) {
        require(whitelistedSettlementLayers[_settlementChainId], "BH: SL not whitelisted");

        (uint256 _chainId, bytes memory _stmData, bytes memory _chainData) = abi.decode(_data, (uint256, bytes, bytes));
        require(_assetId == stmAssetIdFromChainId(_chainId), "BH: assetInfo 1");
        require(settlementLayer[_chainId] == block.chainid, "BH: not current SL");
        settlementLayer[_chainId] = _settlementChainId;

        bytes memory stmMintData = IStateTransitionManager(stateTransitionManager[_chainId]).forwardedBridgeBurn(
            _chainId,
            _stmData
        );
        bytes memory chainMintData = IZkSyncHyperchain(getHyperchain(_chainId)).forwardedBridgeBurn(
            getHyperchain(_settlementChainId),
            _prevMsgSender,
            _chainData
        );
        bridgehubMintData = abi.encode(_chainId, stmMintData, chainMintData);
        // TODO: double check that get only returns when chain id is there.
    }

    /// @dev Creates the child chain on this bridgehub.
    function bridgeMint(
        uint256, // chainId
        bytes32 _assetId,
        bytes calldata _bridgehubMintData
    ) external payable override returns (address l1Receiver) {
        (uint256 _chainId, bytes memory _stmData, bytes memory _chainMintData) = abi.decode(
            _bridgehubMintData,
            (uint256, bytes, bytes)
        );
        address stm = stmAssetIdToAddress[_assetId];
        require(stm != address(0), "BH: assetInfo 2");
        require(settlementLayer[_chainId] != block.chainid, "BH: already current SL");

        settlementLayer[_chainId] = block.chainid;
        stateTransitionManager[_chainId] = stm;
        address hyperchain = getHyperchain(_chainId);
        if (hyperchain == address(0)) {
            hyperchain = IStateTransitionManager(stm).forwardedBridgeMint(_chainId, _stmData);
        }

        IMessageRoot(messageRoot).addNewChainIfNeeded(_chainId);
        IZkSyncHyperchain(hyperchain).forwardedBridgeMint(_chainMintData);
        return address(0);
    }

    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        bytes32 _assetId,
        bytes calldata _data
    ) external payable override {}

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
}
