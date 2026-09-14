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
///         half of an L2 upgrade's delegate calldata, read through the ecosystem's Bridgehub.
/// @dev A library so no chain diamond storage is reachable: delegate-calldata composers are plain
///      external views that compose for any chain of the ecosystem.
library ZKChainSpecificForceDeploymentsLib {
    /// @param _bridgehub The ecosystem's Bridgehub.
    /// @param _chainId The chain whose base-token data is read.
    function build(address _bridgehub, uint256 _chainId) internal view returns (bytes memory) {
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        INativeTokenVaultBase nativeTokenVault = INativeTokenVaultBase(
            address(IL1AssetRouter(address(bridgehub.assetRouter())).nativeTokenVault())
        );
        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(_chainId);
        address originToken = nativeTokenVault.originToken(baseTokenAssetId);

        TokenMetadata memory baseTokenMetadata;
        if (originToken == ETH_TOKEN_ADDRESS) {
            baseTokenMetadata = TokenMetadata({name: "Ether", symbol: "ETH", decimals: 18});
        } else {
            // The metadata is read from the token's bridged representation on this settlement
            // layer (`tokenAddress`), not from `originToken`: a base token bridged from another
            // chain has no code here under its origin address.
            IERC20Metadata localToken = IERC20Metadata(nativeTokenVault.tokenAddress(baseTokenAssetId));
            baseTokenMetadata = TokenMetadata({
                name: localToken.name(),
                symbol: localToken.symbol(),
                decimals: localToken.decimals()
            });
        }

        return
            abi.encode(
                ZKChainSpecificForceDeploymentsData({
                    l2LegacySharedBridge: address(0),
                    predeployedL2WethAddress: address(0),
                    baseTokenL1Address: originToken,
                    baseTokenMetadata: baseTokenMetadata,
                    baseTokenBridgingData: TokenBridgingData({
                        assetId: baseTokenAssetId,
                        originChainId: nativeTokenVault.originChainId(baseTokenAssetId),
                        originToken: originToken
                    })
                })
            );
    }
}
