// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {ConfirmBalanceMigrationData, TokenBalanceMigrationData} from "../../common/Messaging.sol";
import {GW_ASSET_TRACKER_ADDR, L2_ASSET_TRACKER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVaultBase} from "../ntv/INativeTokenVaultBase.sol";
import {InvalidProof, ZeroAddress, InvalidChainId, Unauthorized} from "../../common/L1ContractErrors.sol";
import {IMessageRoot, V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY} from "../../bridgehub/IMessageRoot.sol";
import {IBridgehubBase} from "../../bridgehub/IBridgehubBase.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "../../bridge/interfaces/IL1Nullifier.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";

import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {InvalidChainMigrationNumber, InvalidFunctionSignature, InvalidMigrationNumber, InvalidSender, InvalidWithdrawalChainId, NotMigratedChain, OnlyWhitelistedSettlementLayer, TransientBalanceChangeAlreadySet, InvalidVersion, L1TotalSupplyAlreadyMigrated, MaxChainBalanceAlreadyAssigned} from "./AssetTrackerErrors.sol";
import {V30UpgradeChainBatchNumberNotSet} from "../../bridgehub/L1BridgehubErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {MAX_TOKEN_BALANCE, TOKEN_BALANCE_MIGRATION_DATA_VERSION} from "./IAssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IGWAssetTracker} from "./IGWAssetTracker.sol";
import {IL1AssetTracker} from "./IL1AssetTracker.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IChainAssetHandler} from "../../bridgehub/IChainAssetHandler.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";

