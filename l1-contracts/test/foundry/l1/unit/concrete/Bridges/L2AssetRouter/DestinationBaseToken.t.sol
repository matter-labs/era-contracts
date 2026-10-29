// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {L2_BRIDGEHUB_ADDR, L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract L2AssetRouterDestinationBaseTokenHarness is L2AssetRouter {
    function destinationBaseTokenAssetId(uint256 _chainId) external view returns (bytes32) {
        return _destinationBaseTokenAssetId(_chainId);
    }
}

/// @notice Where `L2AssetRouter` takes a destination's base token from for the `AssetIdNotSupported` check.
/// See {protocol-docs/l1sload.md#the-base-token-snapshot}.
/// @dev The L2 Bridgehub is mocked to isolate the router's choice of source; the L1 reads behind
/// `interopBaseTokenAssetId` are covered by `L2BridgehubL1Reads.t.sol`.
contract L2AssetRouterDestinationBaseTokenTest is Test {
    uint256 internal constant L1_CHAIN_ID = 1;
    uint256 internal constant PEER_CHAIN_ID = 271;

    L2AssetRouterDestinationBaseTokenHarness internal router;

    function setUp() external {
        router = new L2AssetRouterDestinationBaseTokenHarness();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        router.updateL2(L1_CHAIN_ID, IL1AssetRouter(makeAddr("l1AssetRouter")), keccak256("ownBaseToken"), address(0));
        vm.etch(L2_BRIDGEHUB_ADDR, hex"00");
    }

    function test_peerUsesTheL1Snapshot() external {
        bytes32 snapshot = keccak256("peerBaseToken");
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IL2Bridgehub.interopBaseTokenAssetId, (PEER_CHAIN_ID)),
            abi.encode(snapshot)
        );
        vm.expectCall(L2_BRIDGEHUB_ADDR, abi.encodeCall(IBridgehubBase.baseTokenAssetId, (PEER_CHAIN_ID)), 0);

        assertEq(router.destinationBaseTokenAssetId(PEER_CHAIN_ID), snapshot);
    }

    function test_l1KeepsTheLocalEntry() external {
        bytes32 localEntry = keccak256("l1Entry");
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (L1_CHAIN_ID)),
            abi.encode(localEntry)
        );
        vm.expectCall(L2_BRIDGEHUB_ADDR, abi.encodeCall(IL2Bridgehub.interopBaseTokenAssetId, (L1_CHAIN_ID)), 0);

        assertEq(router.destinationBaseTokenAssetId(L1_CHAIN_ID), localEntry);
    }
}
