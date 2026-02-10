// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
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
import {MigrationNumberMismatch} from "../bridgehub/L1BridgehubErrors.sol";

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

    /// @dev The mapping showing for each chain if migration is in progress or not, used for freezing deposits.
    mapping(uint256 chainId => bool isMigrationInProgress) public isMigrationInProgress;

    /// @dev The message root contract. Set via `setAddresses` after deployment because
    /// L1MessageRoot is deployed after L1ChainAssetHandler (so that L1MessageRoot can store
    /// the chain asset handler address as an immutable).
    IMessageRoot internal storedMessageRoot;

    /// @dev The asset router contract. Set via `setAddresses` after deployment because
    /// L1AssetRouter is deployed after L1ChainAssetHandler.
    IAssetRouterBase internal storedAssetRouter;

    /*//////////////////////////////////////////////////////////////
                        GETTERS
    //////////////////////////////////////////////////////////////*/

    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }
    function _bridgehub() internal view override returns (IL1Bridgehub) {
        return BRIDGEHUB;
    }

    function _messageRoot() internal view override returns (IMessageRoot) {
        return storedMessageRoot;
    }

    // solhint-disable-next-line func-name-mixedcase
    function MESSAGE_ROOT() public view override returns (IMessageRoot) {
        return storedMessageRoot;
    }

    // solhint-disable-next-line func-name-mixedcase
    function ASSET_ROUTER() public view override returns (IAssetRouterBase) {
        return storedAssetRouter;
    }

    function _assetRouter() internal view override returns (IAssetRouterBase) {
        return storedAssetRouter;
    }

    constructor(
        address _owner,
        address _bridgehub
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGEHUB = IL1Bridgehub(_bridgehub);
        L1_CHAIN_ID = block.chainid;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        _transferOwnership(_owner);
    }

    /// @dev Initializes the reentrancy guard. Expected to be used in the proxy.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @notice Sets the addresses of the message root and asset router by querying the bridgehub.
    /// @dev Called after deployment once the dependent contracts are registered on the bridgehub.
    function setAddresses() external onlyOwner {
        storedMessageRoot = BRIDGEHUB.messageRoot();
        storedAssetRouter = BRIDGEHUB.assetRouter();
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
        uint256 chainId = bridgehubBurnData.chainId;

        (address zkChain, address ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeConfirmTransferResult(
            chainId,
            _txStatus
        );

        IChainTypeManager(ctm).forwardedBridgeConfirmTransferResult({
            _chainId: chainId,
            _txStatus: _txStatus,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _ctmData: bridgehubBurnData.ctmData
        });

        if (_txStatus == TxStatus.Failure) {
            uint256 failedMigrationNum = migrationNumber[chainId];
            require(
                failedMigrationNum == MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER,
                MigrationNumberMismatch(MIGRATION_NUMBER_L1_TO_SETTLEMENT_LAYER, failedMigrationNum)
            );
            migrationNumber[chainId] = failedMigrationNum - 1;
            // Reset migration interval since the L1 -> SL migration failed.
            // This prevents stale migrateToSLBatchNumber from affecting settlement layer validation.
            delete _migrationInterval[chainId][failedMigrationNum];
        }

        isMigrationInProgress[chainId] = false;

        IZKChain(zkChain).forwardedBridgeConfirmTransferResult({
            _chainId: chainId,
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
