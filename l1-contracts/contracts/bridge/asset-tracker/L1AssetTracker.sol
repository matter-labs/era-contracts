// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {TokenBalanceMigrationData} from "../../common/Messaging.sol";
import {GW_ASSET_TRACKER_ADDR, L2_ASSET_TRACKER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {InvalidProof, ZeroAddress, InvalidChainId, Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRoot, V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY} from "../../core/message-root/IMessageRoot.sol";
import {IBridgehubBase} from "../../core/bridgehub/IBridgehubBase.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "../../bridge/interfaces/IL1Nullifier.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";

import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {InvalidChainMigrationNumber, InvalidFunctionSignature, InvalidMigrationNumber, InvalidSender, InvalidWithdrawalChainId, NotMigratedChain, OnlyWhitelistedSettlementLayer, TransientBalanceChangeAlreadySet, InvalidVersion, L1TotalSupplyAlreadyMigrated, InvalidAssetMigrationNumber, InvalidSettlementLayer} from "./AssetTrackerErrors.sol";
import {V31UpgradeChainBatchNumberNotSet} from "../../core/bridgehub/L1BridgehubErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "./IAssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IGWAssetTracker} from "./IGWAssetTracker.sol";
import {IL1AssetTracker} from "./IL1AssetTracker.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IChainAssetHandler} from "../../core/chain-asset-handler/IChainAssetHandler.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";
import {IL1MessageRoot} from "../../core/message-root/IL1MessageRoot.sol";

