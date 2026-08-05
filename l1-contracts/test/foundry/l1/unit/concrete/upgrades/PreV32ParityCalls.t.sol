// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CoreUpgrade_v31} from "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
import {AddressIntrospector} from "deploy-scripts/utils/AddressIntrospector.sol";
import {BridgesDeployedAddresses} from "deploy-scripts/utils/Types.sol";

import {Call} from "contracts/governance/Common.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {L1InteropHandler} from "contracts/interop/interop-handler/L1InteropHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

/// @dev Exposes the pre-v32 parity call builder and lets the test place the discovered addresses, which the
/// script normally fills in from on-chain introspection.
contract CoreUpgradeParityHarness is CoreUpgrade_v31 {
    function setDiscoveredAddresses(
        address _l1Nullifier,
        address _l1AssetRouter,
        address _l1InteropHandler,
        bool _deployedL1InteropHandler
    ) external {
        coreAddresses.bridges.proxies.l1Nullifier = _l1Nullifier;
        coreAddresses.bridges.proxies.l1AssetRouter = _l1AssetRouter;
        coreAddresses.bridges.proxies.l1InteropHandler = _l1InteropHandler;
        deployedL1InteropHandler = _deployedL1InteropHandler;
    }

    function buildInteropHandlerWiringCalls() external returns (Call[] memory) {
        return _buildL1InteropHandlerWiringCalls();
    }
}

