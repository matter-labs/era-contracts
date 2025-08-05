// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TokenBalanceMigrationData} from "./IAssetTrackerBase.sol";
import {L2Message} from "../../common/Messaging.sol";
import {L2_ASSET_TRACKER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {InvalidProof} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "../../bridge/interfaces/IL1Nullifier.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";

import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {InsufficientChainBalanceAssetTracker, InvalidAssetId, InvalidMigrationNumber, InvalidSender, InvalidWithdrawalChainId, NotMigratedChain} from "./AssetTrackerErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IL1AssetTracker} from "./IL1AssetTracker.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";

contract L1AssetTracker is AssetTrackerBase, IL1AssetTracker {
    uint256 public immutable L1_CHAIN_ID;

    IBridgehub public immutable BRIDGE_HUB;

    INativeTokenVault public immutable NATIVE_TOKEN_VAULT;

    IMessageRoot public immutable MESSAGE_ROOT;
    constructor(uint256 _l1ChainId, address _bridgeHub, address, address _nativeTokenVault, address _messageRoot) {
        L1_CHAIN_ID = _l1ChainId;
        BRIDGE_HUB = IBridgehub(_bridgeHub);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
    }

    function initialize() external {
        // TODO: implement
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgeHub() internal view override returns (IBridgehub) {
        return BRIDGE_HUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVault) {
        return NATIVE_TOKEN_VAULT;
    }

    function _messageRoot() internal view override returns (IMessageRoot) {
        return MESSAGE_ROOT;
    }

    /*//////////////////////////////////////////////////////////////
                    Token deposits and withdrawals
    //////////////////////////////////////////////////////////////*/

    /// @notice Called on the L1 when a deposit to the chain happens.
    /// @notice Also called from the InteropCenter on Gateway during deposits.
    /// @dev As the chain does not update its balance when settling on L1.
    function handleChainBalanceIncreaseOnL1(
        uint256 _chainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) external {
        // onlyNativeTokenVault {

        uint256 currentSettlementLayer = _bridgeHub().settlementLayer(_chainId);
        uint256 chainToUpdate = currentSettlementLayer == block.chainid ? _chainId : currentSettlementLayer;
        if (currentSettlementLayer != block.chainid) {
            uint256 key = uint256(keccak256(abi.encode(_chainId)));
            TransientPrimitivesLib.set(key, uint256(_assetId));
            TransientPrimitivesLib.set(key + 1, _amount);
        }
        // if (!isMinterChain[chainToUpdate][_assetId]) {
        chainBalance[chainToUpdate][_assetId] += _amount;
        // }
    }

    /// @notice Called on the L1 by the chain's mailbox when a deposit happens
    /// @notice Used for deposits via Gateway.
    function getBalanceChange(uint256 _chainId) external returns (bytes32 assetId, uint256 amount) {
        // kl todo add only whitelisted settlement layers.
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
        uint256 _tokenOriginChainId
    ) external {
        // onlyNativeTokenVault
        uint256 chainToUpdate = _getWithdrawalChain(_chainId);

        bool chainToUpdateIsMinter = _tokenOriginChainId == chainToUpdate ||
            _bridgeHub().settlementLayer(_tokenOriginChainId) == chainToUpdate;
        if (chainToUpdateIsMinter) {
            return;
        }
        // Check that the chain has sufficient balance
        if (chainBalance[chainToUpdate][_assetId] < _amount) {
            revert InsufficientChainBalanceAssetTracker(chainToUpdate, _assetId, _amount);
        }
        chainBalance[chainToUpdate][_assetId] -= _amount;
    }

    function _getWithdrawalChain(uint256 _chainId) internal view returns (uint256 chainToUpdate) {
        uint256 settlementLayer = IL1Nullifier(IL1NativeTokenVault(address(_nativeTokenVault())).L1_NULLIFIER())
            .getTransientSettlementLayer();
        chainToUpdate = settlementLayer == 0 ? _chainId : settlementLayer;
    }

    /*//////////////////////////////////////////////////////////////
                    Gateway related token balance migration 
    //////////////////////////////////////////////////////////////*/

    /// @notice This function receives the migration from the L2 or the Gateway.
    /// @dev It sends the corresponding L1->L2 messages to the L2 and the Gateway.
    function receiveMigrationOnL1(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) external {
        _proveMessageInclusion(_finalizeWithdrawalParams);
        require(_finalizeWithdrawalParams.l2Sender == L2_ASSET_TRACKER_ADDR, InvalidSender());

        // solhint-disable-next-line no-unused-vars

        TokenBalanceMigrationData memory data = abi.decode(
            _finalizeWithdrawalParams.message,
            (TokenBalanceMigrationData)
        );
        require(assetMigrationNumber[data.chainId][data.assetId] < data.migrationNumber, InvalidAssetId());

        uint256 currentSettlementLayer = _bridgeHub().settlementLayer(data.chainId);
        // require(_getMigrationNumber(chainId) == migrationNumber, InvalidMigrationNumber());
        uint256 fromChainId;
        uint256 toChainId;

        if (data.isL1ToGateway) {
            require(currentSettlementLayer != block.chainid, NotMigratedChain());
            require(data.chainId == _finalizeWithdrawalParams.chainId, InvalidWithdrawalChainId());
            uint256 chainMigrationNumber = _getMigrationNumber(data.chainId);

            // we check parity here to make sure that we migrated back to L1 from Gateway.
            // In the future we might initalize chains on GW. So we subtract from chainMigrationNumber.
            require(
                (chainMigrationNumber - assetMigrationNumber[data.chainId][data.assetId]) % 2 == 1,
                InvalidMigrationNumber(chainMigrationNumber, assetMigrationNumber[data.chainId][data.assetId])
            );

            /// We check the assetId to make sure the chain is not lying about it.
            DataEncoding.assetIdCheck(data.tokenOriginChainId, data.assetId, data.originToken);

            fromChainId = data.chainId;
            toChainId = currentSettlementLayer;
        } else {
            require(currentSettlementLayer == block.chainid, NotMigratedChain());
            require(
                _bridgeHub().whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
                InvalidWithdrawalChainId()
            );

            /// We trust the settlement layer to provide the correct assetId.

            fromChainId = _finalizeWithdrawalParams.chainId;
            toChainId = data.chainId;
        }

        _migrateFunds(fromChainId, toChainId, data.assetId, data.amount, data.tokenOriginChainId);
        assetMigrationNumber[data.chainId][data.assetId] = data.migrationNumber;
        _sendToChain(
            data.isL1ToGateway ? currentSettlementLayer : _finalizeWithdrawalParams.chainId,
            abi.encodeCall(IL2AssetTracker.confirmMigrationOnGateway, (data))
        );
        _sendToChain(data.chainId, abi.encodeCall(IL2AssetTracker.confirmMigrationOnL2, (data)));
    }

    function _migrateFunds(
        uint256 _fromChainId,
        uint256 _toChainId,
        bytes32 _assetId,
        uint256 _amount,
        uint256 _tokenOriginChainId
    ) internal {
        bool fromChainIsMinter = _tokenOriginChainId == _fromChainId ||
            _bridgeHub().settlementLayer(_tokenOriginChainId) == _fromChainId;
        if (fromChainIsMinter) {
            return;
        }
        bool toChainIsMinter = _tokenOriginChainId == _toChainId ||
            _bridgeHub().settlementLayer(_tokenOriginChainId) == _toChainId;
        if (toChainIsMinter) {
            return;
        }
        // if (!isMinterChain[_fromChainId][_assetId]) {
        // && data.tokenOriginChainId != _fromChainId) { kl todo can probably remove
        chainBalance[_fromChainId][_assetId] -= _amount;
        chainBalance[_toChainId][_assetId] += _amount;
        // }
    }

    function _sendToChain(uint256 _chainId, bytes memory _data) internal {
        address zkChain = _bridgeHub().getZKChain(_chainId);
        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(L2_ASSET_TRACKER_ADDR, _data);
    }

    function _proveMessageInclusion(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) internal view {
        L2Message memory l2ToL1Message = L2Message({
            txNumberInBatch: _finalizeWithdrawalParams.l2TxNumberInBatch,
            sender: L2_ASSET_TRACKER_ADDR,
            data: _finalizeWithdrawalParams.message
        });

        bool success = _bridgeHub().proveL2MessageInclusion({
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
}
