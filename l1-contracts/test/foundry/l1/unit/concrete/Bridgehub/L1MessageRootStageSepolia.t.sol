// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {
    L1MessageRootStageSepolia,
    STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID
} from "contracts/dev-contracts/L1MessageRootStageSepolia.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE} from "contracts/core/message-root/IMessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {NotAllChainsOnL1} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

/// @notice Stage Sepolia variant: confirms `_v31InitializeInner` skips chain 270
///         (still on stage Gateway 123 at upgrade time) but still requires every
///         other registered chain to be settling on L1.
contract L1MessageRootStageSepoliaTest is Test {
    address bridgehub;
    address chainAssetHandler;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
        chainAssetHandler = makeAddr("chainAssetHandler");
    }

    function _deploy(uint256[] memory _chainIds) internal returns (L1MessageRootStageSepolia) {
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(_chainIds)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        return
            L1MessageRootStageSepolia(
                address(
                    new TransparentUpgradeableProxy(
                        address(new L1MessageRootStageSepolia(bridgehub, 123, chainAssetHandler)),
                        address(uint160(1)),
                        abi.encodeCall(L1MessageRoot.initializeL1V31Upgrade, ())
                    )
                )
            );
    }

    function test_skipsStageEraChain270() public {
        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID; // 270 — still on GW 123
        chainIds[1] = 2702; // Atlas, on L1

        // 270's settlement layer is the GW (123), not L1 — but the variant must skip it.
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID),
            abi.encode(uint256(123))
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, uint256(2702)),
            abi.encode(block.chainid)
        );

        L1MessageRootStageSepolia mr = _deploy(chainIds);

        // 270 keeps the zero default — the chain stamps the slot itself once it migrates back.
        assertEq(mr.v31UpgradeChainBatchNumber(STAGE_SEPOLIA_NON_MIGRATED_ERA_CHAIN_ID), 0);
        // 2702 gets the canonical placeholder.
        assertEq(mr.v31UpgradeChainBatchNumber(2702), V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE);
    }

    function test_revertsWhenNonExemptChainOffL1() public {
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = 9999; // arbitrary non-exempt chain on Gateway

        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(chainIds)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, uint256(9999)),
            abi.encode(uint256(123))
        );
        address impl = address(new L1MessageRootStageSepolia(bridgehub, 123, chainAssetHandler));

        vm.expectRevert(NotAllChainsOnL1.selector);
        new TransparentUpgradeableProxy(
            impl,
            address(uint160(1)),
            abi.encodeCall(L1MessageRoot.initializeL1V31Upgrade, ())
        );
    }
}
