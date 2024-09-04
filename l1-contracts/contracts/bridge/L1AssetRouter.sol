// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable reason-string, gas-custom-errors

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL1AssetRouter} from "./interfaces/IL1AssetRouter.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IL2BridgeLegacy} from "./interfaces/IL2BridgeLegacy.sol";
import {IL1AssetHandler} from "./interfaces/IL1AssetHandler.sol";
import {IL1NativeTokenVault} from "./interfaces/IL1NativeTokenVault.sol";
import {IL1SharedBridgeLegacy} from "./interfaces/IL1SharedBridgeLegacy.sol";

import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";
import {TWO_BRIDGES_MAGIC_VALUE, ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../common/L2ContractAddresses.sol";
import {NotNTV, EthTransferFailed, NativeTokenVaultAlreadySet, NativeTokenVault0, LegacycFD, LegacyEthWithdrawal, LegacyTokenWithdrawal, WrongMsgLength, NotNTVorADT, AssetHandlerNotSet, NewEncodingFormatNotYetSupportedForNTV, AssetHandlerDoesNotExistForAssetId} from "./L1BridgeContractErrors.sol";

import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR} from "../common/L2ContractAddresses.sol";

import {BridgeHelper} from "./BridgeHelper.sol";

import {IL1AssetDeploymentTracker} from "../bridge/interfaces/IL1AssetDeploymentTracker.sol";

