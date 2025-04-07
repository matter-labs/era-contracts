// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1SharedBridgeLegacy} from "../bridge/interfaces/IL1SharedBridgeLegacy.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";
import {ZKChainSpecificForceDeploymentsData} from "../state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {ZKChainStorage} from "../state-transition/chain-deps/ZKChainStorage.sol";

import {L2WrappedBaseTokenStore} from "../bridge/L2WrappedBaseTokenStore.sol";
import {IERC20Metadata} from "@openzeppelin/contracts-v4/token/ERC20/extensions/IERC20Metadata.sol";

import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";

/// @title L1FixedForceDeploymentsHelper
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
abstract contract L1FixedForceDeploymentsHelper {
    using UnsafeBytes for bytes;

    /// @notice The function to retrieve the chain-specific upgrade data.
    /// @param s The pointer to the storage of the chain.
    /// @param _wrappedBaseTokenStore The address of the `L2WrappedBaseTokenStore` contract.
    /// It is expected to be zero during creation of new chains and non-zero during upgrades.
    /// @param _baseTokenAddress The L1 address of the base token of the chain. Note, that for
    /// chains whose token originates from an L2, this address will be the address of its bridged
    /// representation on L1.
    function getZKChainSpecificForceDeploymentsData(
        ZKChainStorage storage s,
        address _wrappedBaseTokenStore,
        address _baseTokenAddress
    ) internal view returns (bytes memory) {
        address sharedBridge = IBridgehub(s.bridgehub).sharedBridge();
        address legacySharedBridge = IL1SharedBridgeLegacy(sharedBridge).l2BridgeAddress(s.chainId);

        address l2WBaseToken;
        if (_wrappedBaseTokenStore != address(0)) {
            l2WBaseToken = L2WrappedBaseTokenStore(_wrappedBaseTokenStore).l2WBaseTokenAddress(s.chainId);
        }

        // It is required for a base token to implement the following methods
        string memory baseTokenName;
        string memory baseTokenSymbol;
        if (_baseTokenAddress == ETH_TOKEN_ADDRESS) {
            baseTokenName = string("Ether");
            baseTokenSymbol = string("ETH");
        } else {
            (string memory stringResult, bool success) = _safeCallTokenMetadata(
                _baseTokenAddress,
                abi.encodeCall(IERC20Metadata.name, ())
            );
            if (success) {
                baseTokenName = stringResult;
            } else {
                baseTokenName = string("Base Token");
            }

            (stringResult, success) = _safeCallTokenMetadata(
                _baseTokenAddress,
                abi.encodeCall(IERC20Metadata.symbol, ())
            );
            if (success) {
                baseTokenSymbol = stringResult;
            } else {
                // "BT" is an acronym for "Base Token"
                baseTokenSymbol = string("BT");
            }
        }

        ZKChainSpecificForceDeploymentsData
            memory additionalForceDeploymentsData = ZKChainSpecificForceDeploymentsData({
                baseTokenAssetId: s.baseTokenAssetId,
                l2LegacySharedBridge: legacySharedBridge,
                predeployedL2WethAddress: l2WBaseToken,
                baseTokenL1Address: _baseTokenAddress,
                baseTokenName: baseTokenName,
                baseTokenSymbol: baseTokenSymbol
            });
        return abi.encode(additionalForceDeploymentsData);
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
    function _safeCallTokenMetadata(address _token, bytes memory data) internal view returns (string memory, bool) {
        // We are not afraid if token returns large calldata, since it affects
        // only the deployment of the chain that uses such a malicious token.
        (bool callSuccess, bytes memory returnData) = _token.staticcall(data);

        // The failed call most likely means that this method is not supported.
        if (!callSuccess) {
            return ("", false);
        }

        // This case covers non-standard tokens, such as Maker (MKR), that return `bytes32` instead of `string`
        if (returnData.length == 32) {
            return ("", false);
        }

        // Note, that the following line will panic in case the token has more non-standard behavior.
        return (abi.decode(returnData, (string)), true);
    }
}