/// @notice Covers the stage-1 calls that bring a v31 ecosystem to the wiring a from-scratch v32 deployment
/// has: the interop handler, which is new in v32.
contract PreV32ParityCallsTest is Test {
    CoreUpgradeParityHarness internal upgradeScript;
    L1Nullifier internal l1Nullifier;
    L1AssetRouter internal assetRouter;
    L1InteropHandler internal interopHandler;

    address internal owner;
    address internal bridgehub;
    address internal chainRegistrationSender;

    function setUp() public {
        owner = makeAddr("owner");
        bridgehub = makeAddr("bridgehub");
        chainRegistrationSender = makeAddr("chainRegistrationSender");
        address proxyAdmin = makeAddr("proxyAdmin");
        address messageRoot = makeAddr("messageRoot");
        uint256 eraChainId = 9;
        address eraDiamondProxy = makeAddr("eraDiamondProxy");

        // A v31-shaped pair of bridges: deployed and initialized, but with no interop handler, since that
        // storage only exists from v32 on.
        L1NullifierDev nullifierImpl = new L1NullifierDev({
            _bridgehub: IL1Bridgehub(bridgehub),
            _messageRoot: IMessageRootBase(messageRoot),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
        });
        l1Nullifier = L1Nullifier(
            payable(
                new TransparentUpgradeableProxy(
                    address(nullifierImpl),
                    proxyAdmin,
                    abi.encodeCall(L1Nullifier.initialize, (owner, 1, 1, 1, 0))
                )
            )
        );

        L1AssetRouter assetRouterImpl = new L1AssetRouter({
            _l1WethToken: makeAddr("weth"),
            _bridgehub: bridgehub,
            _l1Nullifier: address(l1Nullifier),
            _eraChainId: eraChainId,
            _eraDiamondProxy: eraDiamondProxy
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
                    abi.encodeCall(L1InteropHandler.initialize, (address(this)))
                )
            )
        );

        upgradeScript = new CoreUpgradeParityHarness();
    }

    function _executeAsOwners(Call[] memory _calls) internal {
        for (uint256 i = 0; i < _calls.length; ++i) {
            // Governance owns the bridges, and the interop handler's pending owner is governance too.
            vm.prank(owner);
            (bool success, bytes memory returnData) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            if (!success) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
    }

    function test_wiresTheNewInteropHandler() public {
        // Ownership of the freshly deployed handler is pending for governance, as the deploy step leaves it.
        interopHandler.transferOwnership(owner);

        upgradeScript.setDiscoveredAddresses(address(l1Nullifier), address(assetRouter), address(interopHandler), true);

        Call[] memory calls = upgradeScript.buildInteropHandlerWiringCalls();
        assertEq(calls.length, 3, "handler ownership + the two wirings");

        assertEq(l1Nullifier.l1InteropHandler(), address(0), "v31 nullifier starts unwired");
        assertEq(assetRouter.l1InteropHandler(), address(0), "v31 asset router starts unwired");

        _executeAsOwners(calls);

        assertEq(interopHandler.owner(), owner, "handler ownership accepted by governance");
        assertEq(l1Nullifier.l1InteropHandler(), address(interopHandler), "nullifier wired to the handler");
        assertEq(assetRouter.l1InteropHandler(), address(interopHandler), "asset router wired to the handler");
    }

    function test_emitsNothingForAnAlreadyUpgradedEcosystem() public {
        // Re-running the upgrade on a v32 ecosystem: the handler already exists, so the script did not
        // deploy one and emits no wiring calls.

        upgradeScript.setDiscoveredAddresses(
            address(l1Nullifier),
            address(assetRouter),
            address(interopHandler),
            false
        );

        assertEq(upgradeScript.buildInteropHandlerWiringCalls().length, 0, "nothing left to wire");
    }

    function test_revertWhen_NoInteropHandlerAddress() public {
        // The handler must either be discovered or deployed by the upgrade; a zero address would silently
        // leave interop finalization dead.
        upgradeScript.setDiscoveredAddresses(address(l1Nullifier), address(assetRouter), address(0), false);

        vm.expectRevert("L1InteropHandler proxy not deployed");
        upgradeScript.buildInteropHandlerWiringCalls();
    }

    /*//////////////////////////////////////////////////////////////
                        v31 address discovery
    //////////////////////////////////////////////////////////////*/

    /// @dev Discovery walks from the asset router to the vault; this fixture has no vault, so stand one in.
    function _mockNativeTokenVaultForDiscovery() internal {
        address nativeTokenVault = makeAddr("nativeTokenVault");
        vm.mockCall(address(assetRouter), abi.encodeWithSignature("nativeTokenVault()"), abi.encode(nativeTokenVault));
        vm.mockCall(nativeTokenVault, abi.encodeWithSignature("bridgedTokenBeacon()"), abi.encode(address(0)));
    }

    /// @dev A v31 nullifier has no `l1InteropHandler()` at all, which a call into the missing function
    /// surfaces as a revert — exactly what the version-aware discovery has to avoid.
    function _makeNullifierLookPreV32() internal {
        vm.mockCallRevert(
            address(l1Nullifier),
            abi.encodeWithSignature("l1InteropHandler()"),
            "function does not exist"
        );
    }

    function test_discovery_v31PathSkipsTheInteropHandlerGetter() public {
        _mockNativeTokenVaultForDiscovery();
        _makeNullifierLookPreV32();

        BridgesDeployedAddresses memory bridges = AddressIntrospector.getBridgesDeployedAddressesV31(
            address(assetRouter)
        );

        assertEq(bridges.proxies.l1Nullifier, address(l1Nullifier), "nullifier still discovered");
        assertEq(bridges.proxies.l1InteropHandler, address(0), "handler reported as absent");
        assertEq(bridges.implementations.l1InteropHandler, address(0), "no implementation either");
    }

    function test_discovery_v32PathNeedsTheInteropHandlerGetter() public {
        // The same discovery a v32 ecosystem uses cannot be applied to a v31 one: it reads a getter that
        // only exists from v32 on. This is what made the upgrade impossible to prepare.
        _mockNativeTokenVaultForDiscovery();
        _makeNullifierLookPreV32();

        vm.expectRevert("function does not exist");
        AddressIntrospector.getBridgesDeployedAddresses(address(assetRouter));
    }

    function test_discovery_v32PathIsUsedOnceTheGetterExists() public {
        _mockNativeTokenVaultForDiscovery();

        BridgesDeployedAddresses memory bridges = AddressIntrospector.getBridgesDeployedAddresses(address(assetRouter));
        assertEq(bridges.proxies.l1InteropHandler, address(0), "unwired ecosystem reports no handler");

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

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
