// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AddressIntrospector} from "deploy-scripts/utils/AddressIntrospector.sol";
import {BridgesDeployedAddresses} from "deploy-scripts/utils/Types.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";

/// @notice Bridge discovery used by the default upgrade scripts: the interop handler is read off the nullifier
///         (`l1InteropHandler()`), and its implementation is resolved behind its proxy.
/// @dev Real nullifier, asset router and interop handler proxies are deployed. Only the native token vault is
///      mocked: discovery merely walks through it to the bridged-token beacon, and standing up a full vault is
///      unrelated to what is under test here.
contract AddressIntrospectorBridgesTest is Test {
    L1Nullifier internal l1Nullifier;
    L1AssetRouter internal assetRouter;
    L1InteropHandler internal interopHandler;

    address internal owner;

    function setUp() public {
        owner = makeAddr("owner");
        address bridgehub = makeAddr("bridgehub");
        address proxyAdmin = makeAddr("proxyAdmin");
        address messageRoot = makeAddr("messageRoot");

        L1NullifierDev nullifierImpl = new L1NullifierDev({
            _bridgehub: IL1Bridgehub(bridgehub),
            _messageRoot: IMessageRootBase(messageRoot)
        });
        l1Nullifier = L1Nullifier(
            payable(
                new TransparentUpgradeableProxy(
                    address(nullifierImpl),
                    proxyAdmin,
                    abi.encodeCall(L1Nullifier.initialize, (owner))
                )
            )
        );

        L1AssetRouter assetRouterImpl = new L1AssetRouter({
            _l1WethToken: makeAddr("weth"),
            _bridgehub: bridgehub,
            _l1Nullifier: address(l1Nullifier)
        });
        assetRouter = L1AssetRouter(
            payable(
                new TransparentUpgradeableProxy(
                    address(assetRouterImpl),
                    proxyAdmin,
                    abi.encodeCall(L1AssetRouter.initialize, (owner))
                )
            )
        );

        L1InteropHandler interopHandlerImpl = new L1InteropHandler(IMessageRootBase(messageRoot), address(assetRouter));
        interopHandler = L1InteropHandler(
            payable(
                new TransparentUpgradeableProxy(
                    address(interopHandlerImpl),
                    proxyAdmin,
                    abi.encodeCall(L1InteropHandler.initialize, (owner))
                )
            )
        );

        address nativeTokenVault = makeAddr("nativeTokenVault");
        vm.mockCall(address(assetRouter), abi.encodeWithSignature("nativeTokenVault()"), abi.encode(nativeTokenVault));
        vm.mockCall(nativeTokenVault, abi.encodeWithSignature("bridgedTokenBeacon()"), abi.encode(address(0)));
    }

    function test_discoversTheInteropHandlerWiredIntoTheNullifier() public {
        BridgesDeployedAddresses memory bridges = AddressIntrospector.getBridgesDeployedAddresses(address(assetRouter));
        assertEq(bridges.proxies.l1Nullifier, address(l1Nullifier), "nullifier discovered");
        assertEq(bridges.proxies.l1InteropHandler, address(0), "unwired ecosystem reports no handler");
        assertEq(bridges.implementations.l1InteropHandler, address(0), "no implementation for an absent handler");

        vm.prank(owner);
        l1Nullifier.setL1InteropHandler(address(interopHandler));

        bridges = AddressIntrospector.getBridgesDeployedAddresses(address(assetRouter));
        assertEq(bridges.proxies.l1InteropHandler, address(interopHandler), "wired handler discovered");
        assertEq(
            bridges.implementations.l1InteropHandler,
            Utils.getImplementation(address(interopHandler)),
            "implementation resolved behind the proxy"
        );
    }

    /// @dev A nullifier without the `l1InteropHandler()` getter (an ecosystem older than v33) is not supported:
    ///      discovery fails loudly instead of reporting the handler as absent.
    function test_revertWhen_NullifierHasNoInteropHandlerGetter() public {
        vm.mockCallRevert(address(l1Nullifier), abi.encodeWithSignature("l1InteropHandler()"), "no getter");

        vm.expectRevert("no getter");
        AddressIntrospector.getBridgesDeployedAddresses(address(assetRouter));
    }
}
