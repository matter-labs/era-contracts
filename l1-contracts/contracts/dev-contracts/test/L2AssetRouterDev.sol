// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {L2AssetRouter} from "../../bridge/asset-router/L2AssetRouter.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The "default" bridge implementation for the ERC20 tokens. Note, that it does not
/// support any custom token logic, i.e. rebase tokens' functionality is not supported.
contract L2AssetRouterDev is L2AssetRouter {
    constructor(
        uint256 _l1ChainId,
        uint256 _eraChainId,
        address _l1AssetRouter,
        address _legacySharedBridge,
        bytes32 _baseTokenAssetId,
        address _aliasedOwner
    ) 
        L2AssetRouter(
            _l1ChainId,
            _eraChainId,
            _l1AssetRouter,
            _legacySharedBridge,
            _baseTokenAssetId,
            _aliasedOwner
        )
    {}

    function setValues(
        address _l1AssetRouter,
        bytes32 _baseTokenAssetId
    ) public {
        l1AssetRouter = _l1AssetRouter;
        assetHandlerAddress[_baseTokenAssetId] = L2_NATIVE_TOKEN_VAULT_ADDR;
    }
}