// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {GatewayToL1TokenBalanceMigrationData, L1ToGatewayTokenBalanceMigrationData, MigrationConfirmationData} from "../../common/Messaging.sol";
import {GW_ASSET_TRACKER_ADDR, L2_ASSET_TRACKER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {InvalidProof, ZeroAddress, InvalidChainId, Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRootBase, V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE} from "../../core/message-root/IMessageRoot.sol";
import {IBridgehubBase} from "../../core/bridgehub/IBridgehubBase.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "../../bridge/interfaces/IL1Nullifier.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";

import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {AmountToKeepOnL1NotUint256, AssetIdNotRegistered, AssetNotMigratedFromNTV, InvalidAssetMigrationNumber, InvalidChainMigrationNumber, InvalidMigrationAmount, InvalidMigrationNumber, InvalidSender, InvalidSettlementLayer, InvalidVersion, InvalidWithdrawalChainId, MaxChainBalanceAlreadyAssigned, NotMigratedChain, OnlyWhitelistedSettlementLayer, TransientBalanceChangeAlreadySet} from "./AssetTrackerErrors.sol";
import {V31UpgradeChainBatchNumberNotSet} from "../../core/bridgehub/L1BridgehubErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {MAX_TOKEN_BALANCE, TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "./IAssetTrackerBase.sol";
import {IGWAssetTracker} from "./IGWAssetTracker.sol";
import {IL1AssetTracker} from "./IL1AssetTracker.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IChainAssetHandlerBase} from "../../core/chain-asset-handler/IChainAssetHandler.sol";
import {IL1MessageRoot} from "../../core/message-root/IL1MessageRoot.sol";
import {MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1} from "../../common/Config.sol";

contract L1AssetTracker is AssetTrackerBase, IL1AssetTracker {
    IBridgehubBase public immutable BRIDGE_HUB;

    INativeTokenVaultBase public immutable NATIVE_TOKEN_VAULT;

    IMessageRootBase public immutable MESSAGE_ROOT;

    IL1Nullifier public immutable L1_NULLIFIER;

    IChainAssetHandlerBase public chainAssetHandler;

    mapping(uint256 chainId => mapping(bytes32 assetId => InteropL1Info info)) internal interopInfo;

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
        MESSAGE_ROOT = IMessageRootBase(_messageRoot);
        L1_NULLIFIER = IL1Nullifier(IL1NativeTokenVault(_nativeTokenVault).L1_NULLIFIER());
    }

    function initialize(address _owner) external reentrancyGuardInitializer initializer {
        require(_owner != address(0), ZeroAddress());
        _transferOwnership(_owner);
    }

    function setAddresses() external onlyOwner {
        chainAssetHandler = IChainAssetHandlerBase(BRIDGE_HUB.chainAssetHandler());
    }

    function _requireRegistered(bytes32 _assetId) internal {
        if (!isAssetRegistered[_assetId]) {
            revert AssetIdNotRegistered(_assetId);
        }
    }

    /// @notice This function is used to migrate the token balance from the NTV to the AssetTracker for V31 upgrade.
    /// @dev The only way to register a legacy token.
    /// @dev Note, that this function performs O(number of chains) calls to NTV. It relies on the fact
    /// that the max number of chains is bound by 100, so this function should be always processable.
    /// @dev We need to migrate the balance for every single chain first to ensure that the `preV31ChainBalance`
    /// is set correctly for the origin chain.
    /// @param _assetId The asset id of the token to migrate the token balance for.
    function registerLegacyToken(bytes32 _assetId) public {
        IL1NativeTokenVault l1NTV = IL1NativeTokenVault(address(NATIVE_TOKEN_VAULT));
        uint256 originChainId = NATIVE_TOKEN_VAULT.originChainId(_assetId);
        require(originChainId != 0, InvalidChainId());

        // This function is only intended to be used for legacy tokens that have not yet been registered.
        if (isAssetRegistered[_assetId]) {
            revert MaxChainBalanceAlreadyAssigned(_assetId);
        }

        uint256[] memory allZKChainIds = BRIDGE_HUB.getAllZKChainChainIDs();
        uint256 allZKChainIdsLength = allZKChainIds.length;

        uint256 totalBridgedOut = 0;

        for (uint256 i = 0; i < allZKChainIdsLength; ++i) {
            uint256 chainId = allZKChainIds[i];
            // This require should never be triggered in production, it is an invariant check
            // chainBalance inside the L1AT should never be incremented until the token is registered.
            if (chainBalance[chainId][_assetId] != 0) {
                revert MaxChainBalanceAlreadyAssigned(_assetId);
            }

            // Origin chain id will be handled later in this function.
            if (chainId == originChainId) {
                continue;
            }

            // slither-disable-next-line reentrancy-eth,reentrancy-no-eth
            uint256 migratedBalance = l1NTV.migrateTokenBalanceToAssetTracker(chainId, _assetId);

            chainBalance[chainId][_assetId] = migratedBalance;
            interopInfo[chainId][_assetId].preV31ChainBalance = migratedBalance;
            totalBridgedOut += migratedBalance;
        }
        // Similar to the above, it is just an invariant check that should never be hit
        if (chainBalance[block.chainid][_assetId] != 0) {
            revert MaxChainBalanceAlreadyAssigned(_assetId);
        }

        // The token is not native to L1, so we also have to account for the amount bridged to L1.
        if (originChainId != block.chainid) {
            address tokenAddress = NATIVE_TOKEN_VAULT.tokenAddress(_assetId);
            // Note, that here we have an implicit invariant that the token's total supply
            // can never be changed before this migration happens. So until a token is registered, all withdrawals must fail.
            // Note, that if a token is a bridged token native to L2, its representation on L1
            // is deployed by NativeTokenVault as `BridgedStandardERC20`, so we can safely assume the returned value
            // will be correct.
            uint256 migratedBalance = IERC20(tokenAddress).totalSupply();
            chainBalance[block.chainid][_assetId] = migratedBalance;
            interopInfo[block.chainid][_assetId].preV31ChainBalance = migratedBalance;
            totalBridgedOut += migratedBalance;
        }

        chainBalance[originChainId][_assetId] = MAX_TOKEN_BALANCE - totalBridgedOut;
        interopInfo[originChainId][_assetId].preV31ChainBalance = MAX_TOKEN_BALANCE - totalBridgedOut;
        isAssetRegistered[_assetId] = true;
    }

    /// @inheritdoc AssetTrackerBase
    function registerNewToken(bytes32 _assetId, uint256 _originChainId) public override onlyNativeTokenVault {
        _registerNewTokenInner(_originChainId, _assetId);
    }

    function _registerNewTokenInner(uint256 _originChainId, bytes32 _assetId) internal {
        if (isAssetRegistered[_assetId]) {
            return;
        }

        isAssetRegistered[_assetId] = true;
        chainBalance[_originChainId][_assetId] = MAX_TOKEN_BALANCE;
        // For any new native token, we treat `preV31ChainBalance` as if at the moment of the inception
        // there was an infinite deposit to the chain.
        interopInfo[_originChainId][_assetId].preV31ChainBalance = MAX_TOKEN_BALANCE;
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
        _requireRegistered(_assetId);
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
        } else {
            interopInfo[_chainId][_assetId].totalDepositedFromL1 += _amount;
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
        uint256 _amount
    ) external onlyNativeTokenVault {
        uint256 chainToUpdate = _getWithdrawalChain(_chainId);
        _requireRegistered(_assetId);

        if (chainToUpdate == _chainId) {
            interopInfo[_chainId][_assetId].totalClaimedOnL1 += _amount;
        }

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
            v31UpgradeChainBatchNumber != V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE,
            V31UpgradeChainBatchNumberNotSet()
        );

        /// For chains that were settling on GW before V31, we need to update the chain's chainBalance until the chain updates to V31.
        /// Logic: If no settlement layer OR the batch number is before V31 upgrade, update the chain itself.
        /// Otherwise, update the settlement layer (Gateway) balance.
        chainToUpdate = settlementLayer == 0 || l2BatchNumber < v31UpgradeChainBatchNumber ? _chainId : settlementLayer;
    }

    /// @notice This function is used to register tokens that are only deployed on L2.
    /// @dev This is needed e.g. to enable interop for a token native to the chain that has never
    /// been withdrawn to L1.
    function _autoRegisterTokenFromMigration(uint256 _originChainId, bytes32 _assetId) internal {
        // Firstly, we need to check whether we have already registered the token
        if (isAssetRegistered[_assetId]) {
            return;
        }

        // Token has never been registered, but there are two cases here:
        // - The token existed prior to v31 and we simply did not migrate its balance from NTV.
        // - The token is indeed bridged from L2 for the first time.
        // We distinguish the cases above by querying NTV.

        address tokenAddress = NATIVE_TOKEN_VAULT.tokenAddress(_assetId);

        if (tokenAddress != address(0)) {
            revert AssetNotMigratedFromNTV(_assetId);
        }

        _registerNewTokenInner(_originChainId, _assetId);
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalizes a token migration from L1 to Gateway.
    /// @param _finalizeWithdrawalParams Message inclusion proof parameters.
    function receiveL1ToGatewayMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);

        // slither-disable-next-line unused-return
        (, L1ToGatewayTokenBalanceMigrationData memory data) = DataEncoding.decodeL1ToGatewayTokenBalanceMigrationData(
            _finalizeWithdrawalParams.message
        );
        require(data.version == TOKEN_BALANCE_MIGRATION_DATA_VERSION, InvalidVersion());
        require(
            assetMigrationNumber[data.chainId][data.assetId] < data.chainMigrationNumber,
            InvalidAssetMigrationNumber()
        );

        // We check the assetId to make sure the chain is not lying about it.
        DataEncoding.assetIdCheck(data.tokenOriginChainId, data.assetId, data.originToken);
        _autoRegisterTokenFromMigration(data.tokenOriginChainId, data.assetId);

        uint256 currentSettlementLayer = BRIDGE_HUB.settlementLayer(data.chainId);
        require(currentSettlementLayer != block.chainid, NotMigratedChain());
        require(data.chainId == _finalizeWithdrawalParams.chainId, InvalidWithdrawalChainId());

        uint256 chainMigrationNumber = _getChainMigrationNumber(data.chainId);
        require(
            chainMigrationNumber == data.chainMigrationNumber,
            InvalidChainMigrationNumber(chainMigrationNumber, data.chainMigrationNumber)
        );

        // We check parity here to make sure that we migrated the token balance back to L1 from Gateway.
        require(
            (assetMigrationNumber[data.chainId][data.assetId]) % 2 == 0,
            InvalidMigrationNumber(chainMigrationNumber, assetMigrationNumber[data.chainId][data.assetId])
        );

        uint256 amountToKeep = _toKeepDuringL1ToGWMigration({
            _chainId: data.chainId,
            _assetId: data.assetId,
            _totalWithdrawalsToL1: data.totalWithdrawalsToL1,
            _totalSuccessfulDepositsFromL1: data.totalSuccessfulDepositsFromL1,
            _totalPreV31TotalSupply: data.totalPreV31TotalSupply
        });
        uint256 fromChainBalance = chainBalance[data.chainId][data.assetId];
        require(fromChainBalance >= amountToKeep, InvalidMigrationAmount(fromChainBalance, amountToKeep));
        uint256 amountToMigrate = fromChainBalance - amountToKeep;

        _migrateFunds({
            _fromChainId: data.chainId,
            _toChainId: currentSettlementLayer,
            _assetId: data.assetId,
            _amount: amountToMigrate
        });

        assetMigrationNumber[data.chainId][data.assetId] = data.chainMigrationNumber;

        MigrationConfirmationData memory migrationConfirmationData = MigrationConfirmationData({
            chainId: data.chainId,
            assetId: data.assetId,
            tokenOriginChainId: data.tokenOriginChainId,
            originToken: data.originToken,
            amount: amountToMigrate,
            assetMigrationNumber: data.chainMigrationNumber,
            isL1ToGateway: true
        });

        _sendConfirmationToChains(currentSettlementLayer, migrationConfirmationData);
    }

    /// @notice Finalizes a token migration from Gateway to L1.
    /// @param _finalizeWithdrawalParams Message inclusion proof parameters.
    function receiveGatewayToL1MigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);

        // slither-disable-next-line unused-return
        (, GatewayToL1TokenBalanceMigrationData memory data) = DataEncoding.decodeGatewayToL1TokenBalanceMigrationData(
            _finalizeWithdrawalParams.message
        );
        require(data.version == TOKEN_BALANCE_MIGRATION_DATA_VERSION, InvalidVersion());
        require(
            assetMigrationNumber[data.chainId][data.assetId] < data.chainMigrationNumber,
            InvalidAssetMigrationNumber()
        );

        DataEncoding.assetIdCheck(data.tokenOriginChainId, data.assetId, data.originToken);

        // Such messages are only allowed has settled on Gateway and returned back.
        uint256 chainMigrationNumber = _getChainMigrationNumber(data.chainId);
        require(
            chainMigrationNumber == MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1,
            InvalidChainMigrationNumber(chainMigrationNumber, MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1)
        );
        require(
            data.chainMigrationNumber == chainMigrationNumber,
            InvalidChainMigrationNumber(chainMigrationNumber, data.chainMigrationNumber)
        );

        // It is expected that before a chain gets any balance of a token on GW, it is registered on L1AssetTracker.
        // This requirement should never be violated in production, it is an invariant check.
        _requireRegistered(data.assetId);

        // We only allow whitelisted settlement layers' messages to be processed by this function, since
        // it updates various chain-related parameters such as assetMigrationNumber.
        // It does mean that if a past settlement layer does not have this status anymore, such messages
        // wont be processable. This limitation will be fixed in the future releases.
        require(BRIDGE_HUB.whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId), InvalidWithdrawalChainId());

        // `assetMigrationNumber` can be either 0 or 1 (didnt migrate the balance to GW or did migrate).
        // `data.assetMigrationNumber` should be also either 0 or 1.
        // This check does not serve a specific purpose, it is an invariant check.
        uint256 readAssetMigrationNumber = assetMigrationNumber[data.chainId][data.assetId];
        require(
            readAssetMigrationNumber == data.assetMigrationNumber ||
                readAssetMigrationNumber + 1 == data.assetMigrationNumber,
            InvalidAssetMigrationNumber()
        );

        _migrateFunds({
            _fromChainId: _finalizeWithdrawalParams.chainId,
            _toChainId: data.chainId,
            _assetId: data.assetId,
            _amount: data.amount
        });

        assetMigrationNumber[data.chainId][data.assetId] = chainMigrationNumber;

        MigrationConfirmationData memory migrationConfirmationData = MigrationConfirmationData({
            chainId: data.chainId,
            assetId: data.assetId,
            tokenOriginChainId: data.tokenOriginChainId,
            originToken: data.originToken,
            amount: data.amount,
            assetMigrationNumber: chainMigrationNumber,
            isL1ToGateway: false
        });

        _sendConfirmationToChains(_finalizeWithdrawalParams.chainId, migrationConfirmationData);
    }

    /// @notice used to pause deposits on Gateway from L1 for migration back to L1.
    function requestPauseDepositsForChainOnGateway(uint256 _chainId) external onlyChain(_chainId) {
        uint256 settlementLayer = BRIDGE_HUB.settlementLayer(_chainId);
        require(settlementLayer != block.chainid, InvalidSettlementLayer());
        _sendToChain(
            settlementLayer,
            GW_ASSET_TRACKER_ADDR,
            abi.encodeCall(IGWAssetTracker.requestPauseDepositsForChain, (_chainId))
        );
        emit IL1AssetTracker.PauseDepositsForChainRequested(_chainId, settlementLayer);
    }

    function _sendConfirmationToChains(
        uint256 _settlementLayerChainId,
        MigrationConfirmationData memory _migrationConfirmationData
    ) internal {
        // We send the confirmMigrationOnGateway first, so that withdrawals are definitely paused until the migration is confirmed on GW.
        // Note: confirmMigrationOnL2 is a L1->GW->L2 tx if the chain is settling on Gateway.
        _sendToChain(
            _settlementLayerChainId,
            GW_ASSET_TRACKER_ADDR,
            abi.encodeCall(IGWAssetTracker.confirmMigrationOnGateway, (_migrationConfirmationData))
        );
        _sendToChain(
            _migrationConfirmationData.chainId,
            L2_ASSET_TRACKER_ADDR,
            abi.encodeCall(IL2AssetTracker.confirmMigrationOnL2, (_migrationConfirmationData))
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

    /// @notice Computes how much balance must remain on L1 when moving accounting to Gateway.
    /// @dev Conceptually it should cover the finalization of all outstanding withdrawals or claimed failed deposits
    /// *that would reduce the chainBalance of the chain*. One could say it is `totalWithdrawalsToL1 + totalFailedDepositsFromL1 - totalClaimed`.
    /// Note, both `totalWithdrawalsToL1` and `totalFailedDepositsFromL1` must only refer to messages that happened when the chain
    /// settled on L1, while `totalClaimed` should only include claims for such withdrawlas/failed deposits.
    /// We calculate `totalFailedDepositsFromL1` as the difference between the total deposits for when the chain settled on L1 and the total successful
    /// deposits from the same period. All in all, we get the following formula:
    /// `amountToKeep = totalWithdrawalsToL1 + (totalDepositedFromL1 - totalSuccessfulDepositsFromL1) - totalClaimedOnL1`.
    /// For some of the older tokens, we did not track neither of the values above, so when the token is registered inside this contract, we remember
    /// its pre-v31 chain balance, which is equal to `totalDepositedFromL1BeforeV31 - totalClaimedOnL1BeforeV31`.
    /// For similar reasons the chain should return its pre-v31 totalSupply on L2, which is equal to `totalSuccessfulDepositsFromL1 - totalWithdrawalsToL1`.
    /// All-in-all, we get the following formula:
    /// `amountToKeep = preV31ChainBalance + totalWithdrawalsToL1 + (totalDepositedFromL1 - totalSuccessfulDepositsFromL1) - totalClaimedOnL1 - _totalPreV31TotalSupply`
    /// @param _chainId Chain id being migrated.
    /// @param _assetId Asset id being migrated.
    /// @param _totalWithdrawalsToL1 Total withdrawals tracked on L2 since v31 accounting started.
    /// @param _totalSuccessfulDepositsFromL1 Total successful deposits tracked on L2 since v31 accounting started.
    /// @param _totalPreV31TotalSupply Token total supply snapshot captured on L2 before first post-v31 bridge action.
    /// @return amountToKeep The amount that must stay on L1.
    function _toKeepDuringL1ToGWMigration(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _totalWithdrawalsToL1,
        uint256 _totalSuccessfulDepositsFromL1,
        uint256 _totalPreV31TotalSupply
    ) internal view returns (uint256 amountToKeep) {
        InteropL1Info memory info = interopInfo[_chainId][_assetId];

        // The numbers in question are large especially for native tokens as their
        // preV31ChainBalance and _totalPreV31TotalSupply are very close to 2^256-1, so
        // we need to work around overflows.
        // It is expected however, that the resulting value is within the valid range for 2^256-1.

        uint256 wraps = 0;
        unchecked {
            amountToKeep = info.preV31ChainBalance + _totalWithdrawalsToL1;
            // Overflow => went above 2^256-1.
            if (amountToKeep < info.preV31ChainBalance) {
                ++wraps;
            }

            amountToKeep += info.totalDepositedFromL1;

            // Overflow => went above 2^256-1.
            if (amountToKeep < info.totalDepositedFromL1) {
                ++wraps;
            }

            amountToKeep -= _totalSuccessfulDepositsFromL1;
            // Underflow => went below 0.
            if (amountToKeep > type(uint256).max - _totalSuccessfulDepositsFromL1) {
                --wraps;
            }

            amountToKeep -= info.totalClaimedOnL1;
            // Underflow => went below 0.
            if (amountToKeep > type(uint256).max - info.totalClaimedOnL1) {
                --wraps;
            }

            amountToKeep -= _totalPreV31TotalSupply;
            // Underflow => went below 0.
            if (amountToKeep > type(uint256).max - _totalPreV31TotalSupply) {
                --wraps;
            }
        }

        require(wraps == 0, AmountToKeepOnL1NotUint256());
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