contract L1AssetTracker is AssetTrackerBase, IL1AssetTracker {
    IBridgehubBase public immutable BRIDGE_HUB;

    INativeTokenVaultBase public immutable NATIVE_TOKEN_VAULT;

    IMessageRoot public immutable MESSAGE_ROOT;

    IL1Nullifier public immutable L1_NULLIFIER;

    IChainAssetHandler public chainAssetHandler;

    /// Todo Deprecate after V31 is finished.
    mapping(bytes32 assetId => bool l1TotalSupplyMigrated) internal l1TotalSupplyMigrated;

    function _nativeTokenVault() internal view override returns (INativeTokenVaultBase) {
        return NATIVE_TOKEN_VAULT;
    }

    modifier onlyWhitelistedSettlementLayer(uint256 _callerChainId) {
        require(
            BRIDGE_HUB.whitelistedSettlementLayers(_callerChainId) &&
                BRIDGE_HUB.getZKChain(_callerChainId) == msg.sender,
            OnlyWhitelistedSettlementLayer(BRIDGE_HUB.getZKChain(_callerChainId), msg.sender)
        );
        _;
    }

    /// @notice Modifier to ensure the caller is the specified chain.
    /// @param _chainId The ID of the chain that has to be the caller.
    modifier onlyChain(uint256 _chainId) {
        if (msg.sender != BRIDGE_HUB.getZKChain(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                    Initialization
    //////////////////////////////////////////////////////////////*/

    constructor(address _bridgehub, address _nativeTokenVault, address _messageRoot) reentrancyGuardInitializer {
        _disableInitializers();

        BRIDGE_HUB = IBridgehubBase(_bridgehub);
        NATIVE_TOKEN_VAULT = INativeTokenVaultBase(_nativeTokenVault);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
        L1_NULLIFIER = IL1Nullifier(IL1NativeTokenVault(_nativeTokenVault).L1_NULLIFIER());
    }

    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    function setAddresses() external onlyOwner {
        chainAssetHandler = IChainAssetHandler(BRIDGE_HUB.chainAssetHandler());
    }

    /// @notice This function is used to migrate the token balance from the NTV to the AssetTracker for V31 upgrade.
    /// @param _chainId The chain id of the chain to migrate the token balance for.
    /// @param _assetId The asset id of the token to migrate the token balance for.
    function migrateTokenBalanceFromNTVV31(uint256 _chainId, bytes32 _assetId) external {
        IL1NativeTokenVault l1NTV = IL1NativeTokenVault(address(NATIVE_TOKEN_VAULT));
        uint256 originChainId = NATIVE_TOKEN_VAULT.originChainId(_assetId);
        require(originChainId != 0, InvalidChainId());
        // We do not migrate the chainBalance for the originChain directly, but indirectly by subtracting from MAX_TOKEN_BALANCE.
        // Its important to call this for all chains in the ecosystem so that the sum is accurate.
        require(_chainId != originChainId, InvalidChainId());
        uint256 migratedBalance;
        if (_chainId != block.chainid) {
            migratedBalance = l1NTV.migrateTokenBalanceToAssetTracker(_chainId, _assetId);
        } else {
            address tokenAddress = NATIVE_TOKEN_VAULT.tokenAddress(_assetId);
            migratedBalance = IERC20(tokenAddress).totalSupply();
            // Unlike the case where we migrate the balance for L2 chains, the balance inside `L1NativeTokenVault` is not reset to zero,
            // and so we need to ensure via the mapping below that the total supply is migrated only once.
            require(!l1TotalSupplyMigrated[_assetId], L1TotalSupplyAlreadyMigrated());
            l1TotalSupplyMigrated[_assetId] = true;
        }

        // Note it might be the case that the token's balance has not been registered on L1 yet,
        // in this case the chainBalance[originChainId][_assetId] is set to MAX_TOKEN_BALANCE if it was not already.
        // Note before the token is migrated the MAX_TOKEN_BALANCE is not assigned, since the registerNewToken is only called for new tokens.
        _assignMaxChainBalanceIfNeeded(originChainId, _assetId);
        chainBalance[originChainId][_assetId] -= migratedBalance;
        chainBalance[_chainId][_assetId] += migratedBalance;
    }

    function registerNewToken(bytes32 _assetId, uint256 _originChainId) public override onlyNativeTokenVault {
        _assignMaxChainBalanceIfNeeded(_originChainId, _assetId);
    }

    function _assignMaxChainBalanceIfNeeded(uint256 _originChainId, bytes32 _assetId) internal {
        if (!maxChainBalanceAssigned[_assetId]) {
            _assignMaxChainBalance(_originChainId, _assetId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @notice Called on the L1 when a deposit to the chain happens.
    /// @dev As the chain does not update its balance when settling on L1.
    /// @param _chainId The destination chain id of the transfer.
    function handleChainBalanceIncreaseOnL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 // _tokenOriginChainId
    ) external onlyNativeTokenVault {
        uint256 currentSettlementLayer = BRIDGE_HUB.settlementLayer(_chainId);
        if (_tokenCanSkipMigrationOnSettlementLayer(_chainId, _assetId)) {
            _forceSetAssetMigrationNumber(_chainId, _assetId);
        }

        uint256 chainToUpdate = currentSettlementLayer == block.chainid ? _chainId : currentSettlementLayer;
        if (currentSettlementLayer != block.chainid) {
            bytes32 baseTokenAssetId = BRIDGE_HUB.baseTokenAssetId(_chainId);
            if (baseTokenAssetId != _assetId) {
                _setTransientBalanceChange(_chainId, _assetId, _amount);
            }
        }

        chainBalance[chainToUpdate][_assetId] += _amount;
        _decreaseChainBalance(block.chainid, _assetId, _amount);
    }

    /// @notice We set the transient balance change so the Mailbox can consume it so the Gateway can keep track of the balance change.
    function _setTransientBalanceChange(uint256 _chainId, bytes32 _assetId, uint256 _amount) internal {
        uint256 key = uint256(keccak256(abi.encode(_chainId)));
        uint256 storedAssetId = TransientPrimitivesLib.getUint256(key);
        uint256 storedAmount = TransientPrimitivesLib.getUint256(key + 1);
        require(storedAssetId == 0, TransientBalanceChangeAlreadySet(storedAssetId, storedAmount));
        require(storedAmount == 0, TransientBalanceChangeAlreadySet(storedAssetId, storedAmount));
        TransientPrimitivesLib.set(key, uint256(_assetId));
        TransientPrimitivesLib.set(key + 1, _amount);
    }

    /// @notice Called on the L1 by the gateway's mailbox when a deposit happens
    /// @notice Used for deposits via Gateway.
    /// @dev Note that this function assumes that all whitelisted settlement layers are trusted.
    function consumeBalanceChange(
        uint256 _callerChainId,
        uint256 _chainId
    ) external onlyWhitelistedSettlementLayer(_callerChainId) returns (bytes32 assetId, uint256 amount) {
        uint256 key = uint256(keccak256(abi.encode(_chainId)));
        assetId = bytes32(TransientPrimitivesLib.getUint256(key));
        amount = TransientPrimitivesLib.getUint256(key + 1);
        TransientPrimitivesLib.set(key, 0);
        TransientPrimitivesLib.set(key + 1, 0);
    }

    /// @notice Called on the L1 when a withdrawal from the chain happens, or when a failed deposit is undone.
    /// @dev As the chain does not update its balance when settling on L1.
    function handleChainBalanceDecreaseOnL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 // _tokenOriginChainId
    ) external onlyNativeTokenVault {
        uint256 chainToUpdate = _getWithdrawalChain(_chainId);

        _decreaseChainBalance(chainToUpdate, _assetId, _amount);
        chainBalance[block.chainid][_assetId] += _amount;
    }

    /// @notice Determines which chain's balance should be updated for a withdrawal operation.
    /// @dev This function handles the complex logic around V31 upgrade transitions and settlement layer changes.
    /// @dev The key insight is that before V31, withdrawals affected the chain's own balance, but after V31,
    /// @dev withdrawals from Gateway-settled chains affect the Gateway's balance instead.
    /// @param _chainId The ID of the chain from which the withdrawal is being processed.
    /// @return chainToUpdate The chain ID whose balance should be decremented for this withdrawal.
    function _getWithdrawalChain(uint256 _chainId) internal view returns (uint256 chainToUpdate) {
        (uint256 settlementLayer, uint256 l2BatchNumber) = L1_NULLIFIER.getTransientSettlementLayer();
        // This is the batch starting from which it is the responsibility of all the settlement layers to ensure that
        // all withdrawals coming from the chain are backed by the balance of this settlement layer.
        // Note, that since this method is used for claiming failed deposits, it implies that any failed deposit that has been processed
        // while the chain settled on top of Gateway, has been accredited to Gateway's balance.
        // For all the batches smaller or equal to that, the responsibility lies with the chain itself.
        uint256 v31UpgradeChainBatchNumber = IL1MessageRoot(address(MESSAGE_ROOT)).v31UpgradeChainBatchNumber(_chainId);

        // We need to wait for the proper v31UpgradeChainBatchNumber to be set on the MessageRoot, otherwise we might decrement the chain's chainBalance instead of the gateway's.
        require(
            v31UpgradeChainBatchNumber != V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY,
            V31UpgradeChainBatchNumberNotSet()
        );
        if (v31UpgradeChainBatchNumber != 0) {
            /// For chains that were settling on GW before V31, we need to update the chain's chainBalance until the chain updates to V31.
            /// Logic: If no settlement layer OR the batch number is before V31 upgrade, update the chain itself.
            /// Otherwise, update the settlement layer (Gateway) balance.
            chainToUpdate = settlementLayer == 0 || l2BatchNumber < v31UpgradeChainBatchNumber
                ? _chainId
                : settlementLayer;
        } else {
            /// For chains deployed at V31 or later, the logic is simpler:
            /// Update the chain balance if settling on L1, otherwise update the settlement layer balance.
            chainToUpdate = settlementLayer == 0 ? _chainId : settlementLayer;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration 
    //////////////////////////////////////////////////////////////*/

    /// @notice This function receives the migration from the L2 or the Gateway.
    /// @dev It sends the corresponding L1->L2 messages to the L2 and the Gateway.
    /// @dev Note, that a chain can potentially be malicious and lie about the `amount` field in the
    /// `TokenBalanceMigrationData`. The assetId is validated against the provided token data to prevent
    /// manipulation. This method is intended to ensure that a chain can tell
    /// how much of the token balance it has on L1 pending from previous withdrawals and how much is active,
    /// i.e. the `amount` field in the `TokenBalanceMigrationData` and may be used by interop.
    /// If the chain downplays `amount`, it will restrict its users from additional interop,
    /// while if it overstates `amount`, it should be able to affect past withdrawals of the chain only.
    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);

        (bytes4 functionSignature, TokenBalanceMigrationData memory data) = DataEncoding
            .decodeTokenBalanceMigrationData(_finalizeWithdrawalParams.message);
        require(
            functionSignature == IAssetTrackerDataEncoding.receiveMigrationOnL1.selector,
            InvalidFunctionSignature(functionSignature)
        );
        require(data.version == TOKEN_BALANCE_MIGRATION_DATA_VERSION, InvalidVersion());
        require(
            assetMigrationNumber[data.chainId][data.assetId] < data.chainMigrationNumber,
            InvalidAssetMigrationNumber()
        );

        uint256 currentSettlementLayer = BRIDGE_HUB.settlementLayer(data.chainId);
        uint256 fromChainId;
        uint256 toChainId;

        // We check the assetId to make sure the chain is not lying about it.
        DataEncoding.assetIdCheck(data.tokenOriginChainId, data.assetId, data.originToken);

        if (data.isL1ToGateway) {
            uint256 chainMigrationNumber = _getChainMigrationNumber(data.chainId);
            // We check the chainMigrationNumber to make sure the message is not from a previous token migration.
            // What can happen in theory is the following:
            // - Chain starts migration to Gateway (has chainMigrationNumber = n)
            // - Migration fails, then chain restores itself on L1 (has chainMigrationNumber = n - 1)
            // - Chain starts migration to Gateway again (has chainMigrationNumber = n)
            // In this case there are two valid migrations with the same chainMigrationNumber.
            // This affects only malicious chains, since a normal chain is not expected to send such a message
            // when on L1. In the worst case only this chain is affected.
            require(
                chainMigrationNumber == data.chainMigrationNumber,
                InvalidChainMigrationNumber(chainMigrationNumber, data.chainMigrationNumber)
            );

            // The TokenBalanceMigrationData data might be malicious.
            // We check the chainId to match the finalizeWithdrawalParams.chainId.
            // The amount might be malicious, but that poses a restriction on users of the chain, not other chains.
            // The AssetTracker cannot protect individual users only other chains. Individual users rely on the proof system.
            // The last field is migrationNumber, which cannot be abused due to the check above.
            require(currentSettlementLayer != block.chainid, NotMigratedChain());
            require(data.chainId == _finalizeWithdrawalParams.chainId, InvalidWithdrawalChainId());

            // We check parity here to make sure that we migrated the token balance back to L1 from Gateway.
            // This is needed to ensure that the chainBalance on the Gateway AssetTracker is currently 0.
            // In the future we might initialize chains on GW. So we subtract from chainMigrationNumber.
            // Note, that this logic only works well when only a single ZK Gateway can be used as a settlement layer
            // for an individual chain as well as the fact that chains can only migrate once on top of Gateway.
            // Since `currentSettlementLayer != block.chainid` is checked above, it implies that the current
            // `data.chainMigrationNumber` is odd and so after this migration is processed once, it will not be able to be reprocessed,
            // due to `assetMigrationNumber` being assigned later.
            require(
                (assetMigrationNumber[data.chainId][data.assetId]) % 2 == 0,
                InvalidMigrationNumber(chainMigrationNumber, assetMigrationNumber[data.chainId][data.assetId])
            );

            fromChainId = data.chainId;
            toChainId = currentSettlementLayer;
        } else {
            // In this case we trust the TokenBalanceMigrationData data and the settlement layer = Gateway to be honest.
            require(
                BRIDGE_HUB.whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
                InvalidWithdrawalChainId()
            );
            // The assetMigrationNumber on GW is set via forceSetAssetMigrationNumber to the chainMigrationNumber
            // which asset migration number + 1 or it is set by confirmMigrationOnL2 to the actual asset migration number.
            // This line also serves for replay protection as later the assetMigrationNumber is set to the chainMigrationNumber.
            // We assume that data.chainMigrationNumber is > data.assetMigrationNumber.
            uint256 readAssetMigrationNumber = assetMigrationNumber[data.chainId][data.assetId];
            require(
                readAssetMigrationNumber == data.assetMigrationNumber ||
                    readAssetMigrationNumber + 1 == data.assetMigrationNumber,
                InvalidAssetMigrationNumber()
            );

            // Note, that here, unlike the case above, we do not enforce the `chainMigrationNumber`, since
            // we always allow to finalize previous withdrawals.

            fromChainId = _finalizeWithdrawalParams.chainId;
            toChainId = data.chainId;
        }

        _assignMaxChainBalanceIfNeeded(data.tokenOriginChainId, data.assetId);
        _migrateFunds({_fromChainId: fromChainId, _toChainId: toChainId, _assetId: data.assetId, _amount: data.amount});

        assetMigrationNumber[data.chainId][data.assetId] = data.chainMigrationNumber;

        TokenBalanceMigrationData memory tokenBalanceMigrationData = data;
        tokenBalanceMigrationData.assetMigrationNumber = data.chainMigrationNumber;
        tokenBalanceMigrationData.chainMigrationNumber = 0;

        _sendConfirmationToChains(
            data.isL1ToGateway ? currentSettlementLayer : _finalizeWithdrawalParams.chainId,
            tokenBalanceMigrationData
        );
    }

    /// @notice used to pause deposits on Gateway from L1 for migration back to L1.
    function requestPauseDepositsForChainOnGateway(uint256 _chainId) external onlyChain(_chainId) {
        uint256 settlementLayer = BRIDGE_HUB.settlementLayer(_chainId);
        require(settlementLayer != 0, InvalidSettlementLayer());
        _sendToChain(
            settlementLayer,
            GW_ASSET_TRACKER_ADDR,
            abi.encodeCall(IGWAssetTracker.requestPauseDepositsForChain, (_chainId))
        );
        emit IL1AssetTracker.PauseDepositsForChainRequested(_chainId, settlementLayer);
    }

    function _sendConfirmationToChains(
        uint256 _settlementLayerChainId,
        TokenBalanceMigrationData memory _tokenBalanceMigrationData
    ) internal {
        // We send the confirmMigrationOnGateway first, so that withdrawals are definitely paused until the migration is confirmed on GW.
        // Note: the confirmMigrationOnL2 is a L1->GW->L2 txs if the chain is settling on Gateway.
        _sendToChain(
            _settlementLayerChainId,
            GW_ASSET_TRACKER_ADDR,
            abi.encodeCall(IGWAssetTracker.confirmMigrationOnGateway, (_tokenBalanceMigrationData))
        );
        _sendToChain(
            _tokenBalanceMigrationData.chainId,
            L2_ASSET_TRACKER_ADDR,
            abi.encodeCall(IL2AssetTracker.confirmMigrationOnL2, (_tokenBalanceMigrationData))
        );
    }

    /// @notice Migrates token balance from one chain to another by updating chainBalance mappings.
    /// @dev This is an internal accounting function that moves balance between chains without actual token transfers.
    /// @param _fromChainId The chain ID from which to decrease the balance.
    /// @param _toChainId The chain ID to which to increase the balance.
    /// @param _assetId The asset ID of the token being migrated.
    /// @param _amount The amount of tokens to migrate.
    function _migrateFunds(uint256 _fromChainId, uint256 _toChainId, bytes32 _assetId, uint256 _amount) internal {
        _decreaseChainBalance(_fromChainId, _assetId, _amount);
        chainBalance[_toChainId][_assetId] += _amount;
    }

    /// @notice Sends a transaction to a specific chain through its mailbox.
    /// @dev This is a helper function that resolves the chain address and sends an L2 service transaction.
    /// @param _chainId The target chain ID to send the transaction to.
    /// @param _to The address of the contract to call on the target chain.
    /// @param _data The encoded function call data to send.
    function _sendToChain(uint256 _chainId, address _to, bytes memory _data) internal {
        address zkChain = BRIDGE_HUB.getZKChain(_chainId);
        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(_to, _data);
    }

    /// @notice Verifies that a message was properly included in the L2->L1 message system.
    /// @param _finalizeWithdrawalParams The parameters containing the message and its inclusion proof.
    function _proveMessageInclusion(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) internal view {
        require(
            _finalizeWithdrawalParams.l2Sender == L2_ASSET_TRACKER_ADDR ||
                _finalizeWithdrawalParams.l2Sender == GW_ASSET_TRACKER_ADDR,
            InvalidSender()
        );
        bool success = MESSAGE_ROOT.proveL1DepositParamsInclusion(_finalizeWithdrawalParams);
        if (!success) {
            revert InvalidProof();
        }
    }

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return chainAssetHandler.migrationNumber(_chainId);
    }
}
