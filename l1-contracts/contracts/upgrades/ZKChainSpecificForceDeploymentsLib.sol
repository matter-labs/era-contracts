// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "../bridge/ntv/INativeTokenVaultBase.sol";
import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {TokenBridgingData, TokenMetadata} from "../common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Builds a chain's `ZKChainSpecificForceDeploymentsData` from L1 state — the per-chain
///         half of the L2 transaction of a genesis AND of an upgrade, read through the ecosystem's
///         Bridgehub.
/// @dev A library so no chain diamond storage is reachable: both the genesis engine (which holds a
///      chain diamond's storage under delegatecall) and the delegate-calldata composers (plain
///      external views composing for any chain of the ecosystem) reach it with explicit chain
///      context, so the two paths cannot produce different data for the same chain.
library ZKChainSpecificForceDeploymentsLib {
    /// @param _bridgehub The ecosystem's Bridgehub.
    /// @param _chainId The chain whose base-token data is read.
    function build(address _bridgehub, uint256 _chainId) internal view returns (bytes memory) {
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        // The base token AS IT EXISTS ON THIS LAYER: `baseToken` resolves the asset id through its
        // registered asset handler, so a token bridged in from elsewhere resolves to its local
        // representation — the only contract here whose metadata can be read at all.
        address baseTokenAddress = bridgehub.baseToken(_chainId);
        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(_chainId);
        INativeTokenVaultBase nativeTokenVault = IL1AssetRouter(address(bridgehub.assetRouter())).nativeTokenVault();

        return
            abi.encode(
                ZKChainSpecificForceDeploymentsData({
                    // The legacy shared bridge has been removed; this ABI placeholder is always address(0).
                    l2LegacySharedBridge: address(0),
                    predeployedL2WethAddress: address(0),
                    // The local representation again, NOT `baseTokenBridgingData.originToken`,
                    // which the struct already carries: the single consumer of this field
                    // (`IL2WrappedBaseToken.initializeV3`, through `L2GenesisForceDeploymentsHelper`)
                    // stores it beside the metadata below, so the two must name one token.
                    baseTokenL1Address: baseTokenAddress,
                    baseTokenMetadata: _baseTokenMetadata(baseTokenAddress),
                    baseTokenBridgingData: TokenBridgingData({
                        assetId: baseTokenAssetId,
                        originChainId: nativeTokenVault.originChainId(baseTokenAssetId),
                        originToken: nativeTokenVault.originToken(baseTokenAssetId)
                    })
                })
            );
    }

    /// @notice The base token's name, symbol and decimals.
    /// @dev Typed reads: a base token without `name()`/`symbol()`, or answering them with a
    ///      Maker-style `bytes32`, reverts the chain's genesis and every upgrade composed for it:
    ///      such a chain can be neither created nor upgraded.
    /// @dev `decimals` is 18 for every base token. The probe this read replaced filtered out
    ///      every conforming `decimals()` answer, so every chain created so far has 18 in its L2
    ///      vault, and `L2NativeTokenVault.updateL2` rewrites the value on every upgrade: reading
    ///      the token's own would redenominate a live chain's base token.
    function _baseTokenMetadata(address _baseTokenAddress) private view returns (TokenMetadata memory) {
        if (_baseTokenAddress == ETH_TOKEN_ADDRESS) {
            return TokenMetadata({name: string("Ether"), symbol: string("ETH"), decimals: 18});
        }
        return
            TokenMetadata({
                name: IERC20Metadata(_baseTokenAddress).name(),
                symbol: IERC20Metadata(_baseTokenAddress).symbol(),
                decimals: 18
            });
    }
}
