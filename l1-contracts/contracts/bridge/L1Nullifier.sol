// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {NEW_ENCODING_VERSION, LEGACY_ENCODING_VERSION} from "./asset-router/IAssetRouterBase.sol";
import {IL1NativeTokenVault} from "./ntv/IL1NativeTokenVault.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL1AssetRouter} from "./asset-router/IL1AssetRouter.sol";
import {IAssetRouterBase} from "./asset-router/IAssetRouterBase.sol";

import {IL1Nullifier, FinalizeL1DepositParams} from "./interfaces/IL1Nullifier.sol";

import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";
import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_ASSET_ROUTER_ADDR} from "../common/L2ContractAddresses.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {LegacyMethodForNonL1Token, LegacyBridgeNotSet, Unauthorized, SharedBridgeKey, DepositExists, AddressAlreadySet, InvalidProof, DepositDoesNotExist, SharedBridgeValueNotSet, WithdrawalAlreadyFinalized, L2WithdrawalMessageWrongLength, InvalidSelector, SharedBridgeValueNotSet, ZeroAddress, TokenNotLegacy} from "../common/L1ContractErrors.sol";
import {WrongL2Sender, NativeTokenVaultAlreadySet, EthTransferFailed, WrongMsgLength} from "./L1BridgeContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1Nullifier is IL1Nullifier, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IBridgehub public immutable override BRIDGE_HUB;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @dev The address of ZKsync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

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

    /// @dev The tx number in the _eraLegacyBridgeLastDepositBatch that comes *right after* the last deposit tx initiated by the legacy bridge.
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
    // keccak256(abi.encode(_originalCaller, assetId, transferData)) for new transfers
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
    mapping(uint256 chainId => bool enabled) private __DEPRECATED_hyperbridgingEnabled;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chain.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(address l1Token => uint256 balance)) public __DEPRECATED_chainBalance;

    /// @dev Admin has the ability to register new chains within the shared bridge.
    address public __DEPRECATED_admin;

    /// @dev The pending admin, i.e. the candidate to the admin role.
    address public __DEPRECATED_pendingAdmin;

    /// @dev Address of L1 asset router.
    IL1AssetRouter public l1AssetRouter;

    /// @dev Address of native token vault.
    IL1NativeTokenVault public l1NativeTokenVault;

    /// @notice Checks that the message sender is the asset router..
    modifier onlyAssetRouter() {
        if (msg.sender != address(l1AssetRouter)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks that the message sender is the native token vault.
    modifier onlyL1NTV() {
        if (msg.sender != address(l1NativeTokenVault)) {
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
    constructor(IBridgehub _bridgehub, uint256 _eraChainId, address _eraDiamondProxy) reentrancyGuardInitializer {
        _disableInitializers();
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
    function transferTokenToNTV(address _token) external onlyL1NTV {
        address ntvAddress = address(l1NativeTokenVault);
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
    function nullifyChainBalanceByNTV(uint256 _chainId, address _token) external onlyL1NTV {
        __DEPRECATED_chainBalance[_chainId][_token] = 0;
    }

    /// @notice Legacy function used for migration, do not use!
    /// @param _chainId The chain id on which the bridge is deployed.
    // slither-disable-next-line uninitialized-state-variables
    function l2BridgeAddress(uint256 _chainId) external view returns (address) {
        // slither-disable-next-line uninitialized-state-variables
        return __DEPRECATED_l2BridgeAddress[_chainId];
    }

    /// @notice Legacy function used for migration, do not use!
    /// @param _chainId The chain id we want to get the balance for.
    /// @param _token The address of the token.
    // slither-disable-next-line uninitialized-state-variables
    function chainBalance(uint256 _chainId, address _token) external view returns (uint256) {
        // slither-disable-next-line uninitialized-state-variables
        return __DEPRECATED_chainBalance[_chainId][_token];
    }

    /// @notice Sets the L1ERC20Bridge contract address.
    /// @dev Should be called only once by the owner.
    /// @param _legacyBridge The address of the legacy bridge.
    function setL1Erc20Bridge(IL1ERC20Bridge _legacyBridge) external onlyOwner {
        if (address(legacyBridge) != address(0)) {
            revert AddressAlreadySet(address(legacyBridge));
        }
        if (address(_legacyBridge) == address(0)) {
            revert ZeroAddress();
        }
        legacyBridge = _legacyBridge;
    }

    /// @notice Sets the nativeTokenVault contract address.
    /// @dev Should be called only once by the owner.
    /// @param _l1NativeTokenVault The address of the native token vault.
    function setL1NativeTokenVault(IL1NativeTokenVault _l1NativeTokenVault) external onlyOwner {
        if (address(l1NativeTokenVault) != address(0)) {
            revert NativeTokenVaultAlreadySet();
        }
        if (address(_l1NativeTokenVault) == address(0)) {
            revert ZeroAddress();
        }
        l1NativeTokenVault = _l1NativeTokenVault;
    }

    /// @notice Sets the L1 asset router contract address.
    /// @dev Should be called only once by the owner.
    /// @param _l1AssetRouter The address of the asset router.
    function setL1AssetRouter(address _l1AssetRouter) external onlyOwner {
        if (address(l1AssetRouter) != address(0)) {
            revert AddressAlreadySet(address(l1AssetRouter));
        }
        if (_l1AssetRouter == address(0)) {
            revert ZeroAddress();
        }
        l1AssetRouter = IL1AssetRouter(_l1AssetRouter);
    }

    /// @notice Confirms the acceptance of a transaction by the Mailbox, as part of the L2 transaction process within Bridgehub.
    /// This function is utilized by `requestL2TransactionTwoBridges` to validate the execution of a transaction.
    /// @param _chainId The chain ID of the ZK chain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
    function bridgehubConfirmL2TransactionForwarded(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyAssetRouter whenNotPaused {
        if (depositHappened[_chainId][_txHash] != 0x00) {
            revert DepositExists();
        }
        depositHappened[_chainId][_txHash] = _txDataHash;
        emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
    }

    /// @dev Calls the library `encodeTxDataHash`. Used as a wrapped for try / catch case.
    /// @dev Encodes the transaction data hash using either the latest encoding standard or the legacy standard.
    /// @param _encodingVersion EncodingVersion.
    /// @param _originalCaller The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @return txDataHash The resulting encoded transaction data hash.
    function encodeTxDataHash(
        bytes1 _encodingVersion,
        address _originalCaller,
        bytes32 _assetId,
        bytes calldata _transferData
    ) external view returns (bytes32 txDataHash) {
        txDataHash = DataEncoding.encodeTxDataHash({
            _encodingVersion: _encodingVersion,
            _originalCaller: _originalCaller,
            _assetId: _assetId,
            _nativeTokenVault: address(l1NativeTokenVault),
            _transferData: _transferData
        });
    }

    /// @inheritdoc IL1Nullifier
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
    ) public nonReentrant {
        _verifyAndClearFailedTransfer({
            _checkedInLegacyBridge: false,
            _chainId: _chainId,
            _depositSender: _depositSender,
            _assetId: _assetId,
            _assetData: _assetData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });

        l1AssetRouter.bridgeRecoverFailedTransfer(_chainId, _depositSender, _assetId, _assetData);
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _chainId The ZK chain id to which deposit was initiated.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _assetData The encoded data, which is used by the asset handler to determine L2 recipient and amount. Might include extra information.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    /// @dev Processes claims of failed deposit, whether they originated from the legacy bridge or the current system.
    function _verifyAndClearFailedTransfer(
        bool _checkedInLegacyBridge,
        uint256 _chainId,
        address _depositSender,
        bytes32 _assetId,
        bytes memory _assetData,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) internal whenNotPaused {
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

        bool notCheckedInLegacyBridgeOrWeCanCheckDeposit;
        {
            // Deposits that happened before the upgrade cannot be checked here, they have to be claimed and checked in the legacyBridge
            bool weCanCheckDepositHere = !_isPreSharedBridgeDepositOnEra(_chainId, _l2BatchNumber, _l2TxNumberInBatch);
            // Double claims are not possible, as depositHappened is checked here for all except legacy deposits (which have to happen through the legacy bridge)
            // Funds claimed before the update will still be recorded in the legacy bridge
            // Note we double check NEW deposits if they are called from the legacy bridge
            notCheckedInLegacyBridgeOrWeCanCheckDeposit = (!_checkedInLegacyBridge) || weCanCheckDepositHere;
        }

        if (notCheckedInLegacyBridgeOrWeCanCheckDeposit) {
            bytes32 dataHash = depositHappened[_chainId][_l2TxHash];
            // Determine if the given dataHash matches the calculated legacy transaction hash.
            bool isLegacyTxDataHash = _isLegacyTxDataHash(_depositSender, _assetId, _assetData, dataHash);
            // If the dataHash matches the legacy transaction hash, skip the next step.
            // Otherwise, perform the check using the new transaction data hash encoding.
            if (!isLegacyTxDataHash) {
                bytes32 txDataHash = DataEncoding.encodeTxDataHash({
                    _encodingVersion: NEW_ENCODING_VERSION,
                    _originalCaller: _depositSender,
                    _assetId: _assetId,
                    _nativeTokenVault: address(l1NativeTokenVault),
                    _transferData: _assetData
                });
                if (dataHash != txDataHash) {
                    revert DepositDoesNotExist();
                }
            }
        }
        delete depositHappened[_chainId][_l2TxHash];
    }

    /// @notice Finalize the withdrawal and release funds.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    /// @dev We have both the legacy finalizeWithdrawal and the new finalizeDeposit functions,
    /// finalizeDeposit uses the new format. On the L2 we have finalizeDeposit with new and old formats both.
    function finalizeDeposit(FinalizeL1DepositParams memory _finalizeWithdrawalParams) public {
        _finalizeDeposit(_finalizeWithdrawalParams);
    }

    /// @notice Internal function that handles the logic for finalizing withdrawals, supporting both the current bridge system and the legacy ERC20 bridge.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    function _finalizeDeposit(
        FinalizeL1DepositParams memory _finalizeWithdrawalParams
    ) internal nonReentrant whenNotPaused {
        uint256 chainId = _finalizeWithdrawalParams.chainId;
        uint256 l2BatchNumber = _finalizeWithdrawalParams.l2BatchNumber;
        uint256 l2MessageIndex = _finalizeWithdrawalParams.l2MessageIndex;
        if (isWithdrawalFinalized[chainId][l2BatchNumber][l2MessageIndex]) {
            revert WithdrawalAlreadyFinalized();
        }
        isWithdrawalFinalized[chainId][l2BatchNumber][l2MessageIndex] = true;

        (bytes32 assetId, bytes memory transferData) = _verifyWithdrawal(_finalizeWithdrawalParams);

        // Handling special case for withdrawal from ZKsync Era initiated before Shared Bridge.
        if (_isPreSharedBridgeEraEthWithdrawal(chainId, l2BatchNumber)) {
            // Checks that the withdrawal wasn't finalized already.
            bool alreadyFinalized = IGetters(ERA_DIAMOND_PROXY).isEthWithdrawalFinalized(l2BatchNumber, l2MessageIndex);
            if (alreadyFinalized) {
                revert WithdrawalAlreadyFinalized();
            }
        }
        if (_isPreSharedBridgeEraTokenWithdrawal(chainId, l2BatchNumber)) {
            if (legacyBridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex)) {
                revert WithdrawalAlreadyFinalized();
            }
        }

        l1AssetRouter.finalizeDeposit(chainId, assetId, transferData);
    }

    /// @dev Determines if an eth withdrawal was initiated on ZKsync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on ZKsync Era before diamond proxy upgrade.
    function _isPreSharedBridgeEraEthWithdrawal(uint256 _chainId, uint256 _l2BatchNumber) internal view returns (bool) {
        if ((_chainId == ERA_CHAIN_ID) && eraPostDiamondUpgradeFirstBatch == 0) {
            revert SharedBridgeValueNotSet(SharedBridgeKey.PostUpgradeFirstBatch);
        }
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostDiamondUpgradeFirstBatch);
    }

    /// @dev Determines if a token withdrawal was initiated on ZKsync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the withdrawal.
    /// @return Whether withdrawal was initiated on ZKsync Era before Legacy Bridge upgrade.
    function _isPreSharedBridgeEraTokenWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber
    ) internal view returns (bool) {
        if ((_chainId == ERA_CHAIN_ID) && eraPostLegacyBridgeUpgradeFirstBatch == 0) {
            revert SharedBridgeValueNotSet(SharedBridgeKey.LegacyBridgeFirstBatch);
        }
        return (_chainId == ERA_CHAIN_ID) && (_l2BatchNumber < eraPostLegacyBridgeUpgradeFirstBatch);
    }

    /// @dev Determines if the provided data for a failed deposit corresponds to a legacy failed deposit.
    /// @param _depositSender The address of the entity that initiated the deposit.
    /// @param _assetId The unique identifier of the deposited L1 token.
    /// @param _transferData The encoded transfer data, which includes both the deposit amount and the address of the L2 receiver.
    /// @param _expectedTxDataHash The nullifier data hash stored for the failed deposit.
    /// @return isLegacyTxDataHash True if the transaction is legacy, false otherwise.
    function _isLegacyTxDataHash(
        address _depositSender,
        bytes32 _assetId,
        bytes memory _transferData,
        bytes32 _expectedTxDataHash
    ) internal view returns (bool isLegacyTxDataHash) {
        try this.encodeTxDataHash(LEGACY_ENCODING_VERSION, _depositSender, _assetId, _transferData) returns (
            bytes32 txDataHash
        ) {
            return txDataHash == _expectedTxDataHash;
        } catch {
            return false;
        }
    }

    /// @dev Determines if a deposit was initiated on ZKsync Era before the upgrade to the Shared Bridge.
    /// @param _chainId The chain ID of the transaction to check.
    /// @param _l2BatchNumber The L2 batch number for the deposit where it was processed.
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the deposit was processed.
    /// @return Whether deposit was initiated on ZKsync Era before Shared Bridge upgrade.
    function _isPreSharedBridgeDepositOnEra(
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
                (_l2TxNumberInBatch < eraLegacyBridgeLastDepositTxNumber &&
                    _l2BatchNumber == eraLegacyBridgeLastDepositBatch));
    }

    /// @notice Verifies the validity of a withdrawal message from L2 and returns withdrawal details.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdawal.
    function _verifyWithdrawal(
        FinalizeL1DepositParams memory _finalizeWithdrawalParams
    ) internal returns (bytes32 assetId, bytes memory transferData) {
        (assetId, transferData) = _parseL2WithdrawalMessage(
            _finalizeWithdrawalParams.chainId,
            _finalizeWithdrawalParams.message
        );
        L2Message memory l2ToL1Message;
        {
            address l2Sender = _finalizeWithdrawalParams.l2Sender;
            bool baseTokenWithdrawal = (assetId == BRIDGE_HUB.baseTokenAssetId(_finalizeWithdrawalParams.chainId));

            bool isL2SenderCorrect = l2Sender == L2_ASSET_ROUTER_ADDR ||
                l2Sender == L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR ||
                l2Sender == __DEPRECATED_l2BridgeAddress[_finalizeWithdrawalParams.chainId];
            if (!isL2SenderCorrect) {
                revert WrongL2Sender(l2Sender);
            }

            l2ToL1Message = L2Message({
                txNumberInBatch: _finalizeWithdrawalParams.l2TxNumberInBatch,
                sender: baseTokenWithdrawal ? L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR : l2Sender,
                data: _finalizeWithdrawalParams.message
            });
        }

        bool success = BRIDGE_HUB.proveL2MessageInclusion({
            _chainId: _finalizeWithdrawalParams.chainId,
            _batchNumber: _finalizeWithdrawalParams.l2BatchNumber,
            _index: _finalizeWithdrawalParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _finalizeWithdrawalParams.merkleProof
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
    ) internal returns (bytes32 assetId, bytes memory transferData) {
        // Please note that there are three versions of the message:
        // 1. The message that is sent from `L2BaseToken` to withdraw base token.
        // 2. The message that is sent from L2 Legacy Shared Bridge to withdraw ERC20 tokens or base token.
        // 3. The message that is sent from L2 Asset Router to withdraw ERC20 tokens or base token.

        uint256 amount;
        address l1Receiver;

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_l2ToL1message, 0);
        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            // The data is expected to be at least 56 bytes long.
            if (_l2ToL1message.length < 56) {
                revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
            }
            // this message is a base token withdrawal
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            // slither-disable-next-line unused-return
            (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);
            assetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
            transferData = DataEncoding.encodeBridgeMintData({
                _originalCaller: address(0),
                _remoteReceiver: l1Receiver,
                // Note, that `assetId` could belong to a token native to an L2, and so
                // the logic for determining the correct origin token address will be complex.
                // It is expected that this value won't be used in the NativeTokenVault and so providing
                // any value is acceptable here.
                _originToken: address(0),
                _amount: amount,
                _erc20Metadata: new bytes(0)
            });
        } else if (bytes4(functionSignature) == IL1ERC20Bridge.finalizeWithdrawal.selector) {
            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            if (_l2ToL1message.length != 76) {
                revert L2WithdrawalMessageWrongLength(_l2ToL1message.length);
            }
            (l1Receiver, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            // We use the IL1ERC20Bridge for backward compatibility with old withdrawals.
            address l1Token;
            (l1Token, offset) = UnsafeBytes.readAddress(_l2ToL1message, offset);
            // slither-disable-next-line unused-return
            (amount, ) = UnsafeBytes.readUint256(_l2ToL1message, offset);

            assetId = l1NativeTokenVault.ensureTokenIsRegistered(l1Token);
            bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(block.chainid, l1Token);
            // This method is only expected to use L1-based tokens.
            if (assetId != expectedAssetId) {
                revert TokenNotLegacy();
            }
            transferData = DataEncoding.encodeBridgeMintData({
                _originalCaller: address(0),
                _remoteReceiver: l1Receiver,
                _originToken: l1Token,
                _amount: amount,
                _erc20Metadata: new bytes(0)
            });
        } else if (bytes4(functionSignature) == IAssetRouterBase.finalizeDeposit.selector) {
            // The data is expected to be at least 68 bytes long to contain assetId.
            if (_l2ToL1message.length < 68) {
                revert WrongMsgLength(68, _l2ToL1message.length);
            }
            // slither-disable-next-line unused-return
            (, offset) = UnsafeBytes.readUint256(_l2ToL1message, offset); // originChainId, not used for L2->L1 txs
            (assetId, offset) = UnsafeBytes.readBytes32(_l2ToL1message, offset);
            transferData = UnsafeBytes.readRemainingBytes(_l2ToL1message, offset);
        } else {
            revert InvalidSelector(bytes4(functionSignature));
        }
    }

    /*//////////////////////////////////////////////////////////////
            SHARED BRIDGE TOKEN BRIDGING LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _depositSender The address of the deposit initiator.
    /// @param _l1Token The address of the deposited L1 ERC20 token.
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external {
        bytes32 assetId = l1NativeTokenVault.assetId(_l1Token);
        bytes32 ntvAssetId = DataEncoding.encodeNTVAssetId(block.chainid, _l1Token);
        if (assetId == bytes32(0)) {
            assetId = ntvAssetId;
        } else if (assetId != ntvAssetId) {
            revert LegacyMethodForNonL1Token();
        }

        // For legacy deposits, the l2 receiver is not required to check tx data hash
        // The token address does not have to be provided for this functionality either.
        bytes memory assetData = DataEncoding.encodeBridgeBurnData(_amount, address(0), address(0));

        _verifyAndClearFailedTransfer({
            _checkedInLegacyBridge: false,
            _depositSender: _depositSender,
            _chainId: _chainId,
            _assetId: assetId,
            _assetData: assetData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });

        l1AssetRouter.bridgeRecoverFailedTransfer({
            _chainId: _chainId,
            _depositSender: _depositSender,
            _assetId: assetId,
            _assetData: assetData
        });
    }

    /*//////////////////////////////////////////////////////////////
                    ERA ERC20 LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on ZKsync Era chain.
    /// This function is specifically designed for maintaining backward-compatibility with legacy `claimFailedDeposit`
    /// method in `L1ERC20Bridge`.
    ///
    /// @param _depositSender The address of the deposit initiator.
    /// @param _l1Token The address of the deposited L1 ERC20 token.
    /// @param _amount The amount of the deposit that failed.
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization.
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed.
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message.
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent.
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization.
    function claimFailedDepositLegacyErc20Bridge(
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external override onlyLegacyBridge {
        // For legacy deposits, the l2 receiver is not required to check tx data hash
        // The token address does not have to be provided for this functionality either.
        bytes memory assetData = DataEncoding.encodeBridgeBurnData(_amount, address(0), address(0));

        /// the legacy bridge can only be used with L1 native tokens.
        bytes32 assetId = DataEncoding.encodeNTVAssetId(block.chainid, _l1Token);

        _verifyAndClearFailedTransfer({
            _checkedInLegacyBridge: true,
            _depositSender: _depositSender,
            _chainId: ERA_CHAIN_ID,
            _assetId: assetId,
            _assetData: assetData,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof
        });

        l1AssetRouter.bridgeRecoverFailedTransfer({
            _chainId: ERA_CHAIN_ID,
            _depositSender: _depositSender,
            _assetId: assetId,
            _assetData: assetData
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

    /*//////////////////////////////////////////////////////////////
                            LEGACY INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IL1Nullifier
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override {
        /// @dev We use a deprecated field to support L2->L1 legacy withdrawals, which were started
        /// by the legacy bridge.
        address legacyL2Bridge = __DEPRECATED_l2BridgeAddress[_chainId];
        if (legacyL2Bridge == address(0)) {
            revert LegacyBridgeNotSet();
        }

        FinalizeL1DepositParams memory finalizeWithdrawalParams = FinalizeL1DepositParams({
            chainId: _chainId,
            l2BatchNumber: _l2BatchNumber,
            l2MessageIndex: _l2MessageIndex,
            l2Sender: legacyL2Bridge,
            l2TxNumberInBatch: _l2TxNumberInBatch,
            message: _message,
            merkleProof: _merkleProof
        });
        finalizeDeposit(finalizeWithdrawalParams);
    }
}
