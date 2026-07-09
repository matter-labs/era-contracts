// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";

/// @title L1AssetRouterReceiveMessageTest
/// @notice Unit tests for the interop entry points of `L1AssetRouter` (via the unified `AssetRouterBase.receiveMessage`):
/// only the configured L1 interop handler may drive it, and only a genuine cross-chain L2-asset-router sender is
/// accepted. `finalizeDeposit` is reachable only through the handler's self-call. The happy path is covered by the
/// integration/withdrawal suites; here we isolate the L1-specific access-control rejections.
contract L1AssetRouterReceiveMessageTest is Test {
    L1AssetRouter internal router;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal owner = makeAddr("owner");
    address internal interopHandler = makeAddr("interopHandler");

    uint256 internal constant ERA_CHAIN_ID = 9;
    uint256 internal constant SOURCE_CHAIN_ID = 271;

    function setUp() public {
        // The bridgehub/nullifier/vault deps are never reached on the access-control rejection paths, so mock
        // addresses suffice for this focused unit test.
        L1AssetRouter impl = new L1AssetRouter(
            makeAddr("weth"),
            makeAddr("bridgehub"),
            makeAddr("nullifier"),
            ERA_CHAIN_ID,
            makeAddr("eraDiamond")
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            proxyAdmin,
            abi.encodeWithSelector(L1AssetRouter.initialize.selector, owner)
        );
        router = L1AssetRouter(address(proxy));
        vm.prank(owner);
        router.setL1InteropHandler(interopHandler);
    }

    /// @notice Only the configured interop handler may call `receiveMessage`; any other caller is rejected.
    function test_receiveMessage_RevertWhen_CallerNotInteropHandler() public {
        bytes memory sender = InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, L2_ASSET_ROUTER_ADDR);
        // Called from the test contract (not the interop handler).
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        router.receiveMessage(bytes32(0), sender, hex"");
    }

    /// @notice A sender that is not the L2 asset router is rejected, even coming through the interop handler.
    function test_receiveMessage_RevertWhen_InteropSenderNotL2AssetRouter() public {
        address wrongSender = makeAddr("wrongSender");
        bytes memory sender = InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, wrongSender);
        vm.prank(interopHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, wrongSender));
        router.receiveMessage(bytes32(0), sender, hex"");
    }

    /// @notice A withdrawal must originate on another chain: a same-chain (L1) source is rejected even when the
    /// sender address is the canonical L2 asset router.
    function test_receiveMessage_RevertWhen_InteropSenderSameChain() public {
        bytes memory sender = InteroperableAddress.formatEvmV1(block.chainid, L2_ASSET_ROUTER_ADDR);
        vm.prank(interopHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, L2_ASSET_ROUTER_ADDR));
        router.receiveMessage(bytes32(0), sender, hex"");
    }

    /// @notice `finalizeDeposit` is guarded by `onlySelf`: it is reachable only via `receiveMessage`'s self-call,
    /// never directly.
    function test_finalizeDeposit_RevertWhen_NotSelf() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        router.finalizeDeposit(SOURCE_CHAIN_ID, bytes32(0), hex"");
    }
}
