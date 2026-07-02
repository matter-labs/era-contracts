// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @title InteropWithdrawalEncoding
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Deploy-script helper for building an L2->L1 asset withdrawal as an InteropCenter bundle.
/// @dev An L2->L1 withdrawal is a single-call interop bundle destined for L1: one indirect call to the
/// L2 AssetRouter carrying the bridgehub-deposit payload for the withdrawn asset. This is the unified
/// withdrawal path that replaced the removed `L2AssetRouter.withdraw` entrypoint.
library InteropWithdrawalEncoding {
    /// @notice Builds the single indirect-call `InteropCallStarter` for an L2->L1 asset withdrawal.
    /// @param _assetId The asset being withdrawn (ERC20 assetId, base-token assetId, or CTM assetId).
    /// @param _transferData The bridgehub-burn/transfer data for the asset.
    function withdrawalCallStarters(
        bytes32 _assetId,
        bytes memory _transferData
    ) internal pure returns (InteropCallStarter[] memory callStarters) {
        // No ETH value is delivered as an L1 call and none rides the bundle as base-token value:
        // both `interopCallValue` and the indirect-call message value are zero.
        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));

        callStarters = new InteropCallStarter[](1);
        callStarters[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
            data: DataEncoding.encodeAssetRouterBridgehubDepositData(_assetId, _transferData),
            callAttributes: callAttributes
        });
    }

    /// @notice ABI-encodes the `InteropCenter.sendBundle` call for an L2->L1 asset withdrawal.
    /// @dev Suitable as the L2 calldata of an L1->L2 admin transaction whose target is the
    /// `L2_INTEROP_CENTER_ADDR` on the source (settlement) chain.
    /// @param _l1ChainId The L1 chain id (bundle destination).
    /// @param _assetId The asset being withdrawn.
    /// @param _transferData The bridgehub-burn/transfer data for the asset.
    function encodeWithdrawalToL1Call(
        uint256 _l1ChainId,
        bytes32 _assetId,
        bytes memory _transferData
    ) internal pure returns (bytes memory) {
        return
            abi.encodeCall(
                IInteropCenter.sendBundle,
                (
                    InteroperableAddress.formatEvmV1(_l1ChainId),
                    withdrawalCallStarters(_assetId, _transferData),
                    new bytes[](0)
                )
            );
    }
}
