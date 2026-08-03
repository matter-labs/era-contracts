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
import {BridgehubBase} from "contracts/core/bridgehub/BridgehubBase.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

/// @dev Exposes the pre-v32 parity call builder and lets the test place the discovered addresses, which the
/// script normally fills in from on-chain introspection.
contract CoreUpgradeParityHarness is CoreUpgrade_v31 {
    function setDiscoveredAddresses(
        address _bridgehub,
        address _l1Nullifier,
        address _l1AssetRouter,
        address _l1InteropHandler,
        address _chainRegistrationSender,
        bool _deployedL1InteropHandler
    ) external {
        coreAddresses.bridgehub.proxies.bridgehub = _bridgehub;
        coreAddresses.bridges.proxies.l1Nullifier = _l1Nullifier;
        coreAddresses.bridges.proxies.l1AssetRouter = _l1AssetRouter;
        coreAddresses.bridges.proxies.l1InteropHandler = _l1InteropHandler;
        coreAddresses.bridgehub.proxies.chainRegistrationSender = _chainRegistrationSender;
        deployedL1InteropHandler = _deployedL1InteropHandler;
    }

    function buildPreV32ParityCalls() external returns (Call[] memory) {
        return _buildPreV32ParityCalls();
    }
}

/// @notice Covers the stage-1 calls that bring a v31 ecosystem to the wiring a from-scratch v32 deployment
/// has: the interop handler (new in v32) and the bridgehub's `chainRegistrationSender`.
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

    function _mockBridgehubChainRegistrationSender(address _value) internal {
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainRegistrationSender.selector),
            abi.encode(_value)
        );
    }

    function _executeAsOwners(Call[] memory _calls) internal {
        for (uint256 i = 0; i < _calls.length; ++i) {
            // Governance owns the bridges; the interop handler's pending owner is governance too. The
            // bridgehub call is mocked away, so it is executed against the mock.
            vm.prank(owner);
            (bool success, bytes memory returnData) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            if (!success) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
    }

    function test_wiresTheNewInteropHandlerAndTheRegistrationSender() public {
        // Ownership of the freshly deployed handler is pending for governance, as the deploy step leaves it.
        interopHandler.transferOwnership(owner);
        _mockBridgehubChainRegistrationSender(address(0));

        upgradeScript.setDiscoveredAddresses(
            bridgehub,
            address(l1Nullifier),
            address(assetRouter),
            address(interopHandler),
            chainRegistrationSender,
            true
        );

        Call[] memory calls = upgradeScript.buildPreV32ParityCalls();
        assertEq(calls.length, 4, "handler ownership + two wirings + the registration sender");

        assertEq(l1Nullifier.l1InteropHandler(), address(0), "v31 nullifier starts unwired");
        assertEq(assetRouter.l1InteropHandler(), address(0), "v31 asset router starts unwired");

        // The bridgehub is a mock, so assert its call separately and execute the rest for real.
        assertEq(calls[3].target, bridgehub, "registration sender call goes to the bridgehub");
        assertEq(
            calls[3].data,
            abi.encodeCall(BridgehubBase.setAddressesV31, (chainRegistrationSender)),
            "registration sender is passed to the bridgehub"
        );

        Call[] memory bridgeCalls = new Call[](3);
        for (uint256 i = 0; i < 3; ++i) {
            bridgeCalls[i] = calls[i];
        }
        _executeAsOwners(bridgeCalls);

        assertEq(interopHandler.owner(), owner, "handler ownership accepted by governance");
        assertEq(l1Nullifier.l1InteropHandler(), address(interopHandler), "nullifier wired to the handler");
        assertEq(assetRouter.l1InteropHandler(), address(interopHandler), "asset router wired to the handler");
    }

    function test_emitsNothingForAnAlreadyUpgradedEcosystem() public {
        // Re-running the upgrade on a v32 ecosystem: the handler already exists (so the script did not
        // deploy one) and the bridgehub already knows the registration sender.
        _mockBridgehubChainRegistrationSender(chainRegistrationSender);

        upgradeScript.setDiscoveredAddresses(
            bridgehub,
            address(l1Nullifier),
            address(assetRouter),
            address(interopHandler),
            chainRegistrationSender,
            false
        );

        assertEq(upgradeScript.buildPreV32ParityCalls().length, 0, "nothing left to wire");
    }

    function test_onlyRegistersTheSenderWhenTheHandlerAlreadyExists() public {
        // An ecosystem that reached v32 without ever having `setAddresses` run: the handler is wired but
        // the bridgehub's registration sender is not.
        _mockBridgehubChainRegistrationSender(address(0));

        upgradeScript.setDiscoveredAddresses(
            bridgehub,
            address(l1Nullifier),
            address(assetRouter),
            address(interopHandler),
            chainRegistrationSender,
            false
        );

        Call[] memory calls = upgradeScript.buildPreV32ParityCalls();
        assertEq(calls.length, 1, "only the registration sender is missing");
        assertEq(calls[0].target, bridgehub);
    }

    function test_revertWhen_NoInteropHandlerAddress() public {
        // The handler must either be discovered or deployed by the upgrade; a zero address would silently
        // leave interop finalization dead.
        _mockBridgehubChainRegistrationSender(chainRegistrationSender);

        upgradeScript.setDiscoveredAddresses(
            bridgehub,
            address(l1Nullifier),
            address(assetRouter),
            address(0),
            chainRegistrationSender,
            false
        );

        vm.expectRevert("L1InteropHandler proxy not deployed");
        upgradeScript.buildPreV32ParityCalls();
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

        BridgesDeployedAddresses memory bridges = AddressIntrospector.getBridgesDeployedAddressesV29(
            address(assetRouter)
        );

        assertEq(bridges.proxies.l1Nullifier, address(l1Nullifier), "nullifier still discovered");
        assertEq(bridges.proxies.l1InteropHandler, address(0), "handler reported as absent");
        assertEq(bridges.implementations.l1InteropHandler, address(0), "no implementation either");
    }

    function test_discovery_v32PathNeedsTheInteropHandlerGetter() public {
        // The same discovery a v32 ecosystem uses cannot be applied to a v31 one: it reads a getter that
        // only exists from v32 on. This is what made the upgrade impossible to prepare.
        _makeNullifierLookPreV32();

        vm.expectRevert();
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
