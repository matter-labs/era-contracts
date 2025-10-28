// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainAssetHandlerBase} from "./ChainAssetHandlerBase.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {DataEncoding} from "../common/libraries/DataEncoding.sol";
import {IBridgehubBase, BridgehubBurnCTMAssetData} from "./IBridgehubBase.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {IZKChain} from "../state-transition/chain-interfaces/IZKChain.sol";
import {IL1AssetHandler} from "../bridge/interfaces/IL1AssetHandler.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The ChainAssetHandler contract is used for migrating chains between settlement layers,
/// it is the IL1AssetHandler for the chains themselves, which is used to migrate the chains
/// between different settlement layers (for example from L1 to Gateway).
/// @dev L1 version – keeps the cheap immutables set in the constructor.
contract L1ChainAssetHandler is ChainAssetHandlerBase, IL1AssetHandler {
    /// @dev The assetId of the ETH.
    bytes32 public immutable override ETH_TOKEN_ASSET_ID;

    /// @dev The chain ID of L1.
    uint256 public immutable override L1_CHAIN_ID;

    /// @dev The bridgehub contract.
    address public immutable override BRIDGEHUB;

    /// @dev The message root contract.
    address public immutable override MESSAGE_ROOT;

    /// @dev The asset router contract.
    address public immutable override ASSET_ROUTER;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLE GETTERS
    //////////////////////////////////////////////////////////////*/

    function _ethTokenAssetId() internal view override returns (bytes32) {
        return ETH_TOKEN_ASSET_ID;
    }
    function _l1ChainId() internal view override returns (uint256) {
        return L1_CHAIN_ID;
    }
    function _bridgehub() internal view override returns (address) {
        return BRIDGEHUB;
    }
    function _messageRoot() internal view override returns (address) {
        return MESSAGE_ROOT;
    }
    function _assetRouter() internal view override returns (address) {
        return ASSET_ROUTER;
    }

    constructor(
        address _owner,
        address _bridgehub,
        address _assetRouter,
        address _messageRoot
    ) reentrancyGuardInitializer {
        _disableInitializers();
        BRIDGEHUB = _bridgehub;
        ASSET_ROUTER = _assetRouter;
        MESSAGE_ROOT = _messageRoot;
        L1_CHAIN_ID = block.chainid;
        ETH_TOKEN_ASSET_ID = DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS);
        _transferOwnership(_owner);
    }

    /// @dev Initializes the reentrancy guard. Expected to be used in the proxy.
    /// @param _owner the owner of the contract
    function initialize(address _owner) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
    }

    /// @dev IL1AssetHandler interface, used to undo a failed migration of a chain.
    /// @param _chainId the chainId of the chain
    /// @param _assetId the assetId of the chain's CTM
    /// @param _data the data for the recovery.
    /// @param _depositSender the address of the entity that initiated the deposit.
    // slither-disable-next-line locked-ether
    function bridgeRecoverFailedTransfer(
        // solhint-disable-next-line no-unused-vars
        uint256 _chainId,
        bytes32 _assetId,
        address _depositSender,
        bytes calldata _data
    ) external payable override requireZeroValue(msg.value) onlyAssetRouter {
        BridgehubBurnCTMAssetData memory bridgehubBurnData = abi.decode(_data, (BridgehubBurnCTMAssetData));

        (address zkChain, address ctm) = IBridgehubBase(_bridgehub()).forwardedBridgeRecoverFailedTransfer(
            bridgehubBurnData.chainId
        );

        IChainTypeManager(ctm).forwardedBridgeRecoverFailedTransfer({
            _chainId: bridgehubBurnData.chainId,
            _assetInfo: _assetId,
            _depositSender: _depositSender,
            _ctmData: bridgehubBurnData.ctmData
        });

        IZKChain(zkChain).forwardedBridgeRecoverFailedTransfer({
            _chainId: bridgehubBurnData.chainId,
            _assetInfo: _assetId,
            _originalCaller: _depositSender,
            _chainData: bridgehubBurnData.chainData
        });
    }
}
