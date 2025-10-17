// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {L2_ASSET_ROUTER_ADDR, L2_INTEROP_CENTER_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {NEW_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {IInteropCenter} from "contracts/interop/InteropCenter.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "@openzeppelin/contracts-master/utils/draft-InteroperableAddress.sol";
import {AmountMustBeGreaterThanZero, ZeroAddress} from "contracts/common/L1ContractErrors.sol";

library InteropLibrary {
    address internal constant UNBUNDLER_ADDRESS = address(0x1);

    IL2NativeTokenVault internal constant l2NativeTokenVault = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
    IInteropCenter internal constant l2InteropCenter = IInteropCenter(L2_INTEROP_CENTER_ADDR);

    /*//////////////////////////////////////////////////////////////
                               BUILDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Build the “second bridge” calldata:
    ///         bytes.concat(NEW_ENCODING_VERSION, abi.encode(l2TokenAssetId, abi.encode(amount, receiver, fee)))
    function buildSecondBridgeCalldata(
        bytes32 l2TokenAssetId,
        uint256 amount,
        address receiver,
        uint256 fee
    ) internal pure returns (bytes memory) {
        // Inner payload: abi.encode(amount, receiver, fee)
        bytes memory inner = abi.encode(amount, receiver, fee);
        // Outer: abi.encode(l2TokenAssetId, inner), prefixed by version byte
        return bytes.concat(NEW_ENCODING_VERSION, abi.encode(l2TokenAssetId, inner));
    }

    /// @notice Create a single Interop call to the L2 asset router with the 7786 "indirectCall" attribute set.
    function buildSecondBridgeCall(
        bytes memory secondBridgeCalldata
    ) internal pure returns (InteropCallStarter memory) {
        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (uint256(0)));
        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
                data: secondBridgeCalldata,
                callAttributes: callAttributes
            });
    }

    /// @notice Bundle-level attributes.
    function buildBundleAttributes() internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ONE-SHOT SENDER
    //////////////////////////////////////////////////////////////*/

    /// @notice Build and send a token transfer bundle in one go.
    /// @param destination       Interoperable chain identifier (e.g., InteroperableAddress.formatEvmV1(271))
    /// @param l2TokenAddress    Address of token on L2
    /// @param amount            Amount to transfer
    /// @param receiver          Recipient on destination chain
    function sendToken(
        uint256 destination,
        address l2TokenAddress,
        uint256 amount,
        address receiver
    ) internal returns (bytes32 bundleHash) {
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        if (receiver == address(0)) {
            revert ZeroAddress();
        }

        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        bytes memory secondBridgeCalldata = buildSecondBridgeCalldata(
            l2TokenAssetId,
            amount,
            receiver,
            0 // fee
        );

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = buildSecondBridgeCall(secondBridgeCalldata);

        bytes[] memory bundleAttrs = buildBundleAttributes();

        return l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(destination), calls, bundleAttrs);
    }
}
