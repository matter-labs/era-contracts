// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/security/PausableUpgradeable.sol";

import {IL1NativeTokenVault} from "./ntv/IL1NativeTokenVault.sol";

import {IL1AssetRouter} from "./asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "./interfaces/IL1Nullifier.sol";
import {IL1InteropHandler} from "./interfaces/IL1InteropHandler.sol";

import {ConfirmTransferResultData, L2Log, TxStatus} from "../common/Messaging.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";

import {IL1Bridgehub} from "../core/bridgehub/IL1Bridgehub.sol";
import {
    AddressAlreadySet,
    DepositDoesNotExist,
    DepositExists,
    InvalidProof,
    Unauthorized,
    ZeroAddress
} from "../common/L1ContractErrors.sol";
import {NativeTokenVaultAlreadySet} from "./L1BridgeContractErrors.sol";
import {MessageHashing, ProofData} from "../common/libraries/MessageHashing.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Bridges assets between L1 and ZK chain, supporting both ETH and ERC20 tokens.
/// @dev Designed for use with a proxy for upgradability.
contract L1Nullifier is IL1Nullifier, ReentrancyGuard, Ownable2StepUpgradeable, PausableUpgradeable {
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

    /// @dev Deprecated. Withdrawal replay protection now lives in `L1InteropHandler.isWithdrawalFinalized`.
    /// Retained ONLY to preserve the upgradeable storage layout; no longer read or written.
    // slither-disable-next-line uninitialized-state
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        internal __DEPRECATED_isWithdrawalFinalized;

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

    /// @dev Address of the L1 interop handler that finalizes L2 -> L1 withdrawals. This contract records the
    /// transient settlement layer on it while confirming failed-deposit recovery so the `L1AssetTracker` can read a
    /// single, consistent source for both flows.
    address public l1InteropHandler;

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

    /// @notice Sets the L1 interop handler contract address.
    /// @dev Should be called only once by the owner.
    /// @param _l1InteropHandler The address of the interop handler.
    function setL1InteropHandler(address _l1InteropHandler) external onlyOwner {
        require(l1InteropHandler == address(0), AddressAlreadySet(l1InteropHandler));
        require(_l1InteropHandler != address(0), ZeroAddress());
        l1InteropHandler = _l1InteropHandler;
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
            // Record the settlement layer on the L1 interop handler, which owns the transient slot that the
            // `L1AssetTracker` reads while attributing this failed-deposit claim.
            IL1InteropHandler(l1InteropHandler).setTransientSettlementLayer(
                proofData.settlementLayerChainId,
                _confirmTransferResultData._l2BatchNumber
            );
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
