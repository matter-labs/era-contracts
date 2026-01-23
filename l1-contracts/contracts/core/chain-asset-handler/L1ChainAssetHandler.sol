// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IL1Nullifier} from "../../bridge/interfaces/IL1Nullifier.sol";
import {TxStatus} from "../../common/Messaging.sol";
import {IBridgehubBase, BridgehubBurnCTMAssetData} from "../bridgehub/IBridgehubBase.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {IZKChain} from "../../state-transition/chain-interfaces/IZKChain.sol";
import {IL1AssetHandler} from "../../bridge/interfaces/IL1AssetHandler.sol";
import {IL1Bridgehub} from "../bridgehub/IL1Bridgehub.sol";
import {IMessageRoot} from "../message-root/IMessageRoot.sol";
import {IAssetRouterBase} from "../../bridge/asset-router/IAssetRouterBase.sol";
import {IChainAssetHandlerShared} from "./IChainAssetHandlerShared.sol";
import {IL1ChainAssetHandler} from "./IL1ChainAssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev L1 version – keeps the cheap immutables set in the constructor.
contract L1ChainAssetHandler is ChainAssetHandlerBase, IL1AssetHandler, IL1ChainAssetHandler, IChainAssetHandlerShared {
    /// @dev The assetId of the ETH.
    bytes32 public immutable override ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    uint256 public immutable override L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    IL1Bridgehub public immutable override BRIDGEHUB;

    /// @dev The message root contract.
    IMessageRoot public immutable override MESSAGE_ROOT;

    /// @dev The asset router contract.
    IAssetRouterBase public immutable override ASSET_ROUTER;

    /// @dev The asset tracker contract.
    address internal immutable ASSET_TRACKER;

    /// @dev The L1 nullifier contract.
    IL1Nullifier internal immutable L1_NULLIFIER;

    /// @dev The mapping showing for each chain if migration is in progress or not, used for freezing deposits.abi
    mapping(uint256 chainId => bool isMigrationInProgress) public isMigrationInProgress;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }
    function _bridgehub() internal view override returns (IL1Bridgehub) {
        return BRIDGEHUB;
    }
    function _messageRoot() internal view override returns (IMessageRoot) {
        return MESSAGE_ROOT;
    }
    function _assetRouter() internal view override returns (IAssetRouterBase) {
        return ASSET_ROUTER;
    }

    function _assetTracker() internal view returns (address) {
        return ASSET_TRACKER;
    }

    constructor(
        address _owner,
        address _bridgehub,
        address _assetRouter,
        address _messageRoot,
        address _assetTracker,
        IL1Nullifier _l1Nullifier
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGEHUB = IL1Bridgehub(_bridgehub);
        ASSET_ROUTER = IAssetRouterBase(_assetRouter);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
        L1_CHAIN_ID = block.chainid;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        ASSET_TRACKER = _assetTracker;
        L1_NULLIFIER = _l1Nullifier;
        _transferOwnership(_owner);
    }

    /// @dev Initializes the reentrancy guard. Expected to be used in the proxy.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @dev IL1AssetHandler interface, used to undo a failed migration of a chain.
    /// @param _assetId the assetId of the chain's CTM
    /// @param _data the data for the recovery.
    /// @param _depositSender the address of the entity that initiated the deposit.
    // slither-disable-next-line locked-ether
    function bridgeConfirmTransferResult(
        uint256,
        TxStatus _txStatus,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable requireZeroValue(msg.value) onlyAssetRouter {
        BridgehubBurnCTMAssetData memory bridgehubBurnData = abi.decode(_data, (BridgehubBurnCTMAssetData));

        (address zkChain, address ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeConfirmTransferResult(
            bridgehubBurnData.chainId,
            _txStatus
        );

        IChainTypeManager(ctm).forwardedBridgeConfirmTransferResult({
            _chainId: bridgehubBurnData.chainId,
            _txStatus: _txStatus,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _ctmData: bridgehubBurnData.ctmData
        });

        if (_txStatus == TxStatus.Failure) {
            --migrationNumber[bridgehubBurnData.chainId];
            // Reset migration interval since the L1 -> SL migration failed.
            // This prevents stale migrateToSLBatchNumber from affecting settlement layer validation.
            delete migrationInterval[bridgehubBurnData.chainId];
        }

        isMigrationInProgress[bridgehubBurnData.chainId] = false;

        IZKChain(zkChain).forwardedBridgeConfirmTransferResult({
            _chainId: bridgehubBurnData.chainId,
            _txStatus: _txStatus,
            _assetInfo: _assetId,
            _originalCaller: _depositSender,
            _chainData: bridgehubBurnData.chainData
        });
    }

    function _setMigrationInProgressOnL1(uint256 _chainId) internal override {
        isMigrationInProgress[_chainId] = true;
    }
}
