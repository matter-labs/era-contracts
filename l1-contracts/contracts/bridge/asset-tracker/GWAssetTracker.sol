// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BALANCE_CHANGE_VERSION, TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "./IAssetTrackerBase.sol";

import {
    BUNDLE_IDENTIFIER,
    BalanceChange,
    GatewayToL1TokenBalanceMigrationData,
    InteropBundle,
    InteropCall,
    InteropCallExecutedMessage,
    L2Log,
    MigrationConfirmationData,
    TxStatus,
    TokenBridgingData
} from "../../common/Messaging.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BOOTLOADER_ADDRESS,
    L2_BRIDGEHUB,
    L2_CHAIN_ASSET_HANDLER,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_COMPRESSOR_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR,
    L2_MESSAGE_ROOT,
    L2_NATIVE_TOKEN_VAULT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    MAX_BUILT_IN_CONTRACT_ADDR,
    L2_ASSET_ROUTER,
    L2_BRIDGEHUB_ADDR
} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {AssetRouterBase} from "../asset-router/AssetRouterBase.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {
    ChainIdNotRegistered,
    InvalidInteropCalldata,
    InvalidMessage,
    ReconstructionMismatch,
    Unauthorized,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";
import {
    CHAIN_TREE_EMPTY_ENTRY_HASH,
    IMessageRootBase,
    SHARED_ROOT_TREE_EMPTY_HASH
} from "../../core/message-root/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkleMemory} from "../../common/libraries/DynamicIncrementalMerkleMemory.sol";
import {
    L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH,
    L2_TO_L1_LOGS_MERKLE_TREE_DEPTH,
    MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
    MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1
} from "../../common/Config.sol";
import {IBridgehubBase} from "../../core/bridgehub/IBridgehubBase.sol";
import {FullMerkleMemory} from "../../common/libraries/FullMerkleMemory.sol";

import {
    InvalidAssetMigrationNumber,
    InvalidBuiltInContractMessage,
    InvalidCanonicalTxHash,
    InvalidChainMigrationNumber,
    InvalidFunctionSignature,
    InvalidInteropChainId,
    InvalidL2ShardId,
    InsufficientPendingInteropBalance,
    InvalidServiceLog,
    InvalidEmptyMultichainBatchRoot,
    RegisterNewTokenNotAllowed,
    InvalidFeeRecipient,
    SettlementFeePayerNotAgreed,
    CanNotSendInteropToL1,
    MustBeWithdrawalToL1
} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IGWAssetTracker} from "./IGWAssetTracker.sol";
import {MessageHashing} from "../../common/libraries/MessageHashing.sol";
import {IL1ERC20Bridge} from "../interfaces/IL1ERC20Bridge.sol";
import {IMailboxLegacy} from "../../state-transition/chain-interfaces/IMailboxLegacy.sol";
import {IMigrator} from "../../state-transition/chain-interfaces/IMigrator.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";
import {LegacySharedBridgeAddresses, SharedBridgeOnChainId} from "./LegacySharedBridgeAddresses.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

