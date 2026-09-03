// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract L2AssetRouterUpdateL2Test is Test {
    /// @dev Slot reported by `forge inspect L2AssetRouter storage-layout`.
    uint256 internal constant DEPRECATED_ERA_CHAIN_ID_SLOT = 253;
    uint256 internal constant L1_CHAIN_ID = 1;

    L2AssetRouter internal router;

    function setUp() external {
        router = new L2AssetRouter();
    }

    function test_updateL2_leavesDeprecatedEraChainIdSlotUnused() external {
        address l1AssetRouter = makeAddr("l1AssetRouter");
        bytes32 baseTokenAssetId = keccak256("baseTokenAssetId");

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        router.updateL2(L1_CHAIN_ID, IL1AssetRouter(l1AssetRouter), baseTokenAssetId, address(0));

        assertEq(router.L1_CHAIN_ID(), L1_CHAIN_ID);
        assertEq(address(router.L1_ASSET_ROUTER()), l1AssetRouter);
        assertEq(router.BASE_TOKEN_ASSET_ID(), baseTokenAssetId);
        assertEq(vm.load(address(router), bytes32(DEPRECATED_ERA_CHAIN_ID_SLOT)), bytes32(0));
    }
}
