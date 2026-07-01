// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

import {AssetRouterBase} from "./asset-router/AssetRouterBase.sol";
import {IL1NativeTokenVault} from "./ntv/IL1NativeTokenVault.sol";

import {IL1AssetRouter} from "./asset-router/IL1AssetRouter.sol";
import {FinalizeL1DepositParams, IL1Nullifier, TRANSIENT_SETTLEMENT_LAYER_SLOT} from "./interfaces/IL1Nullifier.sol";

import {ConfirmTransferResultData, L2Log, L2Message, TxStatus} from "../common/Messaging.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {IMailboxImpl} from "../state-transition/chain-interfaces/IMailboxImpl.sol";
import {L2_ASSET_ROUTER_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {
    AddressAlreadySet,
    DepositDoesNotExist,
    DepositExists,
    InvalidProof,
    InvalidSelector,
    Unauthorized,
    WithdrawalAlreadyFinalized,
    ZeroAddress
} from "../common/L1ContractErrors.sol";
import {NativeTokenVaultAlreadySet, WrongL2Sender} from "./L1BridgeContractErrors.sol";
import {MessageHashing, ProofData} from "../common/libraries/MessageHashing.sol";
import {TransientPrimitivesLib} from "../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1Nullifier is IL1Nullifier, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    /// @dev Bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication.
    IL1Bridgehub public immutable override BRIDGE_HUB;

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @dev The address of ZKsync Era diamond proxy contract.
    address internal immutable ERA_DIAMOND_PROXY;

    /// @dev MessageRoot smart contract that is used to prove message inclusion.
    IMessageRootBase public immutable MESSAGE_ROOT;

    /// @dev Stores the first batch number on the ZKsync Era Diamond Proxy that was settled after Diamond proxy upgrade.
    /// This variable is used to differentiate between pre-upgrade and post-upgrade Eth withdrawals. Withdrawals from batches older
    /// than this value are considered to have been finalized prior to the upgrade and handled separately.
    uint256 internal eraPostDiamondUpgradeFirstBatch;

    /// @dev Deprecated legacy-bridge slots, retained ONLY to preserve the upgradeable storage layout.
    /// Formerly: eraPostLegacyBridgeUpgradeFirstBatch, eraLegacyBridgeLastDepositBatch,
    /// eraLegacyBridgeLastDepositTxNumber, and legacyBridge (the L1ERC20 legacy-bridge support).
    /// These are no longer read or written; do not reuse them.
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_eraPostLegacyBridgeUpgradeFirstBatch;
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_eraLegacyBridgeLastDepositBatch;
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_eraLegacyBridgeLastDepositTxNumber;
    // slither-disable-next-line uninitialized-state
    address private __DEPRECATED_legacyBridge;

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
        require(msg.sender == address(l1AssetRouter), Unauthorized(msg.sender));
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(
        IL1Bridgehub _bridgehub,
        IMessageRootBase _messageRoot,
        uint256 _eraChainId,
        address _eraDiamondProxy
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGE_HUB = _bridgehub;
        MESSAGE_ROOT = _messageRoot;
        ERA_CHAIN_ID = _eraChainId;
        ERA_DIAMOND_PROXY = _eraDiamondProxy;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy.
    /// @dev Used for testing purposes only, as the contract has been initialized on mainnet.
    /// @param _owner The address which can change L2 token implementation and upgrade the bridge implementation.
    /// The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge.
    /// @param _eraPostDiamondUpgradeFirstBatch The first batch number on the ZKsync Era Diamond Proxy that was settled after diamond proxy upgrade.
    function initialize(
        address _owner,
        uint256 _eraPostDiamondUpgradeFirstBatch
    ) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
        if (eraPostDiamondUpgradeFirstBatch == 0) {
            eraPostDiamondUpgradeFirstBatch = _eraPostDiamondUpgradeFirstBatch;
        }
    }

    /// @notice Sets the nativeTokenVault contract address.
    /// @dev Should be called only once by the owner.
    /// @param _l1NativeTokenVault The address of the native token vault.
    function setL1NativeTokenVault(IL1NativeTokenVault _l1NativeTokenVault) external onlyOwner {
        require(address(l1NativeTokenVault) == address(0), NativeTokenVaultAlreadySet());
        require(address(_l1NativeTokenVault) != address(0), ZeroAddress());
        l1NativeTokenVault = _l1NativeTokenVault;
    }

    /// @notice Sets the L1 asset router contract address.
    /// @dev Should be called only once by the owner.
    /// @param _l1AssetRouter The address of the asset router.
    function setL1AssetRouter(address _l1AssetRouter) external onlyOwner {
        require(address(l1AssetRouter) == address(0), AddressAlreadySet(address(l1AssetRouter)));
        require(_l1AssetRouter != address(0), ZeroAddress());
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
        require(depositHappened[_chainId][_txHash] == 0x00, DepositExists());
        depositHappened[_chainId][_txHash] = _txDataHash;
        emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
    }

    function bridgeConfirmTransferResult(
        ConfirmTransferResultData memory _confirmTransferResultData
    ) public nonReentrant {
        _verifyAndClearTransfer(_confirmTransferResultData);
        l1AssetRouter.bridgeConfirmTransferResult({
            _chainId: _confirmTransferResultData._chainId,
            _txStatus: _confirmTransferResultData._txStatus,
            _depositSender: _confirmTransferResultData._depositSender,
            _assetId: _confirmTransferResultData._assetId,
            _assetData: _confirmTransferResultData._assetData
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
        _verifyAndClearTransfer(
            ConfirmTransferResultData({
                _chainId: _chainId,
                _depositSender: _depositSender,
                _assetId: _assetId,
                _assetData: _assetData,
                _l2TxHash: _l2TxHash,
                _l2BatchNumber: _l2BatchNumber,
                _l2MessageIndex: _l2MessageIndex,
                _l2TxNumberInBatch: _l2TxNumberInBatch,
                _merkleProof: _merkleProof,
                _txStatus: TxStatus.Failure
            })
        );

        l1AssetRouter.bridgeConfirmTransferResult({
            _chainId: _chainId,
            _txStatus: TxStatus.Failure,
            _depositSender: _depositSender,
            _assetId: _assetId,
            _assetData: _assetData
        });
    }

    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _confirmTransferResultData The data for confirming the transfer result.
    /// @dev Processes claims of failed deposits.
    function _verifyAndClearTransfer(
        ConfirmTransferResultData memory _confirmTransferResultData
    ) internal whenNotPaused {
        {
            bool proofValid = MESSAGE_ROOT.proveL1ToL2TransactionStatusShared({
                _chainId: _confirmTransferResultData._chainId,
                _l2TxHash: _confirmTransferResultData._l2TxHash,
                _l2BatchNumber: _confirmTransferResultData._l2BatchNumber,
                _l2MessageIndex: _confirmTransferResultData._l2MessageIndex,
                _l2TxNumberInBatch: _confirmTransferResultData._l2TxNumberInBatch,
                _merkleProof: _confirmTransferResultData._merkleProof,
                _status: _confirmTransferResultData._txStatus
            });
            require(proofValid, InvalidProof());
            L2Log memory l2Log = MessageHashing.getL2LogFromL1ToL2Transaction(
                _confirmTransferResultData._l2TxNumberInBatch,
                _confirmTransferResultData._l2TxHash,
                _confirmTransferResultData._txStatus
            );

            bytes32 leaf = MessageHashing.getLeafHashFromLog(l2Log);
            ProofData memory proofData = MESSAGE_ROOT.getProofData({
                _chainId: _confirmTransferResultData._chainId,
                _batchNumber: _confirmTransferResultData._l2BatchNumber,
                _leafProofMask: _confirmTransferResultData._l2MessageIndex,
                _leaf: leaf,
                _proof: _confirmTransferResultData._merkleProof
            });
            TransientPrimitivesLib.set(TRANSIENT_SETTLEMENT_LAYER_SLOT, proofData.settlementLayerChainId);
            TransientPrimitivesLib.set(TRANSIENT_SETTLEMENT_LAYER_SLOT + 1, _confirmTransferResultData._l2BatchNumber);
            emit TransientSettlementLayerSet(proofData.settlementLayerChainId);
        }

        {
            bytes32 dataHash = depositHappened[_confirmTransferResultData._chainId][
                _confirmTransferResultData._l2TxHash
            ];
            bytes32 txDataHash = DataEncoding.encodeTxDataHash({
                _originalCaller: _confirmTransferResultData._depositSender,
                _assetId: _confirmTransferResultData._assetId,
                _transferData: _confirmTransferResultData._assetData
            });
            if (dataHash != txDataHash) {
                revert DepositDoesNotExist(dataHash, txDataHash);
            }
        }
        delete depositHappened[_confirmTransferResultData._chainId][_confirmTransferResultData._l2TxHash];
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
        require(!isWithdrawalFinalized[chainId][l2BatchNumber][l2MessageIndex], WithdrawalAlreadyFinalized());
        isWithdrawalFinalized[chainId][l2BatchNumber][l2MessageIndex] = true;

        (bytes32 assetId, bytes memory transferData) = _verifyWithdrawal(_finalizeWithdrawalParams);

        AssetRouterBase(address(l1AssetRouter)).finalizeDeposit(chainId, assetId, transferData);
    }

    /// @notice Verifies the validity of a withdrawal message from L2 and returns withdrawal details.
    /// @param _finalizeWithdrawalParams The structure that holds all necessary data to finalize withdrawal
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdrawal.
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
            if (baseTokenWithdrawal) {
                require(l2Sender == L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, WrongL2Sender(l2Sender));
            } else {
                bool isL2SenderCorrect = l2Sender == L2_ASSET_ROUTER_ADDR ||
                    l2Sender == __DEPRECATED_l2BridgeAddress[_finalizeWithdrawalParams.chainId];
                require(isL2SenderCorrect, WrongL2Sender(l2Sender));
            }

            l2ToL1Message = L2Message({
                txNumberInBatch: _finalizeWithdrawalParams.l2TxNumberInBatch,
                sender: l2Sender,
                data: _finalizeWithdrawalParams.message
            });
        }

        bool success = MESSAGE_ROOT.proveL2MessageInclusionShared({
            _chainId: _finalizeWithdrawalParams.chainId,
            _blockOrBatchNumber: _finalizeWithdrawalParams.l2BatchNumber,
            _index: _finalizeWithdrawalParams.l2MessageIndex,
            _message: l2ToL1Message,
            _proof: _finalizeWithdrawalParams.merkleProof
        });
        // withdrawal wrong proof
        require(success, InvalidProof());

        bytes32 leaf = MessageHashing.getLeafHashFromMessage(l2ToL1Message);
        ProofData memory proofData = MESSAGE_ROOT.getProofData({
            _chainId: _finalizeWithdrawalParams.chainId,
            _batchNumber: _finalizeWithdrawalParams.l2BatchNumber,
            _leafProofMask: _finalizeWithdrawalParams.l2MessageIndex,
            _leaf: leaf,
            _proof: _finalizeWithdrawalParams.merkleProof
        });
        TransientPrimitivesLib.set(TRANSIENT_SETTLEMENT_LAYER_SLOT, proofData.settlementLayerChainId);
        TransientPrimitivesLib.set(TRANSIENT_SETTLEMENT_LAYER_SLOT + 1, _finalizeWithdrawalParams.l2BatchNumber);
        emit TransientSettlementLayerSet(proofData.settlementLayerChainId);
    }

    /// @inheritdoc IL1Nullifier
    function getTransientSettlementLayer() external view returns (uint256, uint256) {
        return (
            TransientPrimitivesLib.getUint256(TRANSIENT_SETTLEMENT_LAYER_SLOT),
            TransientPrimitivesLib.getUint256(TRANSIENT_SETTLEMENT_LAYER_SLOT + 1)
        );
    }

    /// @notice Parses the withdrawal message and returns withdrawal details.
    /// @dev Currently, 3 different encoding versions are supported: legacy mailbox withdrawal, ERC20 bridge withdrawal,
    /// @dev and the latest version supported by shared bridge. Selectors are used for versioning.
    /// @param _chainId The ZK chain ID.
    /// @param _l2ToL1message The encoded L2 -> L1 message.
    /// @return assetId The ID of the bridged asset.
    /// @return transferData The transfer data used to finalize withdrawal.
    /// @dev The `transferData` is expected to be encoded using `DataEncoding.encodeBridgeMintData`.
    /// Note, that the `_originalCaller`, `_originToken` and `_erc20Metadata` fields in the encoded `transferData` could be empty,
    /// so they should not be relied upon.
    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _l2ToL1message
    ) internal returns (bytes32 assetId, bytes memory transferData) {
        // Please note that there are two versions of the message:
        // 1. The message that is sent from `L2BaseToken` to withdraw base token.
        // 2. The message that is sent from L2 Asset Router to withdraw ERC20 tokens or base token.

        uint256 amount;
        address l1Receiver;

        bytes4 functionSignature = DataEncoding.getSelector(_l2ToL1message);
        if (functionSignature == IMailboxImpl.finalizeEthWithdrawal.selector) {
            // slither-disable-next-line unused-return
            (, l1Receiver, amount) = DataEncoding.decodeBaseTokenFinalizeWithdrawalData(_l2ToL1message);
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
        } else if (functionSignature == AssetRouterBase.finalizeDeposit.selector) {
            // slither-disable-next-line unused-return
            (, , assetId, transferData) = DataEncoding.decodeAssetRouterFinalizeDepositData(_l2ToL1message);
        } else {
            revert InvalidSelector(bytes4(functionSignature));
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
}
