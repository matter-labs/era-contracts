// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CoreUpgrade_v33} from "deploy-scripts/upgrade/v33/CoreUpgrade_v33.s.sol";
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
contract CoreUpgradeParityHarness is CoreUpgrade_v33 {
    function setDiscoveredAddresses(address _l1Nullifier, address _l1AssetRouter, address _l1InteropHandler) external {
        coreAddresses.bridges.proxies.l1Nullifier = _l1Nullifier;
        coreAddresses.bridges.proxies.l1AssetRouter = _l1AssetRouter;
        coreAddresses.bridges.proxies.l1InteropHandler = _l1InteropHandler;
    }

    function deployVersionSpecific() external {
        deployVersionSpecificEcosystemContractsL1();
    }

    /// @dev The initializer the deploy step hands the handler's proxy. Exposed so a test can deploy a
    ///      proxy exactly as the script does and assert the resulting owner.
    function interopHandlerInitializer() external returns (bytes memory) {
        return getInitializeCalldata("L1InteropHandler", false);
    }

    function setOwner(address _owner) external {
        config.ownerAddress = _owner;
    }

    function buildInteropHandlerWiringCalls() external returns (Call[] memory) {
        return prepareVersionSpecificStage1GovernanceCallsL1();
    }

    /// @dev The state the deploy step leaves behind on a v31 ecosystem: the proxy it just created, plus
    ///      the flag that tells stage 1 the one-shot bridge setters still have to be issued. Set here
    ///      rather than by calling the deploy step, which needs the full script machinery (bytecode
    ///      publishing, a CREATE2 factory) that a unit test does not stand up.
    function setFreshlyDeployedInteropHandler(address _l1InteropHandler) external {
        coreAddresses.bridges.proxies.l1InteropHandler = _l1InteropHandler;
        deployedL1InteropHandler = true;
    }

    function getDiscoveredInteropHandlerProxy() external view returns (address) {
        return coreAddresses.bridges.proxies.l1InteropHandler;
    }

    function getDiscoveredInteropHandlerImplementation() external view returns (address) {
        return coreAddresses.bridges.implementations.l1InteropHandler;
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
        upgradeScript.setDiscoveredAddresses(address(l1Nullifier), address(assetRouter), address(0));
        // The v31 case: the deploy step created this proxy, so stage 1 owes the bridges their setters.
        upgradeScript.setFreshlyDeployedInteropHandler(address(interopHandler));

        Call[] memory calls = upgradeScript.buildInteropHandlerWiringCalls();
        // Two calls, not three: the deploy step initializes the handler's proxy straight to the
        // governance address, so there is no pending owner for stage 1 to accept.
        assertEq(calls.length, 2, "the two wirings");

        assertEq(l1Nullifier.l1InteropHandler(), address(0), "v31 nullifier starts unwired");
        assertEq(assetRouter.l1InteropHandler(), address(0), "v31 asset router starts unwired");

        _executeAsOwners(calls);

        assertEq(l1Nullifier.l1InteropHandler(), address(interopHandler), "nullifier wired to the handler");
        assertEq(assetRouter.l1InteropHandler(), address(interopHandler), "asset router wired to the handler");
    }

    /// @notice A handler deployed the way the script deploys it ends up owned by governance.
    /// @dev An outcome check, not a calldata one: the proxy is built with the initializer the script
    ///      supplies and then asked who owns it. That is the property the upgrade depends on — there
    ///      is no `acceptOwnership` in stage 1 to fall back on if the initializer is wrong.
    function test_deployedInteropHandlerIsOwnedByGovernance() public {
        upgradeScript.setOwner(owner);

        L1InteropHandler impl = new L1InteropHandler(IMessageRootBase(makeAddr("messageRoot")), address(assetRouter));
        L1InteropHandler deployed = L1InteropHandler(
            payable(
                new TransparentUpgradeableProxy(
                    address(impl),
                    makeAddr("proxyAdminForHandler"),
                    upgradeScript.interopHandlerInitializer()
                )
            )
        );

        assertEq(deployed.owner(), owner, "governance owns the handler with no further calls");
    }

    /// @notice An ecosystem that already has the handler keeps its proxy and only gets a new
    ///         implementation, and emits none of the one-shot wiring calls.
    /// @dev This is the shape a from-scratch deployment of these contracts has, which the integration
    ///      suite upgrades in place. Replacing the proxy would abandon the handler's state, and
    ///      re-issuing the setters would revert because both are one-shot — so the run must be a
    ///      no-op apart from refreshing the implementation behind the existing proxy.
    function test_refreshesImplementationWhenHandlerAlreadyExists() public {
        upgradeScript.setDiscoveredAddresses(address(l1Nullifier), address(assetRouter), address(interopHandler));

        upgradeScript.deployVersionSpecific();

        assertEq(
            upgradeScript.getDiscoveredInteropHandlerProxy(),
            address(interopHandler),
            "the existing handler proxy must be kept: it holds the handler's state"
        );
        address refreshedImpl = upgradeScript.getDiscoveredInteropHandlerImplementation();
        assertTrue(refreshedImpl != address(0), "a fresh implementation must be deployed");
        assertTrue(refreshedImpl != address(interopHandler), "the implementation is not the proxy");

        Call[] memory calls = upgradeScript.buildInteropHandlerWiringCalls();
        assertEq(calls.length, 0, "the one-shot setters must not be re-issued on an already-wired ecosystem");
    }

    function test_revertWhen_NoInteropHandlerAddress() public {
        // The handler must either be discovered or deployed by the upgrade; a zero address would silently
        // leave interop finalization dead.
        upgradeScript.setDiscoveredAddresses(address(l1Nullifier), address(assetRouter), address(0));

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