contract L1AssetTracker is AssetTrackerBase, IL1AssetTracker {
    uint256 public immutable L1_CHAIN_ID;

    IBridgehubBase public immutable BRIDGE_HUB;

    INativeTokenVaultBase public immutable NATIVE_TOKEN_VAULT;

    IMessageRoot public immutable MESSAGE_ROOT;

    IL1Nullifier public immutable L1_NULLIFIER;

    IChainAssetHandler public chainAssetHandler;

    /// Todo Deprecate after V30 is finished.
    mapping(bytes32 assetId => bool l1TotalSupplyMigrated) internal l1TotalSupplyMigrated;

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view override returns (IBridgehubBase) {
        return BRIDGE_HUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVaultBase) {
        return NATIVE_TOKEN_VAULT;
    }

    function _messageRoot() internal view override returns (IMessageRoot) {
        return MESSAGE_ROOT;
    }

    modifier onlyWhitelistedSettlementLayer(uint256 _callerChainId) {
        require(
            _bridgehub().whitelistedSettlementLayers(_callerChainId) &&
                _bridgehub().getZKChain(_callerChainId) == msg.sender,
            OnlyWhitelistedSettlementLayer(_bridgehub().getZKChain(_callerChainId), msg.sender)
        );
        _;
    }

    /// @notice Modifier to ensure the caller is the administrator of the specified chain.
    /// @param _chainId The ID of the chain that requires the caller to be an admin.
    modifier onlyChainAdmin(uint256 _chainId) {
        IChainTypeManager ctm = IChainTypeManager(BRIDGE_HUB.chainTypeManager(_chainId));
        if (msg.sender != ctm.getChainAdmin(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                    Initialization
    //////////////////////////////////////////////////////////////*/

    constructor(
        uint256 _l1ChainId,
        address _bridgehub,
        address,
        address _nativeTokenVault,
        address _messageRoot
    ) reentrancyGuardInitializer {
        _disableInitializers();

        L1_CHAIN_ID = _l1ChainId;
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

    /// @notice This function is used to migrate the token balance from the NTV to the AssetTracker for V30 upgrade.
    /// @param _chainId The chain id of the chain to migrate the token balance for.
    /// @param _assetId The asset id of the token to migrate the token balance for.
    function migrateTokenBalanceFromNTVV30(uint256 _chainId, bytes32 _assetId) external {
        IL1NativeTokenVault l1NTV = IL1NativeTokenVault(address(NATIVE_TOKEN_VAULT));
        uint256 originChainId = NATIVE_TOKEN_VAULT.originChainId(_assetId);
        /// We do not migrate the chainBalance for the originChain directly, but indirectly by subtracting from MAX_TOKEN_BALANCE.
        /// Its important to call this for all chains in the ecosystem so that the sum is accurate.
        require(_chainId != originChainId, InvalidChainId());
        uint256 migratedBalance;
        if (_chainId != block.chainid) {
            migratedBalance = l1NTV.migrateTokenBalanceToAssetTracker(_chainId, _assetId);
        } else {
            address tokenAddress = NATIVE_TOKEN_VAULT.tokenAddress(_assetId);
            migratedBalance = IERC20(tokenAddress).totalSupply();
            require(!l1TotalSupplyMigrated[_assetId], L1TotalSupplyAlreadyMigrated());
            l1TotalSupplyMigrated[_assetId] = true;
        }
        /// Note it might be the case that the tokenOriginChainId and the specified _chainId are both L1,
        /// in this case the chainBalance[L1_CHAIN_ID][_assetId] is set to uint256.max if it was not already.
        /// Note before the token is migrated the MAX_TOKEN_BALANCE is not assigned, since the registerNewToken is only called for new tokens.
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

    function _assignMaxChainBalanceRequireNotAssigned(uint256 _originChainId, bytes32 _assetId) internal {
        require(!maxChainBalanceAssigned[_assetId], MaxChainBalanceAlreadyAssigned(_assetId));
        _assignMaxChainBalance(_originChainId, _assetId);
    }

    function _assignMaxChainBalance(uint256 _originChainId, bytes32 _assetId) internal override {
        chainBalance[_originChainId][_assetId] = MAX_TOKEN_BALANCE;
        maxChainBalanceAssigned[_assetId] = true;
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
        uint256 currentSettlementLayer = _bridgehub().settlementLayer(_chainId);
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

    function _getWithdrawalChain(uint256 _chainId) internal view returns (uint256 chainToUpdate) {
        (uint256 settlementLayer, uint256 l2BatchNumber) = L1_NULLIFIER.getTransientSettlementLayer();
        uint256 v30UpgradeChainBatchNumber = MESSAGE_ROOT.v30UpgradeChainBatchNumber(_chainId);
        /// We need to wait for the proper v30UpgradeChainBatchNumber to be set on the MessageRoot, otherwise we might decrement the chain's chainBalance instead of the gateway's.
        require(
            v30UpgradeChainBatchNumber != V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY,
            V30UpgradeChainBatchNumberNotSet()
        );
        if (v30UpgradeChainBatchNumber != 0) {
            /// For chains that were settling on GW before V30, we need to update the chain's chainBalance until the chain updates to V30.
            chainToUpdate = settlementLayer == 0 || l2BatchNumber < v30UpgradeChainBatchNumber
                ? _chainId
                : settlementLayer;
        } else {
            chainToUpdate = settlementLayer == 0 ? _chainId : settlementLayer;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration 
    //////////////////////////////////////////////////////////////*/

    /// @notice This function receives the migration from the L2 or the Gateway.
    /// @dev It sends the corresponding L1->L2 messages to the L2 and the Gateway.
    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);

        (bytes4 functionSignature, TokenBalanceMigrationData memory data) = DataEncoding
            .decodeTokenBalanceMigrationData(_finalizeWithdrawalParams.message);
        require(
            functionSignature == IAssetTrackerDataEncoding.receiveMigrationOnL1.selector,
            InvalidFunctionSignature(functionSignature)
        );
        require(data.version == TOKEN_BALANCE_MIGRATION_DATA_VERSION, InvalidVersion());

        uint256 currentSettlementLayer = _bridgehub().settlementLayer(data.chainId);
        uint256 fromChainId;
        uint256 toChainId;

        /// We check the assetId to make sure the chain is not lying about it.
        DataEncoding.assetIdCheck(data.tokenOriginChainId, data.assetId, data.originToken);

        if (data.isL1ToGateway) {
            uint256 chainMigrationNumber = _getChainMigrationNumber(data.chainId);
            /// We check the chainMigrationNumber to make sure the message is not from a previous token migration.
            require(
                chainMigrationNumber == data.migrationNumber,
                InvalidChainMigrationNumber(chainMigrationNumber, data.migrationNumber)
            );
            /// In this case the TokenBalanceMigrationData data might be malicious.
            /// We check the chainId to match the finalizeWithdrawalParams.chainId.
            /// The amount might be malicious, but that poses a restriction on users of the chain, not other chains.
            /// The AssetTracker cannot protect individual users only other chains. Individual users rely on the proof system.
            /// The last field is migrationNumber, which cannot be abused.

            require(currentSettlementLayer != block.chainid, NotMigratedChain());
            require(data.chainId == _finalizeWithdrawalParams.chainId, InvalidWithdrawalChainId());

            // we check equality here to make sure that we migrated the token balance back to L1 from Gateway.
            // this is needed to ensure that the chainBalance on the Gateway AssetTracker is currently 0.
            require(
                (assetMigrationNumber[data.chainId][data.assetId]) % 2 == 0,
                InvalidMigrationNumber(chainMigrationNumber, assetMigrationNumber[data.chainId][data.assetId])
            );

            fromChainId = data.chainId;
            toChainId = currentSettlementLayer;
        } else {
            /// In this case we trust the TokenBalanceMigrationData data and the settlement layer = Gateway to be honest.
            /// If the settlement layer is compromised, other chains settling on L1 are not compromised, only chains settling on Gateway.

            require(
                _bridgehub().whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
                InvalidWithdrawalChainId()
            );

            /// We trust the settlement layer to provide the correct assetId.

            fromChainId = _finalizeWithdrawalParams.chainId;
            toChainId = data.chainId;
        }

        _assignMaxChainBalanceIfNeeded(data.tokenOriginChainId, data.assetId);
        _migrateFunds({_fromChainId: fromChainId, _toChainId: toChainId, _assetId: data.assetId, _amount: data.amount});

        assetMigrationNumber[data.chainId][data.assetId] = data.migrationNumber;

        ConfirmBalanceMigrationData memory confirmBalanceMigrationData = ConfirmBalanceMigrationData({
            version: TOKEN_BALANCE_MIGRATION_DATA_VERSION,
            isL1ToGateway: data.isL1ToGateway,
            chainId: data.chainId,
            assetId: data.assetId,
            migrationNumber: data.migrationNumber,
            amount: data.amount
        });

        _sendConfirmationToChains(
            data.isL1ToGateway ? currentSettlementLayer : _finalizeWithdrawalParams.chainId,
            confirmBalanceMigrationData
        );
    }

    function _sendConfirmationToChains(
        uint256 _settlementLayerChainId,
        ConfirmBalanceMigrationData memory _confirmBalanceMigrationData
    ) internal {
        /// We send the confirmMigrationOnGateway first, so that withdrawals are definitely paused until the migration is confirmed on GW.
        /// Note: the confirmMigrationOnL2 is a L1->GW->L2 txs if the chain is settling on Gateway.
        _sendToChain(
            _settlementLayerChainId,
            GW_ASSET_TRACKER_ADDR,
            abi.encodeCall(IGWAssetTracker.confirmMigrationOnGateway, (_confirmBalanceMigrationData))
        );
        _sendToChain(
            _confirmBalanceMigrationData.chainId,
            L2_ASSET_TRACKER_ADDR,
            abi.encodeCall(IL2AssetTracker.confirmMigrationOnL2, (_confirmBalanceMigrationData))
        );
    }

    function _migrateFunds(uint256 _fromChainId, uint256 _toChainId, bytes32 _assetId, uint256 _amount) internal {
        _decreaseChainBalance(_fromChainId, _assetId, _amount);
        chainBalance[_toChainId][_assetId] += _amount;
    }

    function _sendToChain(uint256 _chainId, address _to, bytes memory _data) internal {
        address zkChain = _bridgehub().getZKChain(_chainId);
        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(_to, _data);
    }

    function _proveMessageInclusion(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) internal view {
        require(_finalizeWithdrawalParams.l2Sender == L2_ASSET_TRACKER_ADDR, InvalidSender());
        bool success = MESSAGE_ROOT.proveL1DepositParamsInclusion(_finalizeWithdrawalParams);
        if (!success) {
            revert InvalidProof();
        }
    }

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return chainAssetHandler.getMigrationNumber(_chainId);
    }
}
