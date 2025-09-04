// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {TokenBalanceMigrationData} from "../../common/Messaging.sol";
import {L2_ASSET_TRACKER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {InvalidProof} from "../../common/L1ContractErrors.sol";
import {IMessageRoot, V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY} from "../../bridgehub/IMessageRoot.sol";
import {IBridgehub} from "../../bridgehub/IBridgehub.sol";
import {FinalizeL1DepositParams, IL1Nullifier} from "../../bridge/interfaces/IL1Nullifier.sol";
import {IMailbox} from "../../state-transition/chain-interfaces/IMailbox.sol";
import {IL1NativeTokenVault} from "../../bridge/ntv/IL1NativeTokenVault.sol";

import {TransientPrimitivesLib} from "../../common/libraries/TransientPrimitives/TransientPrimitives.sol";
import {InsufficientChainBalanceAssetTracker, InvalidAssetId, InvalidBaseTokenAssetId, InvalidChainMigrationNumber, InvalidFunctionSignature, InvalidMigrationNumber, InvalidOriginChainId, InvalidSender, InvalidWithdrawalChainId, NotMigratedChain, OnlyWhitelistedSettlementLayer} from "./AssetTrackerErrors.sol";
import {V30UpgradeChainBatchNumberNotSet} from "../../bridgehub/L1BridgehubErrors.sol";
import {ZeroAddress} from "../../common/L1ContractErrors.sol";
import {AssetTrackerBase} from "./AssetTrackerBase.sol";
import {IL2AssetTracker} from "./IL2AssetTracker.sol";
import {IL1AssetTracker} from "./IL1AssetTracker.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IChainAssetHandler} from "../../bridgehub/IChainAssetHandler.sol";
import {IAssetTrackerDataEncoding} from "./IAssetTrackerDataEncoding.sol";

contract L1AssetTracker is AssetTrackerBase, IL1AssetTracker {
    uint256 public immutable L1_CHAIN_ID;

    IBridgehub public immutable BRIDGE_HUB;

    INativeTokenVault public immutable NATIVE_TOKEN_VAULT;

    IMessageRoot public immutable MESSAGE_ROOT;

    IL1Nullifier public immutable L1_NULLIFIER;

    IChainAssetHandler public chainAssetHandler;

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }

    function _bridgehub() internal view override returns (IBridgehub) {
        return BRIDGE_HUB;
    }

    function _nativeTokenVault() internal view override returns (INativeTokenVault) {
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
        BRIDGE_HUB = IBridgehub(_bridgehub);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
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

    function migrateTokenBalanceFromNTV(uint256 _chainId, bytes32 _assetId) external {
        IL1NativeTokenVault l1NTV = IL1NativeTokenVault(address(NATIVE_TOKEN_VAULT));
        chainBalance[_chainId][_assetId] = l1NTV.migrateTokenBalanceToAssetTracker(_chainId, _assetId);
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
    ) external onlyNativeTokenVault {
        uint256 savedAssetMigrationNumber = assetMigrationNumber[_chainId][_assetId];
        uint256 currentSettlementLayer = _bridgehub().settlementLayer(_chainId);
        if (_tokenCanSkipMigrationOnSettlementLayer(_chainId, _assetId)) {
            _forceSetAssetMigrationNumber(_chainId, _assetId);
        } else {
            // We require that the asset is migrated, deposits are paused until then.
            require(
                currentSettlementLayer == block.chainid ||
                    savedAssetMigrationNumber == _getChainMigrationNumber(_chainId),
                InvalidAssetId(_assetId)
            );
        }

        uint256 chainToUpdate = currentSettlementLayer == block.chainid ? _chainId : currentSettlementLayer;
        if (currentSettlementLayer != block.chainid) {
            uint256 key = uint256(keccak256(abi.encode(_chainId)));
            /// A malicious transactionFilterer can do multiple deposits, but this will make the chainBalance smaller on the Gateway.
            TransientPrimitivesLib.set(key, uint256(_assetId));
            TransientPrimitivesLib.set(key + 1, _amount);
        }

        // `totalSupplyAcrossAllChains` stores the total balance of tokens outside of the origin chain.
        // There are three possible cases:
        // 1. We are depositing it back to the origin chain. The balance outside of it decreases and so we decrease
        // totalSupplyAcrossAllChains.
        // 2. The token's origin is L1 and so regardless of the destination chain, the total amount outside of L1, i.e. 
        // inside our ecosystem increases.
        // 3. (Skipped) Since the token moves between non-origin chains, the totalSupplyAcrossAllChains remains unchanged.
        if (_tokenOriginChainId == _chainId) {
            totalSupplyAcrossAllChains[_assetId] -= _amount;
        } else if (_tokenOriginChainId == block.chainid) {
            totalSupplyAcrossAllChains[_assetId] += _amount;
        }
        if (_tokenOriginChainId != _chainId) {
            chainBalance[chainToUpdate][_assetId] += _amount;
        }
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
        uint256 _tokenOriginChainId
    ) external onlyNativeTokenVault {
        if (_tokenOriginChainId == _chainId) {
            totalSupplyAcrossAllChains[_assetId] += _amount;
        } else if (_tokenOriginChainId == block.chainid) {
            totalSupplyAcrossAllChains[_assetId] -= _amount;
        }

        uint256 chainToUpdate = _getWithdrawalChain(_chainId);

        if (_isChainMinter(chainToUpdate, _tokenOriginChainId)) {
            return;
        }
        // Check that the chain has sufficient balance
        if (chainBalance[chainToUpdate][_assetId] < _amount) {
            revert InsufficientChainBalanceAssetTracker(chainToUpdate, _assetId, _amount);
        }
        chainBalance[chainToUpdate][_assetId] -= _amount;
    }

    function _getWithdrawalChain(uint256 _chainId) internal view returns (uint256 chainToUpdate) {
        (uint256 settlementLayer, uint256 l2BatchNumber) = L1_NULLIFIER.getTransientSettlementLayer();
        // This is the batch starting from which it is the responsibility of all the settlement layers to ensure that
        // all withdrawals coming from the chain are backed inside the balance of this settlement layer.
        // Note, that since this method is used for claiming failed deposits, it implies that any failed deposit that has been processed
        // why the chain settled on top of Gateway, has been accredited to Gateway's balance.
        // For all the batches smaller or equal to that, the responsibility lies with the chain itself.
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
        require(_finalizeWithdrawalParams.l2Sender == L2_ASSET_TRACKER_ADDR, InvalidSender());

        (bytes4 functionSignature, TokenBalanceMigrationData memory data) = DataEncoding
            .decodeTokenBalanceMigrationData(_finalizeWithdrawalParams.message);
        require(
            functionSignature == IAssetTrackerDataEncoding.receiveMigrationOnL1.selector,
            InvalidFunctionSignature(functionSignature)
        );

        require(assetMigrationNumber[data.chainId][data.assetId] < data.migrationNumber, InvalidAssetId(data.assetId));

        uint256 currentSettlementLayer = _bridgehub().settlementLayer(data.chainId);
        require(
            _getChainMigrationNumber(data.chainId) == data.migrationNumber,
            InvalidChainMigrationNumber(_getChainMigrationNumber(data.chainId), data.migrationNumber)
        );
        uint256 fromChainId;
        uint256 toChainId;

        if (data.isL1ToGateway) {
            /// In this case the TokenBalanceMigrationData data might be malicious.
            /// We check the chainId to match the finalizeWithdrawalParams.chainId.
            /// We check the assetId, tokenOriginChainId, originToken with an assetIdCheck.
            /// The amount might be malicious, but that poses a restriction on users of the chain, not other chains.
            /// The AssetTracker cannot protect individual users only other chains. Individual users rely on the proof system.
            /// The last field is migrationNumber, which cannot be abused.

            require(currentSettlementLayer != block.chainid, NotMigratedChain());
            require(data.chainId == _finalizeWithdrawalParams.chainId, InvalidWithdrawalChainId());
            uint256 chainMigrationNumber = _getChainMigrationNumber(data.chainId);

            // we check parity here to make sure that we migrated the token balance back to L1 from Gateway.
            // this is needed to ensure that the chainBalance on the Gateway AssetTracker is currently 0.
            // In the future we might initialize chains on GW. So we subtract from chainMigrationNumber.
            require(
                (chainMigrationNumber - assetMigrationNumber[data.chainId][data.assetId]) % 2 == 1,
                InvalidMigrationNumber(chainMigrationNumber, assetMigrationNumber[data.chainId][data.assetId])
            );

            /// We check the assetId to make sure the chain is not lying about it.
            if (data.originToken != address(0)) {
                DataEncoding.assetIdCheck(data.tokenOriginChainId, data.assetId, data.originToken);
            } else {
                require(data.tokenOriginChainId == L1_CHAIN_ID, InvalidOriginChainId());
                require(BRIDGE_HUB.baseTokenAssetId(data.chainId) == data.assetId, InvalidBaseTokenAssetId());
            }

            fromChainId = data.chainId;
            toChainId = currentSettlementLayer;
        } else {
            /// In this case we trust the TokenBalanceMigrationData data and the settlement layer = Gateway to be honest.
            /// If the settlement layer is compromised, other chains settling on L1 are not compromised, only chains settling on Gateway.

            require(currentSettlementLayer == block.chainid, NotMigratedChain());
            require(
                _bridgehub().whitelistedSettlementLayers(_finalizeWithdrawalParams.chainId),
                InvalidWithdrawalChainId()
            );

            /// We trust the settlement layer to provide the correct assetId.

            fromChainId = _finalizeWithdrawalParams.chainId;
            toChainId = data.chainId;
        }

        _migrateFunds({
            _fromChainId: fromChainId,
            _toChainId: toChainId,
            _assetId: data.assetId,
            _amount: data.amount,
            _tokenOriginChainId: data.tokenOriginChainId
        });
        assetMigrationNumber[data.chainId][data.assetId] = data.migrationNumber;

        /// We send the confirmMigrationOnGateway first, so that withdrawals are definitely paused until the migration is confirmed on GW.
        /// Note: the confirmMigrationOnL2 is a L1->GW->L2 txs.
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
        if (!_isChainMinter(_fromChainId, _tokenOriginChainId)) {
            chainBalance[_fromChainId][_assetId] -= _amount;
        } else {
            /// if the source chain is a minter, we are increasing the totalSupply.
            totalSupplyAcrossAllChains[_assetId] += _amount;
        }
        if (!_isChainMinter(_toChainId, _tokenOriginChainId)) {
            chainBalance[_toChainId][_assetId] += _amount;
        } else {
            /// If the destination chain is a minter, we are decreasing the totalSupply.
            totalSupplyAcrossAllChains[_assetId] -= _amount;
        }
    }

    function _isChainMinter(uint256 _chainId, uint256 _tokenOriginChainId) internal view returns (bool) {
        return _tokenOriginChainId == _chainId || _bridgehub().settlementLayer(_tokenOriginChainId) == _chainId;
    }

    function _sendToChain(uint256 _chainId, bytes memory _data) internal {
        address zkChain = _bridgehub().getZKChain(_chainId);
        // slither-disable-next-line unused-return
        IMailbox(zkChain).requestL2ServiceTransaction(L2_ASSET_TRACKER_ADDR, _data);
    }

    function _proveMessageInclusion(FinalizeL1DepositParams calldata _finalizeWithdrawalParams) internal view {
        bool success = MESSAGE_ROOT.proveL1DepositParamsInclusion(_finalizeWithdrawalParams, L2_ASSET_TRACKER_ADDR);
        if (!success) {
            revert InvalidProof();
        }
    }

    function _getChainMigrationNumber(uint256 _chainId) internal view override returns (uint256) {
        return chainAssetHandler.getMigrationNumber(_chainId);
    }
}
