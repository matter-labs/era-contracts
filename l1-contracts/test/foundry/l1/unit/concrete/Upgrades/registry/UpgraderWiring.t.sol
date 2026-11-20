// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {CTMDeploymentTracker} from "contracts/core/ctm-deployment/CTMDeploymentTracker.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {DefaultProxyUpgradeEngine} from "contracts/upgrades/registry/engines/DefaultProxyUpgradeEngine.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {IProxyUpgradeTransition} from "contracts/upgrades/registry/objects/IProxyUpgradeTransition.sol";
import {
    ProxyUpgradeContext,
    ProxyUpgradeDomain,
    ProxyUpgradeRow,
    ProxyUpgradeTransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {SetterNotWired} from "../../../../../L1TestsErrors.sol";

/// @notice A release engine wiring the Bridgehub after its swap: the shape a release uses to make a
///         setter call on a contract it upgrades instead of declaring a governance call.
contract BridgehubWiringEngine is DefaultProxyUpgradeEngine {
    address public immutable BRIDGEHUB;
    address public immutable CHAIN_REGISTRATION_SENDER;

    constructor(address _bridgehub, address _chainRegistrationSender) {
        BRIDGEHUB = _bridgehub;
        CHAIN_REGISTRATION_SENDER = _chainRegistrationSender;
    }

    function _afterSwaps(ProxyUpgradeContext memory, ProxyUpgradeRow[] memory) internal override {
        L1Bridgehub(BRIDGEHUB).setAddressesV31(CHAIN_REGISTRATION_SENDER);
    }

    function _checkPostconditions(ProxyUpgradeContext memory, ProxyUpgradeRow[] memory) internal view override {
        address live = L1Bridgehub(BRIDGEHUB).chainRegistrationSender();
        if (live != CHAIN_REGISTRATION_SENDER) {
            revert SetterNotWired(live);
        }
    }
}

/// @notice A release engine that only wires: pinned by a transition that swaps nothing.
contract NullifierWiringEngine is DefaultProxyUpgradeEngine {
    address public immutable NULLIFIER;
    address public immutable INTEROP_HANDLER;

    constructor(address _nullifier, address _interopHandler) {
        NULLIFIER = _nullifier;
        INTEROP_HANDLER = _interopHandler;
    }

    function _afterSwaps(ProxyUpgradeContext memory, ProxyUpgradeRow[] memory) internal override {
        L1Nullifier(NULLIFIER).setL1InteropHandler(INTEROP_HANDLER);
    }

    function _checkPostconditions(ProxyUpgradeContext memory, ProxyUpgradeRow[] memory) internal view override {
        address live = L1Nullifier(NULLIFIER).l1InteropHandler();
        if (live != INTEROP_HANDLER) {
            revert SetterNotWired(live);
        }
    }
}

/// @notice The L1 wiring setters accept their owner and the upgrade authority — the owner of the
///         `ProxyAdmin` administering their proxy — and nobody else; a release engine reaches them
///         through `CoreUpgradeExecutor`. See {docs/registry-driven-upgrades.md#what-an-engine-can-reach}.
/// @dev Real implementations behind real transparent proxies, owned by a governance address, with
///      the ecosystem `ProxyAdmin` owned by a real `CoreUpgradeExecutor`.
contract UpgraderWiringTest is Test {
    address internal governance = makeAddr("governance");
    address internal stranger = makeAddr("stranger");

    ProxyAdmin internal proxyAdmin;
    CoreUpgradeExecutor internal coreExecutor;

    L1Bridgehub internal bridgehubImpl;
    L1Bridgehub internal bridgehub;
    L1Nullifier internal nullifier;
    L1AssetRouter internal assetRouter;
    L1ChainAssetHandler internal chainAssetHandler;
    CTMDeploymentTracker internal ctmDeploymentTracker;

    function setUp() public {
        proxyAdmin = new ProxyAdmin();
        coreExecutor = new CoreUpgradeExecutor(governance, proxyAdmin);
        proxyAdmin.transferOwnership(address(coreExecutor));

        bridgehubImpl = new L1Bridgehub(governance, 100);
        bridgehub = L1Bridgehub(_proxy(address(bridgehubImpl), abi.encodeCall(L1Bridgehub.initialize, (governance))));
        nullifier = L1Nullifier(
            _proxy(
                address(new L1Nullifier(IL1Bridgehub(address(bridgehub)), IMessageRootBase(makeAddr("messageRoot")))),
                abi.encodeCall(L1Nullifier.initialize, (governance))
            )
        );
        assetRouter = L1AssetRouter(
            _proxy(
                address(new L1AssetRouter(makeAddr("weth"), address(bridgehub), address(nullifier))),
                abi.encodeCall(L1AssetRouter.initialize, (governance))
            )
        );
        chainAssetHandler = L1ChainAssetHandler(
            _proxy(
                address(new L1ChainAssetHandler(governance, address(bridgehub))),
                abi.encodeCall(L1ChainAssetHandler.initialize, (governance))
            )
        );
        ctmDeploymentTracker = CTMDeploymentTracker(
            _proxy(
                address(
                    new CTMDeploymentTracker(IBridgehubBase(address(bridgehub)), IAssetRouterBase(address(assetRouter)))
                ),
                abi.encodeCall(CTMDeploymentTracker.initialize, (governance))
            )
        );
    }

    function _proxy(address _impl, bytes memory _init) internal returns (address) {
        return address(new TransparentUpgradeableProxy(_impl, address(proxyAdmin), _init));
    }

    // ───────────────────────────── who may call ─────────────────────────────

    function test_bridgehubSetAddressesV31_ownerAndUpgraderOnly(address _caller) public {
        vm.assume(_caller != governance && _caller != address(coreExecutor) && _caller != address(proxyAdmin));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        bridgehub.setAddressesV31(address(1));

        vm.prank(governance);
        bridgehub.setAddressesV31(address(2));
        assertEq(bridgehub.chainRegistrationSender(), address(2), "the owner wires");

        vm.prank(address(coreExecutor));
        bridgehub.setAddressesV31(address(3));
        assertEq(bridgehub.chainRegistrationSender(), address(3), "the upgrade authority wires");
        assertEq(bridgehub.owner(), governance, "ownership does not move");
    }

    function test_bridgehubSetAddresses_upgraderWiresEveryAddress() public {
        address router = makeAddr("router");
        address cah = makeAddr("cah");
        address sender = makeAddr("sender");
        vm.prank(address(coreExecutor));
        bridgehub.setAddresses(
            router,
            ICTMDeploymentTracker(address(ctmDeploymentTracker)),
            IMessageRootBase(makeAddr("messageRoot")),
            cah,
            sender
        );
        assertEq(address(bridgehub.assetRouter()), router);
        assertEq(bridgehub.chainAssetHandler(), cah);
        assertEq(bridgehub.chainRegistrationSender(), sender);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        bridgehub.setAddresses(router, ICTMDeploymentTracker(address(0)), IMessageRootBase(address(0)), cah, sender);
    }

    function test_nullifierSetters_ownerAndUpgraderOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        nullifier.setL1InteropHandler(address(1));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        nullifier.setL1AssetRouter(address(1));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        nullifier.setL1NativeTokenVault(IL1NativeTokenVault(address(1)));
        vm.stopPrank();

        vm.startPrank(address(coreExecutor));
        nullifier.setL1InteropHandler(makeAddr("interopHandler"));
        nullifier.setL1AssetRouter(address(assetRouter));
        vm.stopPrank();
        vm.prank(governance);
        nullifier.setL1NativeTokenVault(IL1NativeTokenVault(makeAddr("ntv")));

        assertEq(nullifier.l1InteropHandler(), makeAddr("interopHandler"));
        assertEq(address(nullifier.l1AssetRouter()), address(assetRouter));
        assertEq(address(nullifier.l1NativeTokenVault()), makeAddr("ntv"));
    }

    function test_assetRouterSetters_ownerAndUpgraderOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        assetRouter.setL1InteropHandler(address(1));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        assetRouter.setNativeTokenVault(INativeTokenVaultBase(address(1)));
        vm.stopPrank();

        vm.prank(address(coreExecutor));
        assetRouter.setL1InteropHandler(makeAddr("interopHandler"));
        vm.prank(governance);
        assetRouter.setNativeTokenVault(INativeTokenVaultBase(makeAddr("ntv")));

        assertEq(assetRouter.l1InteropHandler(), makeAddr("interopHandler"));
        assertEq(address(assetRouter.nativeTokenVault()), makeAddr("ntv"));
    }

    function test_chainAssetHandlerSetAddresses_ownerAndUpgraderOnly() public {
        vm.prank(governance);
        bridgehub.setAddresses(
            address(assetRouter),
            ICTMDeploymentTracker(address(ctmDeploymentTracker)),
            IMessageRootBase(makeAddr("messageRoot")),
            address(chainAssetHandler),
            address(0)
        );

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        chainAssetHandler.setAddresses();

        vm.prank(address(coreExecutor));
        chainAssetHandler.setAddresses();
        assertEq(address(chainAssetHandler.MESSAGE_ROOT()), makeAddr("messageRoot"));
        assertEq(address(chainAssetHandler.ASSET_ROUTER()), address(assetRouter));
    }

    /// @dev The asset router's own check on the tracker is out of scope here, so its
    ///      `setAssetHandlerAddressThisChain` is mocked: this test isolates the tracker's gate.
    function test_ctmDeploymentTrackerSetter_ownerAndUpgraderOnly() public {
        vm.mockCall(
            address(assetRouter),
            abi.encodeWithSelector(AssetRouterBase.setAssetHandlerAddressThisChain.selector),
            hex""
        );
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        ctmDeploymentTracker.setCtmAssetHandlerAddressOnL1(address(1));

        vm.expectCall(
            address(assetRouter),
            abi.encodeCall(
                AssetRouterBase.setAssetHandlerAddressThisChain,
                (bytes32(uint256(uint160(address(1)))), bridgehub.chainAssetHandler())
            )
        );
        vm.prank(address(coreExecutor));
        ctmDeploymentTracker.setCtmAssetHandlerAddressOnL1(address(1));
    }

    /// @notice Only the owner of THIS proxy's admin is the upgrader: owning another ProxyAdmin, or
    ///         being the ProxyAdmin itself, grants nothing.
    function test_ownerOfAnotherProxyAdminIsNotTheUpgrader() public {
        address otherAuthority = makeAddr("otherAuthority");
        vm.prank(otherAuthority);
        ProxyAdmin otherAdmin = new ProxyAdmin();
        assertEq(otherAdmin.owner(), otherAuthority);

        vm.prank(otherAuthority);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, otherAuthority));
        nullifier.setL1InteropHandler(address(1));

        // The transparent proxy never forwards its admin's calls to the implementation.
        vm.prank(address(proxyAdmin));
        vm.expectRevert("TransparentUpgradeableProxy: admin cannot fallback to proxy target");
        nullifier.setL1InteropHandler(address(1));
    }

    /// @notice A contract not behind a proxy has no upgrade authority: only its owner passes.
    function test_noProxyMeansNoUpgrader(address _caller) public {
        vm.assume(_caller != governance);
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        bridgehubImpl.setAddressesV31(address(1));

        vm.prank(governance);
        bridgehubImpl.setAddressesV31(address(1));
        assertEq(bridgehubImpl.chainRegistrationSender(), address(1));
    }

    /// @notice The upgrade authority follows the ProxyAdmin: once governance moves it, the old
    ///         executor loses the setters and the new holder gains them.
    function test_upgraderFollowsTheProxyAdminOwner() public {
        address successor = makeAddr("successor");
        vm.prank(address(coreExecutor));
        proxyAdmin.transferOwnership(successor);

        vm.prank(address(coreExecutor));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(coreExecutor)));
        bridgehub.setAddressesV31(address(1));

        vm.prank(successor);
        bridgehub.setAddressesV31(address(1));
        assertEq(bridgehub.chainRegistrationSender(), address(1));
    }

    // ─────────────────────── through a release engine ───────────────────────

    /// @notice A transition swaps the Bridgehub and its engine wires the new implementation in the
    ///         same leg: no governance call reaches the Bridgehub.
    function test_engineWiresAContractItSwaps() public {
        L1Bridgehub newImpl = new L1Bridgehub(governance, 100);
        address sender = makeAddr("chainRegistrationSender");
        ProxyUpgradeRow[] memory inventory = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        inventory[uint256(L1EcosystemContract.L1Bridgehub)] = ProxyUpgradeRow({
            proxy: address(bridgehub),
            expectedOldImpl: address(bridgehubImpl),
            implNew: address(newImpl),
            callInitializeUpgrade: false
        });
        IProxyUpgradeTransition transition = _transition(
            inventory,
            address(new BridgehubWiringEngine(address(bridgehub), sender))
        );

        vm.prank(governance);
        coreExecutor.applyL1Upgrade(transition);

        assertEq(
            proxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(bridgehub))),
            address(newImpl),
            "the row is applied"
        );
        assertEq(bridgehub.chainRegistrationSender(), sender, "the engine wired the swapped contract");
        assertEq(bridgehub.owner(), governance, "governance still owns the Bridgehub");
    }

    /// @notice A transition with no swaps still runs its engine: a release that only wires needs no
    ///         governance call of its own.
    function test_hooksOnlyTransitionWires() public {
        address handler = makeAddr("interopHandler");
        IProxyUpgradeTransition transition = _transition(
            new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT),
            address(new NullifierWiringEngine(address(nullifier), handler))
        );
        assertEq(transition.rows().length, 0, "the transition swaps nothing");

        vm.prank(governance);
        coreExecutor.applyL1Upgrade(transition);
        assertEq(nullifier.l1InteropHandler(), handler, "the engine wired the Nullifier");
    }

    /// @notice An engine reaches only what the executor's ProxyAdmin administers: a proxy under
    ///         another ProxyAdmin refuses it, and the whole leg reverts.
    function test_engineCannotWireAContractOutsideItsDomain() public {
        ProxyAdmin otherAdmin = new ProxyAdmin();
        L1Nullifier foreign = L1Nullifier(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1Nullifier(IL1Bridgehub(address(bridgehub)), IMessageRootBase(address(1)))),
                    address(otherAdmin),
                    abi.encodeCall(L1Nullifier.initialize, (governance))
                )
            )
        );
        IProxyUpgradeTransition transition = _transition(
            new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT),
            address(new NullifierWiringEngine(address(foreign), makeAddr("interopHandler")))
        );

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(coreExecutor)));
        coreExecutor.applyL1Upgrade(transition);
        assertEq(foreign.l1InteropHandler(), address(0));
    }

    function _transition(
        ProxyUpgradeRow[] memory _inventory,
        address _engine
    ) internal returns (IProxyUpgradeTransition) {
        return
            new ProxyUpgradeTransition(
                ProxyUpgradeTransitionManifest({
                    domain: ProxyUpgradeDomain.Core,
                    proxyUpgrades: _inventory,
                    proxyUpgradeEngine: _engine
                })
            );
    }
}
