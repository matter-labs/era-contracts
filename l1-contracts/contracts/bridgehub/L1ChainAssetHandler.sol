// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {BridgehubBurnCTMAssetData, IBridgehub} from "./IBridgehub.sol";
import {IMessageRoot} from "./IMessageRoot.sol";
import {IL1Nullifier} from "../bridge/interfaces/IL1Nullifier.sol";
import {GW_ASSET_TRACKER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IGWAssetTracker} from "../bridge/asset-tracker/IGWAssetTracker.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev L1 version – keeps the cheap immutables set in the constructor.
contract L1ChainAssetHandler is ChainAssetHandlerBase {
    /// @dev The assetId of the base token.
    bytes32 internal immutable ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    uint256 internal immutable L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    IBridgehub internal immutable BRIDGEHUB;

    /// @dev The message root contract.
    IMessageRoot internal immutable MESSAGE_ROOT;

    /// @dev The asset router contract.
    address internal immutable ASSET_ROUTER;

    /// @dev The asset tracker contract.
    address internal immutable ASSET_TRACKER;

    /// @dev The L1 nullifier contract.
    IL1Nullifier internal immutable L1_NULLIFIER;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }
    function _bridgehub() internal view override returns (IBridgehub) {
        return BRIDGEHUB;
    }
    function _messageRoot() internal view override returns (IMessageRoot) {
        return MESSAGE_ROOT;
    }
    function _assetRouter() internal view override returns (address) {
        return ASSET_ROUTER;
    }

    function _assetTracker() internal view override returns (address) {
        return ASSET_TRACKER;
    }

    constructor(
        uint256 _l1ChainId,
        address _owner,
        IBridgehub _bridgehub,
        address _assetRouter,
        IMessageRoot _messageRoot,
        address _assetTracker,
        IL1Nullifier _l1Nullifier
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGEHUB = _bridgehub;
        L1_CHAIN_ID = _l1ChainId;
        ASSET_ROUTER = _assetRouter;
        MESSAGE_ROOT = _messageRoot;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(_l1ChainId, ETH_TOKEN_ADDRESS);
        ASSET_TRACKER = _assetTracker;
        L1_NULLIFIER = _l1Nullifier;
        _transferOwnership(_owner);
    }

    /// @dev Initializes the reentrancy guard. Expected to be used in the proxy.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    function _setLegacySharedBridgeIfL1(
        BridgehubBurnCTMAssetData memory _bridgehubBurnData,
        uint256 _settlementChainId
    ) internal override {
        /// We set the legacy shared bridge address on the gateway asset tracker to allow for L2->L1 asset withdrawals via the L2AssetRouter.

        bytes memory data = abi.encodeCall(
            IGWAssetTracker.setLegacySharedBridgeAddress,
            (_bridgehubBurnData.chainId, L1_NULLIFIER.l2BridgeAddress(_bridgehubBurnData.chainId))
        );
        address settlementZkChain = _bridgehub().getZKChain(_settlementChainId);
        // slither-disable-next-line unused-return
        IZKChain(settlementZkChain).requestL2ServiceTransaction(GW_ASSET_TRACKER_ADDR, data);
    }
}