import {AssetIdNotSupported, Unauthorized, ZeroAddress, SharedBridgeKey, TokenNotSupported, DepositExists, AddressAlreadyUsed, InvalidProof, DepositDoesNotExist, SharedBridgeValueNotSet, WithdrawalAlreadyFinalized, L2WithdrawalMessageWrongLength, InvalidSelector, SharedBridgeValueNotSet} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1AssetRouter is
    IL1AssetRouter,
    IL1SharedBridgeLegacy,
    ReentrancyGuard,
    Ownable2StepUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    /// @dev The address of the WETH token on L1.
    address public immutable override L1_WETH_TOKEN;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @dev The address of ZKsync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev The encoding version used for new txs.
    bytes1 internal constant LEGACY_ENCODING_VERSION = 0x00;

    /// @dev The encoding version used for legacy txs.
    bytes1 internal constant NEW_ENCODING_VERSION = 0x01;

    /// @dev The encoding version used for txs that set the asset handler on the counterpart contract.
    bytes1 internal constant SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION = 0x02;

    /// @dev Stores the first batch number on the ZKsync Era Diamond Proxy that was settled after Diamond proxy upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade Eth withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostDiamondUpgradeFirstBatch;

    /// @dev Stores the first batch number on the ZKsync Era Diamond Proxy that was settled after L1ERC20 Bridge upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade ERC20 withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostLegacyBridgeUpgradeFirstBatch;

    /// @dev Stores the ZKsync Era batch number that processes the last deposit tx initiated by the legacy bridge
    /// This variable (together with eraLegacyBridgeLastDepositTxNumber) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older batches
    /// than this value are considered to have been processed prior to the upgrade and handled separately.
    /// We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously.
    uint256 internal eraLegacyBridgeLastDepositBatch;

    /// @dev The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge
    /// This variable (together with eraLegacyBridgeLastDepositBatch) is used to differentiate between pre-upgrade and post-upgrade deposits. Deposits processed in older txs
    /// than this value are considered to have been processed prior to the upgrade and handled separately.
    /// We use this both for Eth and erc20 token deposits, so we need to update the diamond and bridge simultaneously.
    uint256 internal eraLegacyBridgeLastDepositTxNumber;

    /// @dev Legacy bridge smart contract that used to hold ERC20 tokens.
    IL1ERC20Bridge public override legacyBridge;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => address l2Bridge) public __DEPRECATED_l2BridgeAddress;

    /// @dev A mapping chainId => L2 deposit transaction hash => dataHash
    // keccak256(abi.encode(account, tokenAddress, amount)) for legacy transfers
    // keccak256(abi.encode(_prevMsgSender, assetId, transferData)) for new transfers
    /// @dev Tracks deposit transactions to L2 to enable users to claim their funds if a deposit fails.
    mapping(uint256 chainId => mapping(bytes32 l2DepositTxHash => bytes32 depositDataHash))
        public
        override depositHappened;

    /// @dev Tracks the processing status of L2 to L1 messages, indicating whether a message has already been finalized.
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        public isWithdrawalFinalized;

    /// @notice Deprecated. Kept for backwards compatibility.
    /// @dev Indicates whether the hyperbridging is enabled for a given chain.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => bool enabled) public hyperbridgingEnabled;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chain.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public chainBalance;

    /// @dev Maps asset ID to address of corresponding asset handler.
    /// @dev Tracks the address of Asset Handler contracts, where bridged funds are locked for each asset.
    /// @dev P.S. this liquidity was locked directly in SharedBridge before.
    mapping(bytes32 assetId => address assetHandlerAddress) public assetHandlerAddress;

    /// @dev Maps asset ID to the asset deployment tracker address.
    /// @dev Tracks the address of Deployment Tracker contract on L1, which sets Asset Handlers on L2s (ZK chain).
    /// @dev For the asset and stores respective addresses.
    mapping(bytes32 assetId => address assetDeploymentTracker) public assetDeploymentTracker;

    /// @dev Address of native token vault.
    IL1NativeTokenVault public nativeTokenVault;

    /// @notice Checks that the message sender is the bridgehub.
    modifier onlyBridgehub() {
        if (msg.sender != address(BRIDGE_HUB)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or ZKsync Era Diamond Proxy.
    modifier onlyBridgehubOrEra(uint256 _chainId) {
        if (msg.sender != address(BRIDGE_HUB) && (_chainId != ERA_CHAIN_ID || msg.sender != ERA_DIAMOND_PROXY)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the legacy bridge.
    modifier onlyLegacyBridge() {
        if (msg.sender != address(legacyBridge)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        address _l1WethAddress,
        IBridgehub _bridgehub,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) reentrancyGuardInitializer {
        _disableInitializers();
        L1_WETH_TOKEN = _l1WethAddress;
        BRIDGE_HUB = _bridgehub;
        ERA_CHAIN_ID = _eraChainId;
        ERA_DIAMOND_PROXY = _eraDiamondProxy;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy.
    /// @dev Used for testing purposes only, as the contract has been initialized on mainnet.
    /// @param _owner The address which can change L2 token implementation and upgrade the bridge implementation.
    /// The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    /// @param _eraPostDiamondUpgradeFirstBatch The first batch number on the ZKsync Era Diamond Proxy that was settled after diamond proxy upgrade.
    /// @param _eraPostLegacyBridgeUpgradeFirstBatch The first batch number on the ZKsync Era Diamond Proxy that was settled after legacy bridge upgrade.
    /// @param _eraLegacyBridgeLastDepositBatch The the ZKsync Era batch number that processes the last deposit tx initiated by the legacy bridge.
    /// @param _eraLegacyBridgeLastDepositTxNumber The tx number in the _eraLegacyBridgeLastDepositBatch of the last deposit tx initiated by the legacy bridge.
    function initialize(
        address _owner,
        uint256 _eraPostDiamondUpgradeFirstBatch,
        uint256 _eraPostLegacyBridgeUpgradeFirstBatch,
        uint256 _eraLegacyBridgeLastDepositBatch,
        uint256 _eraLegacyBridgeLastDepositTxNumber
    ) external reentrancyGuardInitializer initializer {
        if (_owner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_owner);
        if (eraPostDiamondUpgradeFirstBatch == 0) {
            eraPostDiamondUpgradeFirstBatch = _eraPostDiamondUpgradeFirstBatch;
            eraPostLegacyBridgeUpgradeFirstBatch = _eraPostLegacyBridgeUpgradeFirstBatch;
            eraLegacyBridgeLastDepositBatch = _eraLegacyBridgeLastDepositBatch;
            eraLegacyBridgeLastDepositTxNumber = _eraLegacyBridgeLastDepositTxNumber;
        }
    }

    /// @notice Transfers tokens from shared bridge to native token vault.
    /// @dev This function is part of the upgrade process used to transfer liquidity.
    /// @param _token The address of the token to be transferred to NTV.
    function transferTokenToNTV(address _token) external {
        address ntvAddress = address(nativeTokenVault);
        if (msg.sender != ntvAddress) {
            revert NotNTV();
        }
        if (ETH_TOKEN_ADDRESS == _token) {
            uint256 amount = address(this).balance;
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), ntvAddress, amount, 0, 0, 0, 0)
            }
            if (!callSuccess) {
                revert EthTransferFailed();
            }
        } else {
            IERC20(_token).safeTransfer(ntvAddress, IERC20(_token).balanceOf(address(this)));
        }
    }

    /// @notice Clears chain balance for specific token.
    /// @dev This function is part of the upgrade process used to nullify chain balances once they are credited to NTV.
    /// @param _chainId The ID of the ZK chain.
    /// @param _token The address of the token which was previously deposit to shared bridge.
    function nullifyChainBalanceByNTV(uint256 _chainId, address _token) external {
        if (msg.sender != address(nativeTokenVault)) {
            revert NotNTV();
        }
        chainBalance[_chainId][_token] = 0;
    }

    /// @notice Legacy function used for migration, do not use!
    /// @param _chainId The chain id on which the bridge is deployed.
    // slither-disable-next-line uninitialized-state-variables
    function l2BridgeAddress(uint256 _chainId) external view returns (address) {
        // slither-disable-next-line uninitialized-state-variables
        return __DEPRECATED_l2BridgeAddress[_chainId];
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _legacyBridge The address of the legacy bridge.
    function setL1Erc20Bridge(address _legacyBridge) external onlyOwner {
        if (address(legacyBridge) != address(0)) {
            revert AddressAlreadyUsed(address(legacyBridge));
        }
        if (_legacyBridge == address(0)) {
            revert ZeroAddress();
        }
        legacyBridge = IL1ERC20Bridge(_legacyBridge);
    }

    /// @notice Sets the nativeTokenVault contract address.
    /// @dev Should be called only once by the owner.
    /// @param _nativeTokenVault The address of the native token vault.
    function setNativeTokenVault(IL1NativeTokenVault _nativeTokenVault) external onlyOwner {
        if (address(nativeTokenVault) != address(0)) {
            revert NativeTokenVaultAlreadySet();
        }
        if (address(_nativeTokenVault) == address(0)) {
            revert NativeTokenVault0();
        }
        nativeTokenVault = _nativeTokenVault;
    }

    /// @notice Used to set the assed deployment tracker address for given asset data.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetDeploymentTracker The whitelisted address of asset deployment tracker for provided asset.
    function setAssetDeploymentTracker(
        bytes32 _assetRegistrationData,
        address _assetDeploymentTracker
    ) external onlyOwner {
        bytes32 assetId = keccak256(
            abi.encode(uint256(block.chainid), _assetDeploymentTracker, _assetRegistrationData)
        );
        assetDeploymentTracker[assetId] = _assetDeploymentTracker;
        emit AssetDeploymentTrackerSet(assetId, _assetDeploymentTracker, _assetRegistrationData);
    }

    /// @notice Sets the asset handler address for a specified asset ID on the chain of the asset deployment tracker.
    /// @dev The caller of this function is encoded within the `assetId`, therefore, it should be invoked by the asset deployment tracker contract.
    /// @dev Typically, for most tokens, ADT is the native token vault. However, custom tokens may have their own specific asset deployment trackers.
    /// @dev `setAssetHandlerAddressOnCounterpart` should be called on L1 to set asset handlers on L2 chains for a specific asset ID.
    /// @param _assetRegistrationData The asset data which may include the asset address and any additional required data or encodings.
    /// @param _assetHandlerAddress The address of the asset handler to be set for the provided asset.
    function setAssetHandlerAddressThisChain(bytes32 _assetRegistrationData, address _assetHandlerAddress) external {
        bool senderIsNTV = msg.sender == address(nativeTokenVault);
        address sender = senderIsNTV ? L2_NATIVE_TOKEN_VAULT_ADDR : msg.sender;
        bytes32 assetId = DataEncoding.encodeAssetId(block.chainid, _assetRegistrationData, sender);
        if (!senderIsNTV && msg.sender != assetDeploymentTracker[assetId]) {
            revert NotNTVorADT();
        }
        assetHandlerAddress[assetId] = _assetHandlerAddress;
        if (senderIsNTV) {
            assetDeploymentTracker[assetId] = msg.sender;
        }
        emit AssetHandlerRegisteredInitial(assetId, _assetHandlerAddress, _assetRegistrationData, sender);
    }

    /// @notice Used to set the asset handler address for a given asset ID on a remote ZK chain
    /// @dev No access control on the caller, as msg.sender is encoded in the assetId.
    /// @param _chainId The ZK chain ID.
    /// @param _assetId The encoding of asset ID.
    /// @param _assetHandlerAddressOnCounterpart The address of the asset handler, which will hold the token of interest.
    /// @return request The tx request sent to the Bridgehub
    function _setAssetHandlerAddressOnCounterpart(
        uint256 _chainId,
        address _prevMsgSender,
        bytes32 _assetId,
        address _assetHandlerAddressOnCounterpart
    ) internal returns (L2TransactionRequestTwoBridgesInner memory request) {
        IL1AssetDeploymentTracker(assetDeploymentTracker[_assetId]).bridgeCheckCounterpartAddress(
            _chainId,
            _assetId,
            _prevMsgSender,
            _assetHandlerAddressOnCounterpart
        );

        bytes memory l2Calldata = abi.encodeCall(
            IL2Bridge.setAssetHandlerAddress,
            (_assetId, _assetHandlerAddressOnCounterpart)
        );
        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2Calldata,
            factoryDeps: new bytes[](0),
            txDataHash: bytes32(0x00)
        });
    }

    /// @notice Allows bridgehub to acquire mintValue for L1->L2 transactions.
    /// @dev If the corresponding L2 transaction fails, refunds are issued to a refund recipient on L2.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _assetId The deposited asset ID.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _amount The total amount of tokens to be bridged.
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        bytes32 _assetId,
        address _prevMsgSender,
        uint256 _amount
    ) external payable onlyBridgehubOrEra(_chainId) whenNotPaused {
        address l1AssetHandler = assetHandlerAddress[_assetId];
        if (l1AssetHandler == address(0)) {
            revert AssetHandlerNotSet();
        }

        _transferAllowanceToNTV(_assetId, _amount, _prevMsgSender);
        // slither-disable-next-line unused-return
        IL1AssetHandler(l1AssetHandler).bridgeBurn{value: msg.value}({
            _chainId: _chainId,
            _l2Value: 0,
            _assetId: _assetId,
            _prevMsgSender: _prevMsgSender,
            _data: abi.encode(_amount, address(0))
        });

        // Note that we don't save the deposited amount, as this is for the base token, which gets sent to the refundRecipient if the tx fails
        emit BridgehubDepositBaseTokenInitiated(_chainId, _prevMsgSender, _assetId, _amount);
    }

    /// @notice Initiates a deposit transaction within Bridgehub, used by `requestL2TransactionTwoBridges`.
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Value The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _data The calldata for the second bridge deposit.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        uint256 _l2Value,
        bytes calldata _data
    )
        external
        payable
        override
        onlyBridgehub
        whenNotPaused
        returns (L2TransactionRequestTwoBridgesInner memory request)
    {
        bytes32 assetId;
        bytes memory transferData;
        bytes1 encodingVersion = _data[0];

        // The new encoding ensures that the calldata is collision-resistant with respect to the legacy format.
        // In the legacy calldata, the first input was the address, meaning the most significant byte was always `0x00`.
        if (encodingVersion == SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION) {
            (bytes32 _assetId, address _assetHandlerAddressOnCounterpart) = abi.decode(_data[1:], (bytes32, address));
            return
                _setAssetHandlerAddressOnCounterpart(
                    _chainId,
                    _prevMsgSender,
                    _assetId,
                    _assetHandlerAddressOnCounterpart
                );
        } else if (encodingVersion == NEW_ENCODING_VERSION) {
            (assetId, transferData) = abi.decode(_data[1:], (bytes32, bytes));
            if (assetHandlerAddress[assetId] == address(nativeTokenVault)) {
                revert NewEncodingFormatNotYetSupportedForNTV();
            }
        } else {
            (assetId, transferData) = _handleLegacyData(_data, _prevMsgSender);
        }

        if (BRIDGE_HUB.baseTokenAssetId(_chainId) == assetId) {
            revert AssetIdNotSupported(assetId);
        }

        bytes memory bridgeMintCalldata = _burn({
            _chainId: _chainId,
            _l2Value: _l2Value,
            _assetId: assetId,
            _prevMsgSender: _prevMsgSender,
            _transferData: transferData,
            _passValue: true
        });
        bytes32 txDataHash = this.encodeTxDataHash(encodingVersion, _prevMsgSender, assetId, transferData);

        request = _requestToBridge({
            _prevMsgSender: _prevMsgSender,
            _assetId: assetId,
            _bridgeMintCalldata: bridgeMintCalldata,
            _txDataHash: txDataHash
        });

        emit BridgehubDepositInitiated({
            chainId: _chainId,
            txDataHash: txDataHash,
            from: _prevMsgSender,
            assetId: assetId,
            bridgeMintCalldata: bridgeMintCalldata
        });
    }

    /// @notice Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
    /// This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.
    /// @param _chainId The chain ID of the ZK chain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyBridgehub whenNotPaused {
        if (depositHappened[_chainId][_txHash] != 0x00) {
            revert DepositExists();
        }
        depositHappened[_chainId][_txHash] = _txDataHash;
        emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _chainId The chain ID of the transaction to check
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override {
        _finalizeWithdrawal({
            _chainId: _chainId,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
    }

    /// @dev Calls the internal `_encodeTxDataHash`. Used as a wrapped for try / catch case.
    /// @param _encodingVersion The version of the encoding.
    /// @param _prevMsgSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @return txDataHash The resulting encoded transaction data hash.
    function encodeTxDataHash(
        bytes1 _encodingVersion,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external view returns (bytes32 txDataHash) {
        return _encodeTxDataHash(_encodingVersion, _prevMsgSender, _assetId, _transferData);
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The ZK chain id to which deposit was initiated.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _assetData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver. Might include extra information.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function bridgeRecoverFailedTransfer(
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes memory _assetData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) public nonReentrant whenNotPaused {
        {
            bool proofValid = BRIDGE_HUB.proveL1ToL2TransactionStatus({
                _chainId: _chainId,
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _status: TxStatus.Failure
            });
            if (!proofValid) {
                revert InvalidProof();
            }
        }

        if (_isEraLegacyDeposit(_chainId, _l2BatchNumber, _l2TxNumberInBatch)) {
            revert LegacycFD();
        }
        {
            bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
            // Determine if the given dataHash matches the calculated legacy transaction hash.
            bool isLegacyTxDataHash = _isLegacyTxDataHash(_depositSender, _assetId, _assetData, dataHash);
            // If the dataHash matches the legacy transaction hash, skip the next step.
            // Otherwise, perform the check using the new transaction data hash encoding.
            if (!isLegacyTxDataHash) {
                bytes32 txDataHash = _encodeTxDataHash(NEW_ENCODING_VERSION, _depositSender, _assetId, _assetData);
                if (dataHash != txDataHash) {
                    revert DepositDoesNotExist();
                }
            }
        }
        delete depositHappened[_chainId][_l2TxHash];

        IL1AssetHandler(assetHandlerAddress[_assetId]).bridgeRecoverFailedTransfer(
            _chainId,
            _assetId,
            _depositSender,
            _assetData
        );

        emit ClaimedFailedDepositAssetRouter(_chainId, _depositSender, _assetId, _assetData);
    }

    /// @dev Receives and parses (name, symbol, decimals) from the token contract
    function getERC20Getters(address _token) public view returns (bytes memory) {
        return BridgeHelper.getERC20Getters(_token, ETH_TOKEN_ADDRESS);
    }

    /// @dev send the burn message to the asset
    /// @notice Forwards the burn request for specific asset to respective asset handler
    /// @param _chainId The chain ID of the ZK chain to which deposit.
    /// @param _l2Value The L2 `msg.value` from the L1 -> L2 deposit transaction.
    /// @param _assetId The deposited asset ID.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _transferData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _passValue Boolean indicating whether to pass msg.value in the call.
    /// @return bridgeMintCalldata The calldata used by remote asset handler to mint tokens for recipient.
    function _burn(
        uint256 _chainId,
        uint256 _l2Value,
        bytes32 _assetId,
        address _prevMsgSender,
        bytes memory _transferData,
        bool _passValue
    ) internal returns (bytes memory bridgeMintCalldata) {
        address l1AssetHandler = assetHandlerAddress[_assetId];
        if (l1AssetHandler == address(0)) {
            revert AssetHandlerDoesNotExistForAssetId();
        }

        uint256 msgValue = _passValue ? msg.value : 0;
        bridgeMintCalldata = IL1AssetHandler(l1AssetHandler).bridgeBurn{value: msgValue}({
            _chainId: _chainId,
            _l2Value: _l2Value,
            _assetId: _assetId,
            _prevMsgSender: _prevMsgSender,
            _data: _transferData
        });
    }

    struct MessageParams {
        uint256 l2BatchNumber;
        uint256 l2MessageIndex;
        uint16 l2TxNumberInBatch;
    }

    /// @notice Internal function that handles the logic for finalizing withdrawals, supporting both the current bridge system and the legacy ERC20 bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent.
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message.
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
    /// @return l1Receiver The address to receive bridged assets.
    /// @return assetId The bridged asset ID.
    /// @return amount The amount of asset bridged.
    function _finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal nonReentrant whenNotPaused returns (address l1Receiver, bytes32 assetId, uint256 amount) {
        if (isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex]) {
            revert WithdrawalAlreadyFinalized();
        }
        isWithdrawalFinalized[_chainId][_l2BatchNumber][_l2MessageIndex] = true;

        // Handling special case for withdrawal from ZKsync Era initiated before Shared Bridge.
        if (_isEraLegacyEthWithdrawal(_chainId, _l2BatchNumber)) {
            revert LegacyEthWithdrawal();
        }
        if (_isEraLegacyTokenWithdrawal(_chainId, _l2BatchNumber)) {
            revert LegacyTokenWithdrawal();
        }

        bytes memory transferData;
        {
            MessageParams memory messageParams = MessageParams({
                l2BatchNumber: _l2BatchNumber,
                l2MessageIndex: _l2MessageIndex,
                l2TxNumberInBatch: _l2TxNumberInBatch
            });
            (assetId, transferData) = _checkWithdrawal(_chainId, messageParams, _message, _merkleProof);
        }
        address l1AssetHandler = assetHandlerAddress[assetId];
        IL1AssetHandler(l1AssetHandler).bridgeMint(_chainId, assetId, transferData);
        if (l1AssetHandler == address(nativeTokenVault)) {
            (amount, l1Receiver) = abi.decode(transferData, (uint256, address));
        }
        emit WithdrawalFinalizedAssetRouter(_chainId, assetId, transferData);
    }

    /// @notice Decodes the transfer input for legacy data and transfers allowance to NTV
    /// @dev Is not applicable for custom asset handlers
    /// @param _data encoded transfer data (address _l1Token, uint256 _depositAmount, address _l2Receiver)
    /// @param _prevMsgSender address of the deposit initiator
    function _handleLegacyData(bytes calldata _data, address _prevMsgSender) internal returns (bytes32, bytes memory) {
        (address _l1Token, uint256 _depositAmount, address _l2Receiver) = abi.decode(
            _data,
            (address, uint256, address)
        );
        bytes32 assetId = _ensureTokenRegisteredWithNTV(_l1Token);
        _transferAllowanceToNTV(assetId, _depositAmount, _prevMsgSender);
        return (assetId, abi.encode(_depositAmount, _l2Receiver));
    }

    function _ensureTokenRegisteredWithNTV(address _l1Token) internal returns (bytes32 assetId) {
        assetId = DataEncoding.encodeNTVAssetId(block.chainid, _l1Token);
        if (nativeTokenVault.tokenAddress(assetId) == address(0)) {
            nativeTokenVault.registerToken(_l1Token);
        }
    }

    /// @notice Transfers allowance to Native Token Vault, if the asset is registered with it. Does nothing for ETH or non-registered tokens.
    /// @dev assetId is not the padded address, but the correct encoded id (NTV stores respective format for IDs)
    function _transferAllowanceToNTV(bytes32 _assetId, uint256 _amount, address _prevMsgSender) internal {
        address l1TokenAddress = nativeTokenVault.tokenAddress(_assetId);
        if (l1TokenAddress == address(0) || l1TokenAddress == ETH_TOKEN_ADDRESS) {
            return;
        }
        IERC20 l1Token = IERC20(l1TokenAddress);

        // Do the transfer if allowance to Shared bridge is bigger than amount
        // And if there is not enough allowance for the NTV
        if (
            l1Token.allowance(_prevMsgSender, address(this)) >= _amount &&
            l1Token.allowance(_prevMsgSender, address(nativeTokenVault)) < _amount
        ) {
            // slither-disable-next-line arbitrary-send-erc20
            l1Token.safeTransferFrom(_prevMsgSender, address(this), _amount);
            l1Token.forceApprove(address(nativeTokenVault), _amount);
        }
    }

    /// @dev The request data that is passed to the bridgehub
    function _requestToBridge(
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _bridgeMintCalldata,
        bytes32 _txDataHash
    ) internal view returns (L2TransactionRequestTwoBridgesInner memory request) {
        // Request the finalization of the deposit on the L2 side
        bytes memory l2TxCalldata = _getDepositL2Calldata(_prevMsgSender, _assetId, _bridgeMintCalldata);

        request = L2TransactionRequestTwoBridgesInner({
            magicValue: TWO_BRIDGES_MAGIC_VALUE,
            l2Contract: L2_ASSET_ROUTER_ADDR,
            l2Calldata: l2TxCalldata,
            factoryDeps: new bytes[](0),
            txDataHash: _txDataHash
        });
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 bridge contract
    function _getDepositL2Calldata(
        address _l1Sender,
        bytes32 _assetId,
        bytes memory _assetData
    ) internal view returns (bytes memory) {
        // First branch covers the case when asset is not registered with NTV (custom asset handler)
        // Second branch handles tokens registered with NTV and uses legacy calldata encoding
        if (nativeTokenVault.tokenAddress(_assetId) == address(0)) {
            return abi.encodeCall(IL2Bridge.finalizeDeposit, (_assetId, _assetData));
        } else {
            // slither-disable-next-line unused-return
            (, address _l2Receiver, address _parsedL1Token, uint256 _amount, bytes memory _gettersData) = DataEncoding
                .decodeBridgeMintData(_assetData);
            return
                abi.encodeCall(
                    IL2BridgeLegacy.finalizeDeposit,
                    (_l1Sender, _l2Receiver, _parsedL1Token, _amount, _gettersData)
                );
        }
    }

    /// @dev Determines if an eth withdrawal was initiated on ZKsync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on ZKsync Era before diamond proxy upgrade.
    function _isEraLegacyEthWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        if ((_chainId == ERA_CHAIN_ID) && eraPostDiamondUpgradeFirstBatch == 0) {
            revert SharedBridgeValueNotSet(SharedBridgeKey.PostUpgradeFirstBatch);
        }
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostDiamondUpgradeFirstBatch);
    }

    /// @dev Determines if a token withdrawal was initiated on ZKsync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on ZKsync Era before Legacy Bridge upgrade.
    function _isEraLegacyTokenWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        if ((_chainId == ERA_CHAIN_ID) && eraPostLegacyBridgeUpgradeFirstBatch == 0) {
            revert SharedBridgeValueNotSet(SharedBridgeKey.LegacyBridgeFirstBatch);
        }
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostLegacyBridgeUpgradeFirstBatch);
    }

    /// @dev Determines if the provided data for a failed deposit corresponds to a legacy failed deposit.
    /// @param _prevMsgSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @param _expectedTxDataHash The nullifier data hash stored for the failed deposit.
    /// @return isLegacyTxDataHash True if the transaction is legacy, false otherwise.
    function _isLegacyTxDataHash(
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _transferData,
        bytes32 _expectedTxDataHash
    ) internal view returns (bool isLegacyTxDataHash) {
        try this.encodeTxDataHash(LEGACY_ENCODING_VERSION, _prevMsgSender, _assetId, _transferData) returns (
            bytes32 txDataHash
        ) {
            return txDataHash == _expectedTxDataHash;
        } catch {
            return false;
        }
    }

    /// @dev Encodes the transaction data hash using either the latest encoding standard or the legacy standard.
    /// @param _encodingVersion EncodingVersion.
    /// @param _prevMsgSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @return txDataHash The resulting encoded transaction data hash.
    function _encodeTxDataHash(
        bytes1 _encodingVersion,
        address _prevMsgSender,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal view returns (bytes32 txDataHash) {
        if (_encodingVersion == LEGACY_ENCODING_VERSION) {
            (uint256 depositAmount, ) = abi.decode(_transferData, (uint256, address));
            txDataHash = keccak256(abi.encode(_prevMsgSender, nativeTokenVault.tokenAddress(_assetId), depositAmount));
        } else {
            // Similarly to calldata, the txDataHash is collision-resistant.
            // In the legacy data hash, the first encoded variable was the address, which is padded with zeros during `abi.encode`.
            txDataHash = keccak256(bytes.concat(_encodingVersion, abi.encode(_prevMsgSender, _assetId, _transferData)));
        }
    }

    /// @dev Determines if a deposit was initiated on ZKsync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the deposit where it was processed.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the deposit was processed.
    /// @return Whether deposit was initiated on ZKsync Era before Shared Bridge upgrade.
    function _isEraLegacyDeposit(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2TxNumberInBatch
    ) internal view returns (bool) {
        if ((_chainId == ERA_CHAIN_ID) && (eraLegacyBridgeLastDepositBatch == 0)) {
            revert SharedBridgeValueNotSet(SharedBridgeKey.LegacyBridgeLastDepositBatch);
        }
        return
            (_chainId == ERA_CHAIN_ID) &&
            (_l2BatchNumber < eraLegacyBridgeLastDepositBatch ||
                (_l2TxNumberInBatch <= eraLegacyBridgeLastDepositTxNumber &&
                    _l2BatchNumber == eraLegacyBridgeLastDepositBatch));
    }

    /// @notice Verifies the validity of a withdrawal message from L2 and returns withdrawal details.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _messageParams The message params, which include batch number, message index, and L2 tx number in batch.
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message.
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdawal.
    function _checkWithdrawal(
        uint256 _chainId,
        MessageParams memory _messageParams,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (bytes32 assetId, bytes memory transferData) {
        (assetId, transferData) = _parseL2WithdrawalMessage(_chainId, _message);
        L2Message memory l2ToL1Message;
        {
            bool baseTokenWithdrawal = (assetId == BRIDGE_HUB.baseTokenAssetId(_chainId));
            address l2Sender = baseTokenWithdrawal ? L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR : L2_ASSET_ROUTER_ADDR;

            l2ToL1Message = L2Message({
                txNumberInBatch: _messageParams.l2TxNumberInBatch,
                sender: l2Sender,
                data: _message
            });
        }

        bool success = BRIDGE_HUB.proveL2MessageInclusion({
            _chainId: _chainId,
            _batchNumber: _messageParams.l2BatchNumber,
            _index: _messageParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _merkleProof
        });
        // withdrawal wrong proof
        if (!success) {
            revert InvalidProof();
        }
    }

    /// @notice Parses the withdrawal message and returns withdrawal details.
    /// @dev Currently, 3 different encoding versions are supported: legacy mailbox withdrawal, ERC20 bridge withdrawal,
    /// @dev and the latest version supported by shared bridge. Selectors are used for versioning.
    /// @param _chainId The ZK chain ID.
    /// @param _l2ToL1message The encoded L2 -> L1 message.
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdawal.
    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _l2ToL1message
    ) internal view returns (bytes32 assetId, bytes memory transferData) {
        // We check that the message is long enough to read the data.
        // Please note that there are three versions of the message:
        // 1. The message that is sent by `withdraw(address _l1Receiver)` or `withdrawWithMessage`. In the second case, this function ignores the extra data
        // It should be equal to the length of the bytes4 function signature + address l1Receiver + uint256 amount = 4 + 20 + 32 = 56 (bytes).
        // 2. The legacy `getL1WithdrawMessage`, the length of the data is known.
        // 3. The message that is encoded by `getL1WithdrawMessage(bytes32 _assetId, bytes memory _bridgeMintData)`
        // No length is assumed. The assetId is decoded and the mintData is passed to respective assetHandler

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            uint256 amount;
            address l1Receiver;

            // The data is expected to be at least 56 bytes long.
            if (_l2ToL1message.length < 56) {
                revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
            }
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            // slither-disable-next-line unused-return
            (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            assetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
            transferData = abi.encode(amount, l1Receiver);
        } else if (bytes4(functionSignature) == IL1ERC20Bridge.finalizeWithdrawal.selector) {
            address l1Token;
            uint256 amount;
            address l1Receiver;
            // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.
            // This message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            if (_l2ToL1message.length != 76) {
                revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
            }
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            // slither-disable-next-line unused-return
            (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);

            assetId = DataEncoding.encodeNTVAssetId(block.chainid, l1Token);
            transferData = abi.encode(amount, l1Receiver);
        } else if (bytes4(functionSignature) == this.finalizeWithdrawal.selector) {
            // The data is expected to be at least 36 bytes long to contain assetId.
            if (_l2ToL1message.length < 36) {
                revert WrongMsgLength();
            }
            (assetId, offset) = UnsafeBytes.readBytes32(_l2ToL1message, offset);
            transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
        } else {
            revert InvalidSelector(bytes4(functionSignature));
        }
    }

    /*//////////////////////////////////////////////////////////////
            SHARED BRIDGE TOKEN BRIDGING LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @dev Cannot be used to claim deposits made with new encoding.
    /// @param _chainId The ZK chain id to which deposit was initiated.
    /// @param _depositSender The address of the deposit initiator.
    /// @param _l1Asset The address of the deposited L1 ERC20 token.
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Asset,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external override {
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, _l1Asset);
        // For legacy deposits, the l2 receiver is not required to check tx data hash
        bytes memory transferData = abi.encode(_amount, address(0));
        bridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _depositSender: _depositSender,
            _assetId: assetId,
            _assetData: transferData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });
    }

    /*//////////////////////////////////////////////////////////////
                    ERA ERC20 LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted.
    /// @dev If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
    /// newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
    /// @param _prevMsgSender The `msg.sender` address from the external call that initiated current one.
    /// @param _l2Receiver The account address that should receive funds on L2.
    /// @param _l1Token The L1 token address which is deposited.
    /// @param _amount The total amount of tokens to be bridged.
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction.
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction.
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @dev If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
    /// Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses
    /// out of control.
    /// - If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will
    /// be sent to the `msg.sender` address.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be
    /// sent to the aliased `msg.sender` address.
    /// @dev The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds
    /// are controllable through the Mailbox, since the Mailbox applies address aliasing to the from address for the
    /// L2 tx if the L1 msg.sender is a contract. Without address aliasing for L1 contracts as refund recipients they
    /// would not be able to make proper L2 tx requests through the Mailbox to use or withdraw the funds from L2, and
    /// the funds would be lost.
    /// @return txHash The L2 transaction hash of deposit finalization.
    function depositLegacyErc20Bridge(
        address _prevMsgSender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable override onlyLegacyBridge nonReentrant whenNotPaused returns (bytes32 txHash) {
        if (_l1Token == L1_WETH_TOKEN) {
            revert TokenNotSupported(L1_WETH_TOKEN);
        }

        bytes32 _assetId;
        bytes memory bridgeMintCalldata;

        {
            // Inner call to encode data to decrease local var numbers
            _assetId = _ensureTokenRegisteredWithNTV(_l1Token);
            IERC20(_l1Token).forceApprove(address(nativeTokenVault), _amount);
        }

        {
            bridgeMintCalldata = _burn({
                _chainId: ERA_CHAIN_ID,
                _l2Value: 0,
                _assetId: _assetId,
                _prevMsgSender: _prevMsgSender,
                _transferData: abi.encode(_amount, _l2Receiver),
                _passValue: false
            });
        }

        {
            bytes memory l2TxCalldata = _getDepositL2Calldata(_prevMsgSender, _assetId, bridgeMintCalldata);

            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = AddressAliasHelper.actualRefundRecipient(_refundRecipient, _prevMsgSender);

            L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
                chainId: ERA_CHAIN_ID,
                l2Contract: L2_ASSET_ROUTER_ADDR,
                mintValue: msg.value, // l2 gas + l2 msg.Value the bridgehub will withdraw the mintValue from the shared bridge (base token bridge) for gas
                l2Value: 0, // L2 msg.value, this contract doesn't support base token deposits or wrapping functionality, for direct deposits use bridgehub
                l2Calldata: l2TxCalldata,
                l2GasLimit: _l2TxGasLimit,
                l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
                factoryDeps: new bytes[](0),
                refundRecipient: refundRecipient
            });
            txHash = BRIDGE_HUB.requestL2TransactionDirect{value: msg.value}(request);
        }

        // Save the deposited amount to claim funds on L1 if the deposit failed on L2
        depositHappened[ERA_CHAIN_ID][txHash] = keccak256(abi.encode(_prevMsgSender, _l1Token, _amount));

        emit LegacyDepositInitiated({
            chainId: ERA_CHAIN_ID,
            l2DepositTxHash: txHash,
            from: _prevMsgSender,
            to: _l2Receiver,
            l1Asset: _l1Token,
            amount: _amount
        });
    }

    /// @notice Finalizes the withdrawal for transactions initiated via the legacy ERC20 bridge.
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent.
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message.
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization.
    ///
    /// @return l1Receiver The address on L1 that will receive the withdrawn funds.
    /// @return l1Asset The address of the L1 token being withdrawn.
    /// @return amount The amount of the token being withdrawn.
    function finalizeWithdrawalLegacyErc20Bridge(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override onlyLegacyBridge returns (address l1Receiver, address l1Asset, uint256 amount) {
        bytes32 assetId;
        (l1Receiver, assetId, amount) = _finalizeWithdrawal({
            _chainId: ERA_CHAIN_ID,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
        l1Asset = nativeTokenVault.tokenAddress(assetId);
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
}
