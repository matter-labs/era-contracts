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

    /// @notice The base token's name, symbol and decimals, with the ERC20 defaults substituted for
    ///         a token that serves no usable metadata.
    /// @dev Tolerant by design: a chain may be created on a base token without metadata, and the
    ///      same values are recomposed on every later upgrade (`L2NativeTokenVault.updateL2`
    ///      rewrites them), so a strict read would make such a chain upgradeable only by first
    ///      changing its base token.
    function _baseTokenMetadata(address _baseTokenAddress) private view returns (TokenMetadata memory tokenData) {
        if (_baseTokenAddress == ETH_TOKEN_ADDRESS) {
            return TokenMetadata({name: string("Ether"), symbol: string("ETH"), decimals: 18});
        }

        (string memory stringResult, bool success) = _safeCallTokenMetadataString(
            _baseTokenAddress,
            abi.encodeCall(IERC20Metadata.name, ())
        );
        tokenData.name = success ? stringResult : string("Base Token");

        (stringResult, success) = _safeCallTokenMetadataString(
            _baseTokenAddress,
            abi.encodeCall(IERC20Metadata.symbol, ())
        );
        // "BT" is an acronym for "Base Token"
        tokenData.symbol = success ? stringResult : string("BT");

        // A conforming `decimals()` answers with exactly 32 bytes, which the `bytes32` guard below
        // filters out, so a conforming token lands on the ERC20 default of 18 and the probe only
        // ever bites on a token answering with some other width. That is what every chain created
        // so far has in its L2 vault, and `L2NativeTokenVault.updateL2` rewrites these values on
        // every upgrade — reading the real value here would silently redenominate a live chain's
        // base token, so it is deliberately left as is rather than "fixed" in passing.
        (uint256 uintResult, bool decimalsSuccess) = _safeCallTokenMetadataUint256(
            _baseTokenAddress,
            abi.encodeCall(IERC20Metadata.decimals, ())
        );
        tokenData.decimals = decimalsSuccess ? uintResult : 18;
    }

    /// @notice Calls a token's metadata method.
    /// @dev For the sake of simplicity, we expect that either of the
    /// following is true:
    /// 1. The token does not support metadata methods
    /// 2. The token supports it and returns a `bytes32` string there.
    /// 3. The token supports it and returns a correct `string` as a returndata.
    ///
    /// For all other cases, this function will panic and so such chains would not be
    /// deployable.
    /// @dev The `staticcall` the repository otherwise forbids is the mechanism itself here: it is
    /// what distinguishes "this token serves no metadata" from a genuine failure, and there is no
    /// typed call that can express the `bytes32`-returning (Maker-style) token.
    function _safeCallTokenMetadataBytes(address _token, bytes memory _data) private view returns (bytes memory, bool) {
        // We are not afraid if token returns large calldata, since it affects
        // only the deployment of the chain that uses such a malicious token.
        (bool callSuccess, bytes memory returnData) = _token.staticcall(_data);

        // The failed call most likely means that this method is not supported.
        if (!callSuccess) {
            return ("", false);
        }

        // This case covers non-standard tokens, such as Maker (MKR), that return `bytes32` instead of `string`
        if (returnData.length == 32) {
            return ("", false);
        }

        return (returnData, true);
    }

    function _safeCallTokenMetadataString(
        address _token,
        bytes memory _data
    ) private view returns (string memory, bool) {
        (bytes memory returnData, bool success) = _safeCallTokenMetadataBytes(_token, _data);
        if (!success) {
            return ("", false);
        }

        // Note, that the following line will panic in case the token has more non-standard behavior.
        return (abi.decode(returnData, (string)), true);
    }

    function _safeCallTokenMetadataUint256(address _token, bytes memory _data) private view returns (uint256, bool) {
        (bytes memory returnData, bool success) = _safeCallTokenMetadataBytes(_token, _data);
        if (!success) {
            return (0, false);
        }

        return (abi.decode(returnData, (uint256)), true);
    }
}
