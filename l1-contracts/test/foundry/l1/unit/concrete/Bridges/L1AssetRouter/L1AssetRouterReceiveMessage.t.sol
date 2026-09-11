// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    InteropSenderChainIdMismatch,
    InvalidSelector,
    PayloadTooShort,
    Unauthorized
} from "contracts/common/L1ContractErrors.sol";

/// @notice Native-token-vault stand-in whose `bridgeMint` always reverts with a sentinel error. Registered as the
/// asset handler so a `finalizeDeposit` reverts deterministically, letting us assert that `receiveMessage` bubbles
/// the inner revert reason.
contract MockRevertingAssetHandler {
    error HandlerReverted();

    function bridgeMint(uint256, bytes32, bytes calldata) external payable {
        revert HandlerReverted();
    }
}

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

    uint256 internal constant SOURCE_CHAIN_ID = 271;

    function setUp() public {
        // The bridgehub/nullifier/vault deps are never reached on the access-control rejection paths, so mock
        // addresses suffice for this focused unit test.
        L1AssetRouter impl = new L1AssetRouter(makeAddr("weth"), makeAddr("bridgehub"), makeAddr("nullifier"));
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

    /// @notice The interop payload must be long enough to hold a `finalizeDeposit` selector plus its first
    /// (`_sourceChainId`) word — at least 4 + 32 bytes.
    function test_receiveMessage_RevertWhen_PayloadTooShort() public {
        bytes memory sender = InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, L2_ASSET_ROUTER_ADDR);
        vm.prank(interopHandler);
        vm.expectRevert(PayloadTooShort.selector);
        router.receiveMessage(bytes32(0), sender, hex"12345678"); // 4 bytes; the check requires >= 36
    }

    /// @notice Only a `finalizeDeposit` payload may ride through the interop system: a long-enough payload
    /// carrying any other selector is rejected.
    function test_receiveMessage_RevertWhen_InvalidSelector() public {
        bytes4 bogusSelector = bytes4(0xdeadbeef);
        // Well-formed length (selector + args), wrong selector.
        bytes memory payload = abi.encodeWithSelector(bogusSelector, SOURCE_CHAIN_ID, bytes32(0), hex"");
        bytes memory sender = InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, L2_ASSET_ROUTER_ADDR);

        vm.prank(interopHandler);
        vm.expectRevert(abi.encodeWithSelector(InvalidSelector.selector, bogusSelector));
        router.receiveMessage(bytes32(0), sender, payload);
    }

    /// @notice The authenticated interop-message sender chain id must match the `_sourceChainId` the deposit is
    /// finalized under. A payload whose `_sourceChainId` differs from the sender's chain id is rejected.
    function test_receiveMessage_RevertWhen_SenderChainIdMismatch() public {
        uint256 payloadSourceChainId = SOURCE_CHAIN_ID + 1;
        bytes memory payload = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (payloadSourceChainId, router.ETH_TOKEN_ASSET_ID(), hex"")
        );
        bytes memory sender = InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, L2_ASSET_ROUTER_ADDR);

        vm.prank(interopHandler);
        vm.expectRevert(
            abi.encodeWithSelector(InteropSenderChainIdMismatch.selector, SOURCE_CHAIN_ID, payloadSourceChainId)
        );
        router.receiveMessage(bytes32(0), sender, payload);
    }

    /// @notice Regression: `receiveMessage` bubbles the inner `finalizeDeposit` revert verbatim instead of masking
    /// it, so callers can react to the specific reason (the token-balance-migration flow retries withdrawals on
    /// `InsufficientChainBalance`). Here the registered handler reverts with a sentinel that must propagate.
    function test_receiveMessage_BubblesInnerRevert() public {
        MockRevertingAssetHandler ntv = new MockRevertingAssetHandler();
        vm.prank(owner);
        router.setNativeTokenVault(INativeTokenVaultBase(address(ntv)));

        bytes memory payload = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (SOURCE_CHAIN_ID, router.ETH_TOKEN_ASSET_ID(), hex"")
        );
        bytes memory sender = InteroperableAddress.formatEvmV1(SOURCE_CHAIN_ID, L2_ASSET_ROUTER_ADDR);

        vm.prank(interopHandler);
        vm.expectRevert(MockRevertingAssetHandler.HandlerReverted.selector);
        router.receiveMessage(bytes32(0), sender, payload);
    }
}