contract GWAssetTracker is AssetTrackerBase, IGWAssetTracker {
    using FullMerkleMemory for FullMerkleMemory.FullTree;
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;
    using SafeERC20 for IERC20;

    uint256 public L1_CHAIN_ID;

    /// @notice Used to track how the balance has changed for each chain during a deposit.
    /// We assume that during a single deposit at most two token balances for a chain are amended:
    /// - base token of the chain.
    /// - bridged token (in case it is a deposit of some sort).
    /// @dev Whenever a failed deposit is processed, the chain balance must be decremented accordingly.
    /// From this, it follows that all failed deposit logs that are ever sent to Gateway must have been routed through this contract,
    /// i.e., a chain cannot migrate on top of ZK Gateway until all deposits that were submitted through L1 have been processed
    /// and vice versa.
    mapping(uint256 chainId => mapping(bytes32 canonicalTxHash => BalanceChange balanceChange)) internal balanceChange;

    /// @notice The address of the token on the origin chain.
    /// @dev We assume that if a chain is registered on the GW's bridgehub and it able to submit related deposits or
    /// batches, this value has been populated for its base token.
    mapping(bytes32 assetId => address originToken) internal originToken;

    /// @notice The chain on which the token was originally issued. For tokens issued on L1, this will be equal to the L1 chain ID.
    mapping(bytes32 assetId => uint256 originChainId) internal tokenOriginChainId;

    /// @notice The address of the L2 shared bridge. It is used only on some old EraVM-based chains.
    /// On such chains, it is responsible for sending withdrawal messages.
    mapping(uint256 chainId => address legacySharedBridgeAddress) internal legacySharedBridgeAddress;

    /// @notice Empty multichainBatchRoot calculated for specific chain.
    mapping(uint256 chainId => bytes32 emptyMultichainBatchRoot) internal emptyMultichainBatchRoot;

    /// @notice Gateway settlement fee per interop operation in ZK tokens.
    /// @dev Set by gateway governance, paid by chain operators during settlement.
    /// @dev On Gateway, ZK is the base token, fees are paid using Wrapped ZK token.
    uint256 public gatewaySettlementFee;

    /// @notice Wrapped ZK token contract used for settlement fee collection.
    /// @dev Since ZK is the base token on Gateway, we use the wrapped version for transfers.
    /// @dev This is fetched from L2NativeTokenVault.WETH_TOKEN on initialization.
    IERC20 public wrappedZKToken;

    /// @notice Tracks whether a fee payer has agreed to pay settlement fees for a specific chain.
    /// @dev This prevents front-running attacks where a malicious operator could make another chain's
    /// fee payer pay for their settlement by specifying their address as settlementFeePayer.
    mapping(address payer => mapping(uint256 chainId => bool)) public settlementFeePayerAgreement;

    /// @notice Tracks token balances sent via interop that have not yet been confirmed as executed on the destination chain.
    /// @dev When a source chain settles and its interop bundle is processed, the destination chain's balance moves
    /// here rather than directly to chainBalance. When the destination chain settles and confirms execution via
    /// InteropHandler messages, balances are moved from here to chainBalance.
    /// @dev This separation ensures chainBalance always equals the totalSupply of the token inside the chain.
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public pendingInteropBalance;

    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != L2_BRIDGEHUB.getZKChain(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2InteropCenter() {
        if (msg.sender != L2_INTEROP_CENTER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyBridgehub() {
        if (msg.sender != L2_BRIDGEHUB_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @inheritdoc IGWAssetTracker
    function initL2(uint256 _l1ChainId, address _owner) external onlyUpgrader {
        L1_CHAIN_ID = _l1ChainId;

        // Fetch wrapped ZK token from Native Token Vault
        // On Gateway, ZK is the base token, so WETH_TOKEN is actually the wrapped ZK token
        address wrappedZK = L2_NATIVE_TOKEN_VAULT.WETH_TOKEN();
        require(wrappedZK != address(0), ZeroAddress());
        wrappedZKToken = IERC20(wrappedZK);

        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    /// @inheritdoc IGWAssetTracker
    function setGatewaySettlementFee(uint256 _fee) external onlyOwner {
        uint256 oldFee = gatewaySettlementFee;
        gatewaySettlementFee = _fee;
        emit GatewaySettlementFeeUpdated(oldFee, _fee);
    }

    /// @inheritdoc IGWAssetTracker
    function withdrawGatewayFees(address _recipient) external onlyOwner {
        if (_recipient == address(0)) {
            revert InvalidFeeRecipient();
        }
        uint256 balance = wrappedZKToken.balanceOf(address(this));
        if (balance > 0) {
            wrappedZKToken.safeTransfer(_recipient, balance);
        }
    }

    /// @inheritdoc IGWAssetTracker
    function agreeToPaySettlementFees(uint256 _chainId) external {
        settlementFeePayerAgreement[msg.sender][_chainId] = true;
        emit SettlementFeePayerAgreementUpdated(msg.sender, _chainId, true);
    }

    /// @inheritdoc IGWAssetTracker
    function revokeSettlementFeePayerAgreement(uint256 _chainId) external {
        settlementFeePayerAgreement[msg.sender][_chainId] = false;
        emit SettlementFeePayerAgreementUpdated(msg.sender, _chainId, false);
    }

    /// @inheritdoc IGWAssetTracker
    function setLegacySharedBridgeAddress() external onlyUpgrader {
        address l1AssetRouter = address(L2_ASSET_ROUTER.L1_ASSET_ROUTER());
        SharedBridgeOnChainId[] memory sharedBridgeOnChainIds = LegacySharedBridgeAddresses
            .getLegacySharedBridgeAddressOnGateway(l1AssetRouter);
        uint256 length = sharedBridgeOnChainIds.length;
        for (uint256 i = 0; i < length; ++i) {
            legacySharedBridgeAddress[sharedBridgeOnChainIds[i].chainId] = sharedBridgeOnChainIds[i]
                .legacySharedBridgeAddress;
        }
    }

    function _l1ChainId() internal view returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view returns (IBridgehubBase) {
        return L2_BRIDGEHUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVaultBase) {
        return L2_NATIVE_TOKEN_VAULT;
    }

    function _messageRoot() internal view returns (IMessageRootBase) {
        return L2_MESSAGE_ROOT;
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    function registerNewTokenIfNeeded(bytes32, uint256) public override onlyNativeTokenVault {
        revert RegisterNewTokenNotAllowed();
    }

    /// @inheritdoc IGWAssetTracker
    function registerBaseTokenOnGateway(TokenBridgingData calldata _baseTokenBridgingData) external onlyBridgehub {
        _registerToken(
            _baseTokenBridgingData.assetId,
            _baseTokenBridgingData.originToken,
            _baseTokenBridgingData.originChainId
        );
    }

    /// @inheritdoc IGWAssetTracker
    function handleChainBalanceIncreaseOnGateway(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        BalanceChange calldata _balanceChange
    ) external onlyL2InteropCenter {
        uint256 chainMigrationNumber = _getChainMigrationNumber(_chainId);
        require(
            chainMigrationNumber == MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
            InvalidChainMigrationNumber(MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, chainMigrationNumber)
        );

        if (_tokenCanSkipMigrationOnSettlementLayer(_chainId, _balanceChange.assetId)) {
            _forceSetAssetMigrationNumber(_chainId, _balanceChange.assetId);
        }
        if (_tokenCanSkipMigrationOnSettlementLayer(_chainId, _balanceChange.baseTokenAssetId)) {
            _forceSetAssetMigrationNumber(_chainId, _balanceChange.baseTokenAssetId);
        }

        /// Note we don't decrease L1ChainBalance here, since we don't track L1 chainBalance on Gateway.
        _increaseChainBalance(_chainId, _balanceChange.assetId, _balanceChange.amount);
        _increaseChainBalance(_chainId, _balanceChange.baseTokenAssetId, _balanceChange.baseTokenAmount);

        _registerToken(_balanceChange.assetId, _balanceChange.originToken, _balanceChange.tokenOriginChainId);

        /// A malicious chain can cause a collision for the canonical tx hash.
        require(balanceChange[_chainId][_canonicalTxHash].version == 0, InvalidCanonicalTxHash(_canonicalTxHash));
        // we save the balance change to be able to handle failed deposits.

        balanceChange[_chainId][_canonicalTxHash] = _balanceChange;
    }

    /// @inheritdoc IGWAssetTracker
    function setLegacySharedBridgeAddress(
        uint256 _chainId,
        address _legacySharedBridgeAddress
    ) external onlyServiceTransactionSender {
        legacySharedBridgeAddress[_chainId] = _legacySharedBridgeAddress;
    }

    /*//////////////////////////////////////////////////////////////
                    Chain settlement logs processing on Gateway
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGWAssetTracker
    function processLogsAndMessages(
        ProcessLogsInput calldata _processLogsInputs
    ) external onlyChain(_processLogsInputs.chainId) {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory reconstructedLogsTree;
        reconstructedLogsTree.createTree(L2_TO_L1_LOGS_MERKLE_TREE_DEPTH);

        // slither-disable-next-line unused-return
        reconstructedLogsTree.setup(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH);

        uint256 msgCount = 0;
        uint256 logsLength = _processLogsInputs.logs.length;
        bytes32 baseTokenAssetId = _bridgehub().baseTokenAssetId(_processLogsInputs.chainId);

        // Count chargeable interop messages during processing
        uint256 chargeableInteropCount = 0;
        for (uint256 logCount = 0; logCount < logsLength; ++logCount) {
            L2Log memory log = _processLogsInputs.logs[logCount];
            {
                bytes32 hashedLog = MessageHashing.getLeafHashFromLog(log);
                // slither-disable-next-line unused-return
                reconstructedLogsTree.push(hashedLog);
            }
            if (log.sender == L2_BOOTLOADER_ADDRESS) {
                _handlePotentialFailedDeposit(_processLogsInputs.chainId, log.key, log.value);
            } else if (log.sender == L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR) {
                ++msgCount;
                bytes calldata message = _processLogsInputs.messages[msgCount - 1];

                if (log.value != keccak256(message)) {
                    revert InvalidMessage();
                }
                require(log.l2ShardId == 0, InvalidL2ShardId());
                require(log.isService, InvalidServiceLog());

                if (log.key == bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR)))) {
                    // Handle interop message and get count of chargeable calls for settlement fees
                    chargeableInteropCount += _handleInteropCenterMessage(_processLogsInputs.chainId, message);
                } else if (log.key == bytes32(uint256(uint160(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR)))) {
                    _handleBaseTokenSystemContractMessage(_processLogsInputs.chainId, baseTokenAssetId, message);
                } else if (log.key == bytes32(uint256(uint160(L2_ASSET_ROUTER_ADDR)))) {
                    _handleAssetRouterMessage(_processLogsInputs.chainId, message);
                } else if (log.key == bytes32(uint256(uint160(L2_ASSET_TRACKER_ADDR)))) {
                    _checkAssetTrackerMessageSelector(message);
                } else if (log.key == bytes32(uint256(uint160(L2_COMPRESSOR_ADDR)))) {
                    // No further action is required in this case.
                } else if (log.key == bytes32(uint256(uint160(L2_KNOWN_CODE_STORAGE_SYSTEM_CONTRACT_ADDR)))) {
                    // No further action is required in this case.
                } else if (log.key == bytes32(uint256(uint160(address(L2_INTEROP_HANDLER_ADDR))))) {
                    _handleInteropHandlerMessage(_processLogsInputs.chainId, message);
                } else if (uint256(log.key) <= MAX_BUILT_IN_CONTRACT_ADDR) {
                    // This Log is not supported
                    revert InvalidBuiltInContractMessage(logCount, msgCount - 1, log.key);
                } else {
                    address legacySharedBridge = legacySharedBridgeAddress[_processLogsInputs.chainId];
                    if (log.key == bytes32(uint256(uint160(legacySharedBridge))) && legacySharedBridge != address(0)) {
                        _handleLegacySharedBridgeMessage(_processLogsInputs.chainId, message);
                    }
                }
            }
        }
        if (msgCount != _processLogsInputs.messages.length) {
            revert InvalidMessage();
        }
        reconstructedLogsTree.extendUntilEnd();
        bytes32 localLogsRootHash = reconstructedLogsTree.root();

        bytes32 expectedEmptyMultichainBatchRoot = _getEmptyMultichainBatchRoot(_processLogsInputs.chainId);
        require(
            _processLogsInputs.multichainBatchRoot == expectedEmptyMultichainBatchRoot,
            InvalidEmptyMultichainBatchRoot(expectedEmptyMultichainBatchRoot, _processLogsInputs.multichainBatchRoot)
        );
        bytes32 chainBatchRootHash = keccak256(bytes.concat(localLogsRootHash, _processLogsInputs.multichainBatchRoot));

        if (chainBatchRootHash != _processLogsInputs.chainBatchRoot) {
            revert ReconstructionMismatch(chainBatchRootHash, _processLogsInputs.chainBatchRoot);
        }

        ///  Appends the batch message root to the global message.
        /// The logic of this function depends on the settlement layer as we support
        /// message root aggregation only on non-L1 settlement layers for ease for migration.
        _messageRoot().addChainBatchRoot(
            _processLogsInputs.chainId,
            _processLogsInputs.batchNumber,
            chainBatchRootHash
        );

        _collectInteropSettlementFee(
            _processLogsInputs.chainId,
            _processLogsInputs.settlementFeePayer,
            chargeableInteropCount
        );
    }

    /// @notice Collects interop settlement fees from the designated fee payer using Wrapped ZK token.
    /// @dev Fee Collection Security Model:
    /// - Fee payers must explicitly opt-in via `agreeToPaySettlementFees(chainId)` before they can be charged
    /// - This prevents front-running attacks where a malicious operator could specify another chain's
    ///   fee payer address to make them pay for unrelated settlements
    /// - Fee payers must also approve wrapped ZK tokens for this contract
    ///
    /// Failure Behavior:
    /// - If fee collection fails (payer not agreed, insufficient balance, or no approval), batch execution reverts
    /// - This ensures fees are always paid atomically with settlement
    /// - Operators must ensure their fee payer has agreed and maintains sufficient balance/approval
    /// @param _chainId The chain ID for which fees are being collected
    /// @param _settlementFeePayer The address paying the settlement fees
    /// @param _chargeableInteropCount The number of chargeable interop messages
    function _collectInteropSettlementFee(
        uint256 _chainId,
        address _settlementFeePayer,
        uint256 _chargeableInteropCount
    ) internal {
        uint256 cachedSettlementFee = gatewaySettlementFee;
        if (_chargeableInteropCount == 0 || cachedSettlementFee == 0) {
            return;
        }

        if (!settlementFeePayerAgreement[_settlementFeePayer][_chainId]) {
            revert SettlementFeePayerNotAgreed(_settlementFeePayer, _chainId);
        }

        uint256 totalFee = cachedSettlementFee * _chargeableInteropCount;

        // Transfer Wrapped ZK tokens from the settlement fee payer to this contract.
        // The fee payer must have pre-approved this contract to spend wrapped ZK tokens.
        // slither-disable-next-line arbitrary-send-erc20
        wrappedZKToken.safeTransferFrom(_settlementFeePayer, address(this), totalFee);

        emit GatewaySettlementFeesCollected(_chainId, _settlementFeePayer, totalFee, _chargeableInteropCount);
    }

    function _getEmptyMultichainBatchRoot(uint256 _chainId) internal returns (bytes32) {
        bytes32 savedEmptyMultichainBatchRoot = emptyMultichainBatchRoot[_chainId];
        if (savedEmptyMultichainBatchRoot != bytes32(0)) {
            return savedEmptyMultichainBatchRoot;
        }
        FullMerkleMemory.FullTree memory sharedTree;
        sharedTree.createTree(1);
        // slither-disable-next-line unused-return
        sharedTree.setup(SHARED_ROOT_TREE_EMPTY_HASH);

        DynamicIncrementalMerkleMemory.Bytes32PushTree memory chainTree;
        chainTree.createTree(1);
        bytes32 initialChainTreeHash = chainTree.setup(CHAIN_TREE_EMPTY_ENTRY_HASH);
        bytes32 leafHash = MessageHashing.chainIdLeafHash(initialChainTreeHash, _chainId);
        bytes32 emptyMultichainBatchRootCalculated = sharedTree.pushNewLeaf(leafHash);

        emptyMultichainBatchRoot[_chainId] = emptyMultichainBatchRootCalculated;
        return emptyMultichainBatchRootCalculated;
    }

    /// @notice Handles potential failed deposits. Not all L1->L2 txs are deposits.
    function _handlePotentialFailedDeposit(uint256 _chainId, bytes32 _canonicalTxHash, bytes32 _value) internal {
        BalanceChange memory savedBalanceChange = balanceChange[_chainId][_canonicalTxHash];
        balanceChange[_chainId][_canonicalTxHash] = BalanceChange({
            version: 0,
            originToken: address(0),
            assetId: bytes32(0),
            amount: 0,
            baseTokenAssetId: bytes32(0),
            baseTokenAmount: 0,
            tokenOriginChainId: 0
        });
        require(savedBalanceChange.version == BALANCE_CHANGE_VERSION, InvalidCanonicalTxHash(_canonicalTxHash));
        if (_value == bytes32(uint256(TxStatus.Success))) {
            return;
        }
        /// Note we handle failedDeposits here for deposits that do not go through GW during chainMigration,
        /// because they were initiated when the chain settles on L1, however the failedDeposit L2->L1 message goes through GW.
        /// Here we do not need to decrement the chainBalance, since the chainBalance was added to the chain's chainBalance on L1,
        /// and never migrated to the GW's chainBalance, since it never increments the totalSupply since the L2 txs fails.
        if (savedBalanceChange.amount > 0) {
            _decreaseChainBalance(_chainId, savedBalanceChange.assetId, savedBalanceChange.amount);
        }
        // Note, that we do not reduce the base token balance for failed deposits,
        // as it is expected that these funds stay on L2 inside the refundRecipient's balance.
    }

    /// @notice Handles an interop center message and returns the number of chargeable calls for settlement fees.
    /// @dev Instead of immediately crediting the destination chain, balances are moved to pendingInteropBalance.
    /// They will be moved to chainBalance when the destination chain settles and confirms execution via
    /// an InteropHandler message that includes the full bundle preimage.
    /// @param _chainId The source chain ID.
    /// @param _message The message data from InteropCenter.
    /// @return chargeableCallCount Number of calls that should incur gateway settlement fees.
    function _handleInteropCenterMessage(
        uint256 _chainId,
        bytes calldata _message
    ) internal returns (uint256 chargeableCallCount) {
        if (_message[0] != BUNDLE_IDENTIFIER) {
            // This should not be possible in V31. In V31 this will be a trigger.
            return 0;
        }

        InteropBundle memory interopBundle = abi.decode(_message[1:], (InteropBundle));

        uint256 totalBaseTokenAmount = 0;

        uint256 interopBundleCallsLength = interopBundle.calls.length;
        for (uint256 callCount = 0; callCount < interopBundleCallsLength; ++callCount) {
            InteropCall memory interopCall = interopBundle.calls[callCount];

            if (interopCall.value > 0) {
                totalBaseTokenAmount += interopCall.value;
            }

            // e.g. for direct calls we just skip
            if (interopCall.from != L2_ASSET_ROUTER_ADDR) {
                continue;
            }

            if (bytes4(interopCall.data) != AssetRouterBase.finalizeDeposit.selector) {
                revert InvalidInteropCalldata(bytes4(interopCall.data));
            }
            // solhint-disable-next-line func-named-parameters
            _processInteropCall(_chainId, interopCall, interopBundle.destinationChainId);
        }

        // We check on the InteropHandler of the destination chain that the `destinationBaseTokenAssetId` is the correct one.
        _decreaseChainBalance(_chainId, interopBundle.destinationBaseTokenAssetId, totalBaseTokenAmount);
        // Increase destination chain pending interop balance for base token.
        // Balance will be moved to chainBalance when the destination chain confirms execution.
        _increasePendingInteropBalance(
            interopBundle.destinationChainId,
            interopBundle.destinationBaseTokenAssetId,
            totalBaseTokenAmount
        );
        // Return chargeable call count for settlement fee calculation.
        return interopBundle.calls.length;
    }

    /// @notice Handles a per-call message from InteropHandler confirming a single interop call was executed.
    /// @dev One such message is emitted for each successfully executed call. Moves the call's balances
    /// from pendingInteropBalance to chainBalance.
    /// @param _chainId The chain ID that is settling (destination chain of the interop bundle).
    /// @param _message The message data from InteropHandler.
    function _handleInteropHandlerMessage(uint256 _chainId, bytes calldata _message) internal {
        bytes4 functionSignature = DataEncoding.getSelector(_message);
        require(
            functionSignature == IAssetTrackerDataEncoding.receiveInteropCallExecuted.selector,
            InvalidFunctionSignature(functionSignature)
        );

        InteropCallExecutedMessage memory executionMsg = abi.decode(_message[4:], (InteropCallExecutedMessage));

        // Move base token balance from pending to confirmed chainBalance.
        if (executionMsg.interopCall.value > 0) {
            _confirmPendingInteropBalance(
                _chainId,
                executionMsg.destinationBaseTokenAssetId,
                executionMsg.interopCall.value
            );
        }

        // Move asset balance from pending to confirmed chainBalance (for asset router calls).
        if (executionMsg.interopCall.from == L2_ASSET_ROUTER_ADDR) {
            // slither-disable-next-line unused-return
            (, bytes32 assetId, bytes memory transferData) = this.parseInteropCall(executionMsg.interopCall.data);
            // slither-disable-next-line unused-return
            (, , , uint256 assetAmount, ) = DataEncoding.decodeBridgeMintData(transferData);
            if (assetAmount > 0) {
                _confirmPendingInteropBalance(_chainId, assetId, assetAmount);
            }
        }
    }

    function _processInteropCall(
        uint256 _chainId,
        InteropCall memory _interopCall,
        uint256 _destinationChainId
    ) internal {
        (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = this.parseInteropCall(_interopCall.data);

        require(_chainId == fromChainId, InvalidInteropChainId(fromChainId, _destinationChainId));

        // solhint-disable-next-line func-named-parameters
        _handleAssetRouterMessageInner(_chainId, _destinationChainId, assetId, transferData, true);
    }

    /// @notice L2->L1 withdrawals go through the L2AssetRouter directly.
    function _handleAssetRouterMessage(uint256 _chainId, bytes memory _message) internal {
        // slither-disable-next-line unused-return
        (bytes4 functionSignature, , bytes32 assetId, bytes memory transferData) = DataEncoding
            .decodeAssetRouterFinalizeDepositData(_message);
        require(
            functionSignature == AssetRouterBase.finalizeDeposit.selector,
            InvalidFunctionSignature(functionSignature)
        );
        // solhint-disable-next-line func-named-parameters
        _handleAssetRouterMessageInner(_chainId, L1_CHAIN_ID, assetId, transferData, false);
    }

    /// @notice Handles the logic of the AssetRouter message.
    /// @param _sourceChainId The chain id of the source chain. Can not be L1.
    /// @param _destinationChainId The chain id of the destination chain. Can be L1.
    /// @param _assetId The asset id of the asset.
    /// @param _transferData The transfer data of the asset.
    /// @param _isInteropCall If true, decreases source chainBalance and increases destination pendingInteropBalance.
    ///        If false, decreases source chainBalance (standard L2->L1 withdrawal; L1 balance is not tracked).
    function _handleAssetRouterMessageInner(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        bytes32 _assetId,
        bytes memory _transferData,
        bool _isInteropCall
    ) internal returns (uint256 amount) {
        address originalToken;
        bytes memory erc20Metadata;
        // slither-disable-next-line unused-return
        (, , originalToken, amount, erc20Metadata) = DataEncoding.decodeBridgeMintData(_transferData);
        // slither-disable-next-line unused-return
        (uint256 tokenOriginalChainId, , , ) = this.parseTokenData(erc20Metadata);
        DataEncoding.assetIdCheck(tokenOriginalChainId, _assetId, originalToken);
        _registerToken(_assetId, originalToken, tokenOriginalChainId);
        _decreaseChainBalance(_sourceChainId, _assetId, amount);

        if (_isInteropCall) {
            // Interop calls can not be used to L1.
            // This error should never be triggered, it is just an invariant check.
            require(_destinationChainId != L1_CHAIN_ID, CanNotSendInteropToL1(_destinationChainId));

            _increasePendingInteropBalance(_destinationChainId, _assetId, amount);
        } else {
            // When it is not an interop call, we expect it to be a withdrawal to L1
            // This error should never be triggered, it is just an invariant check.
            require(_destinationChainId == L1_CHAIN_ID, MustBeWithdrawalToL1(_destinationChainId));
        }
    }

    /// @notice Handles withdrawal messages from legacy shared bridge contracts on pre-V31 chains.
    /// @dev This function provides backwards compatibility for chains that used the old bridge system.
    /// @param _chainId The chain ID that sent the legacy withdrawal message.
    /// @param _message The raw legacy bridge message containing withdrawal data.
    function _handleLegacySharedBridgeMessage(uint256 _chainId, bytes memory _message) internal {
        (bytes4 functionSignature, address l1Token, bytes memory transferData) = DataEncoding
            .decodeLegacyFinalizeWithdrawalData(L1_CHAIN_ID, _message);
        require(
            functionSignature == IL1ERC20Bridge.finalizeWithdrawal.selector,
            InvalidFunctionSignature(functionSignature)
        );
        // The legacy shared bridge message is only for L1 tokens on legacy chains where the legacy L2 shared bridge is deployed.
        // Convert legacy L1 token to modern asset ID format
        bytes32 expectedAssetId = DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, l1Token);

        // Process the withdrawal using the modern asset router logic
        // slither-disable-next-line unused-return
        _handleAssetRouterMessageInner({
            _sourceChainId: _chainId,
            _destinationChainId: L1_CHAIN_ID,
            _assetId: expectedAssetId,
            _transferData: transferData,
            _isInteropCall: false
        });
    }

    /// @notice L2->L1 base token withdrawals go through the L2BaseTokenSystemContract directly.
    function _handleBaseTokenSystemContractMessage(
        uint256 _chainId,
        bytes32 _baseTokenAssetId,
        bytes memory _message
    ) internal {
        // slither-disable-next-line unused-return
        (bytes4 functionSignature, , uint256 amount) = DataEncoding.decodeBaseTokenFinalizeWithdrawalData(_message);
        require(
            functionSignature == IMailboxLegacy.finalizeEthWithdrawal.selector,
            InvalidFunctionSignature(functionSignature)
        );
        _decreaseChainBalance(_chainId, _baseTokenAssetId, amount);
    }

    /// @notice Validates selectors for messages emitted by L2AssetTracker.
    /// @dev Gateway only accepts selectors that L2AssetTracker can emit through L2ToL1Messenger.
    function _checkAssetTrackerMessageSelector(bytes memory _message) internal pure {
        bytes4 functionSignature = DataEncoding.getSelector(_message);
        require(
            functionSignature == IAssetTrackerDataEncoding.receiveL1ToGatewayMigrationOnL1.selector,
            InvalidFunctionSignature(functionSignature)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration 
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IGWAssetTracker
    function requestPauseDepositsForChain(uint256 _chainId) external onlyServiceTransactionSender {
        address zkChain = _bridgehub().getZKChain(_chainId);
        require(zkChain != address(0), ChainIdNotRegistered(_chainId));
        IMigrator(zkChain).pauseDepositsOnGateway(block.timestamp);
    }

    /// @inheritdoc IGWAssetTracker
    function initiateGatewayToL1MigrationOnGateway(uint256 _chainId, bytes32 _assetId) external {
        address zkChain = L2_BRIDGEHUB.getZKChain(_chainId);
        require(zkChain != address(0), ChainIdNotRegistered(_chainId));

        // If the chain already migrated back to GW, then we need the previous migration number.
        uint256 chainMigrationNumber = _calculatePreviousChainMigrationNumber(_chainId);
        require(assetMigrationNumber[_chainId][_assetId] < chainMigrationNumber, InvalidAssetMigrationNumber());

        require(
            chainMigrationNumber == MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1,
            InvalidChainMigrationNumber(chainMigrationNumber, MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1)
        );

        uint256 amount = chainBalance[_chainId][_assetId];
        GatewayToL1TokenBalanceMigrationData memory tokenBalanceMigrationData = GatewayToL1TokenBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            originToken: originToken[_assetId],
            chainId: _chainId,
            assetId: _assetId,
            tokenOriginChainId: tokenOriginChainId[_assetId],
            amount: amount,
            chainMigrationNumber: chainMigrationNumber,
            assetMigrationNumber: assetMigrationNumber[_chainId][_assetId]
        });
        // slither-disable-next-line reentrancy-no-eth
        _sendGatewayToL1MigrationDataToL1(tokenBalanceMigrationData);

        // We assign chain balance to 0 and bump asset migration number for replay protection
        chainBalance[_chainId][_assetId] = 0;
        assetMigrationNumber[_chainId][_assetId] = chainMigrationNumber;

        emit GatewayToL1MigrationInitiated(_assetId, _chainId, amount);
    }

    function _calculatePreviousChainMigrationNumber(uint256 _chainId) internal view returns (uint256) {
        uint256 settlementLayer = L2_BRIDGEHUB.settlementLayer(_chainId);
        uint256 chainMigrationNumber = _getChainMigrationNumber(_chainId);
        // If the chain already migrated back to GW, then we need the previous migration number.
        if (settlementLayer == block.chainid) {
            --chainMigrationNumber;
        }
        return chainMigrationNumber;
    }

    /// @inheritdoc IGWAssetTracker
    function confirmMigrationOnGateway(MigrationConfirmationData calldata _data) external onlyServiceTransactionSender {
        if (_data.isL1ToGateway) {
            assetMigrationNumber[_data.chainId][_data.assetId] = _data.assetMigrationNumber;
            // Register the token if it wasn't already
            _registerToken(_data.assetId, _data.originToken, _data.tokenOriginChainId);

            /// In this case the balance might never have been migrated back to L1.
            chainBalance[_data.chainId][_data.assetId] += _data.amount;
        }

        // For migrations from GW, the chainBalance and assetMigrationNumber are updated at the initiation of the migration.
        // Additionally, all the tokens are expected to be registered the first time they are deposited via the GWAssetTracker, i.e.
        // the amount migrated can not be more than 0 if the token was not registered.
    }

    /*//////////////////////////////////////////////////////////////
                            Helper Functions
    //////////////////////////////////////////////////////////////*/

    function _increaseChainBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        if (_amount > 0) {
            chainBalance[_chainId][_assetId] += _amount;
        }
    }

    function _increasePendingInteropBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        if (_amount > 0) {
            pendingInteropBalance[_chainId][_assetId] += _amount;
        }
    }

    function _decreasePendingInteropBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        if (pendingInteropBalance[_chainId][_assetId] < _amount) {
            revert InsufficientPendingInteropBalance(_chainId, _assetId, _amount);
        }
        pendingInteropBalance[_chainId][_assetId] -= _amount;
    }

    function _confirmPendingInteropBalance(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        _decreasePendingInteropBalance(_chainId, _assetId, _amount);
        _increaseChainBalance(_chainId, _assetId, _amount);
    }

    /// @notice Registers a token's original details if it hasn't been registered yet.
    /// @dev Note, that we do not double check the correctness of the data provided here, so it must come from a trusted source.
    /// - In case of deposits, the should come from the Mailbox of Gateway.
    /// - In case of registration of base token on Gateway, it is checked inside the L1ChainAssetHandler.
    /// - In case of migration confirmation, it should be checked by the L1AssetTracker.
    /// - In case of interop transactions, the assetId check is performed inside the GWAssetTracker.
    function _registerToken(bytes32 _assetId, address _originalToken, uint256 _tokenOriginChainId) internal {
        if (originToken[_assetId] == address(0)) {
            originToken[_assetId] = _originalToken;
            tokenOriginChainId[_assetId] = _tokenOriginChainId;
        }
    }

    /// @inheritdoc IGWAssetTracker
    function parseInteropCall(
        bytes calldata _callData
    ) external pure returns (uint256 fromChainId, bytes32 assetId, bytes memory transferData) {
        (fromChainId, assetId, transferData) = abi.decode(_callData[4:], (uint256, bytes32, bytes));
    }

    /// @inheritdoc IGWAssetTracker
    function parseTokenData(
        bytes calldata _tokenData
    ) external pure returns (uint256 originChainId, bytes memory name, bytes memory symbol, bytes memory decimals) {
        (originChainId, name, symbol, decimals) = DataEncoding.decodeTokenData(_tokenData);
    }

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return L2_CHAIN_ASSET_HANDLER.migrationNumber(_chainId);
    }

    /*//////////////////////////////////////////////////////////////
                        Test-only Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev For local testing only.
    function setLegacySharedBridgeAddressForLocalTesting(
        uint256 _chainId,
        address _legacySharedBridgeAddress
    ) external onlyUpgrader {
        legacySharedBridgeAddress[_chainId] = _legacySharedBridgeAddress;
    }
}
