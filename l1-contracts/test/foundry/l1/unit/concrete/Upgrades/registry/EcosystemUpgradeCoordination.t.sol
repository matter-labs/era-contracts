// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {LifecycleImplNew, LifecycleImplOld} from "./CTMUpgradeLifecycle.t.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {CoreTransition} from "contracts/upgrades/registry/objects/CoreTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {IEcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/IEcosystemUpgradeExecutor.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {
    CTMContract,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {
    L2BytecodeNotPublished,
    CoordinatorCTMMismatch,
    ExecutorCoordinatorMismatch,
    UpgradeLifecycleBusy,
    RegistryTargetHasNoCode,
    OperationChangesNothing,
    OperationNotPending,
    ProxyUpgradeRowMismatch,
    Unauthorized,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    CoreTransitionManifest,
    ProxyUpgradeRow,
    TransitionManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @notice One CTM coordinator: authority bindings, same-CTM succession and atomic core/CTM execution.
/// @dev A second real CTM exists only to test rejection of a different domain during succession.
contract EcosystemUpgradeCoordinationTest is CTMUpgradeExecutorFixture {
    ChainTypeManager internal ctm2;
    CTMUpgradeExecutor internal ctmExecutor2;
    ProxyAdmin internal ctmProxyAdmin2;

    address internal implOld;
    address internal implNew;
    TransparentUpgradeableProxy internal ecosystemProxy;
    CoreTransition internal coreTransition;

    function setUp() public override {
        super.setUp();

        // The second CTM: same implementation and genesis shape as the fixture's, registered on
        // the Bridgehub (the ChainAssetHandler derives pause authority from registration plus
        // ownership), handed to its own executor, and initialized on the same real release.
        ctm2 = ChainTypeManager(
            address(
                new TransparentUpgradeableProxy(
                    address(chainTypeManager),
                    admin,
                    abi.encodeCall(
                        IChainTypeManager.initialize,
                        ChainTypeManagerInitializeData({
                            owner: governor,
                            validatorTimelock: validator,
                            currentRelease: address(fromRelease),
                            serverNotifier: serverNotifier
                        })
                    )
                )
            )
        );
        vm.prank(governor);
        bridgehub.addChainTypeManager(address(ctm2));
        ctmProxyAdmin2 = new ProxyAdmin();
        ctmExecutor2 = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(ctm2)),
            ctmProxyAdmin2,
            address(coordinator)
        );
        ctmProxyAdmin2.transferOwnership(address(ctmExecutor2));
        vm.prank(governor);
        ctm2.transferOwnership(address(ctmExecutor2));
        ctmExecutor2.acceptCTMOwnership();
        assertEq(ctm2.currentRelease(), address(fromRelease));

        // The shared ecosystem change: one proxy under the core executor's admin.
        implOld = address(new LifecycleImplOld());
        implNew = address(new LifecycleImplNew());
        ecosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        CoreTransitionManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = ProxyUpgradeRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implOld,
            implNew: implNew,
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        coreTransition = new CoreTransition(manifest);
    }

    function _replacement(address _coordinator) internal returns (CTMUpgradeExecutor) {
        return
            new CTMUpgradeExecutor(
                governor,
                IChainTypeManager(address(chainContractAddress)),
                ctmProxyAdmin,
                _coordinator
            );
    }

    function test_revertWhen_bindingDifferentCTM() public {
        vm.expectRevert(
            abi.encodeWithSelector(CoordinatorCTMMismatch.selector, address(chainContractAddress), address(ctm2))
        );
        vm.prank(governor);
        coordinator.setCTMExecutor(ctmExecutor2);
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor));
    }

    function test_revertWhen_executorNamesAnotherCoordinator() public {
        address other = makeAddr("otherCoordinator");
        CTMUpgradeExecutor replacement = _replacement(other);
        vm.expectRevert(abi.encodeWithSelector(ExecutorCoordinatorMismatch.selector, address(coordinator), other));
        vm.prank(governor);
        coordinator.setCTMExecutor(replacement);
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor));
    }

    function test_revertWhen_bindingZeroOrCodelessExecutor() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(governor);
        coordinator.setCTMExecutor(ICTMUpgradeExecutor(address(0)));
        address noCode = makeAddr("noCodeExecutor");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, noCode));
        vm.prank(governor);
        coordinator.setCTMExecutor(ICTMUpgradeExecutor(noCode));
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor));
    }

    function test_revertWhen_strangerChangesBinding() public {
        CTMUpgradeExecutor replacement = _replacement(address(coordinator));
        vm.expectRevert("Ownable: caller is not the owner");
        coordinator.setCTMExecutor(replacement);
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor));
    }

    function test_revertWhen_rebindingPendingOperation() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _stage0(transition);
        CTMUpgradeExecutor replacement = _replacement(address(coordinator));
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(operation)));
        vm.prank(governor);
        coordinator.setCTMExecutor(replacement);
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor));
        assertEq(address(coordinator.pendingOperation()), address(operation));
        assertTrue(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));
    }

    function test_sameCTMExecutorReplacementCanRunAnUpgrade() public {
        CTMUpgradeExecutor previous = ctmExecutor;
        CTMUpgradeExecutor replacement = _replacement(address(coordinator));
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (address(replacement)))
        });
        calls[1] = Call({
            target: address(ctmProxyAdmin),
            value: 0,
            data: abi.encodeCall(Ownable.transferOwnership, (address(replacement)))
        });
        vm.prank(governor);
        previous.forward(calls);
        replacement.acceptCTMOwnership();
        vm.expectEmit(true, true, false, true, address(coordinator));
        emit IEcosystemUpgradeExecutor.CTMExecutorChanged(address(previous), address(replacement));
        vm.prank(governor);
        coordinator.setCTMExecutor(replacement);
        ctmExecutor = replacement;
        assertEq(address(coordinator.ctmExecutor()), address(replacement));
        assertEq(ctmProxyAdmin.owner(), address(replacement));
        assertEq(chainContractAddress.owner(), address(replacement));
        _stage0(transition);
        _stage1(transition);
        _stage2(transition);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(address(coordinator.pendingOperation()), address(0));
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));
    }

    function test_ctmFailureRollsBackCoreUpgrade() public {
        bytes memory unpublished = hex"de1f";
        CTMTransition target = _deployTransitionWithDelegate(778, address(fromRelease), unpublished);
        EcosystemUpgradeOperation operation = _operationWithCore(
            ICTMTransition(address(target)),
            address(coreTransition)
        );
        vm.prank(governor);
        coordinator.stage0(operation);
        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(unpublished)));
        vm.prank(governor);
        coordinator.stage1(operation);
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy))),
            implOld
        );
        assertEq(chainContractAddress.protocolVersion(), 0);
        assertEq(address(coreExecutor.activeOperation()), address(operation));
        assertEq(address(ctmExecutor.activeOperation()), address(operation));
        assertTrue(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));
        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(unpublished));
        vm.startPrank(governor);
        coordinator.stage1(operation);
        coordinator.stage2(operation);
        vm.stopPrank();
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy))),
            implNew
        );
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(address(coreExecutor.activeOperation()), address(0));
        assertEq(address(ctmExecutor.activeOperation()), address(0));
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));
    }

    /// @dev A core-only operation needs no chain-version edge, and the CTM domain is STILL
    ///      reserved and its migrations paused for it — the conservative pause policy of
    ///      {protocol-docs/ecosystem-upgrade-coordination.md}: whether a CTM change rides along is
    ///      not something the coordinator infers a safe migration window from.
    function test_coreOnlyOperation_stillReservesTheCTMAndPausesMigrations() public {
        EcosystemUpgradeOperation operation = _deployOperation(address(coreTransition), address(0));
        uint256 ctmVersionBefore = chainContractAddress.protocolVersion();

        vm.prank(governor);
        coordinator.stage0(operation);
        assertEq(address(ctmExecutor.activeOperation()), address(operation), "the CTM domain is reserved");
        assertEq(address(ctmExecutor.reservedTransition()), address(0), "with no transition of its own");
        assertTrue(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "migrations are paused");

        vm.prank(governor);
        coordinator.stage1(operation);
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy))),
            implNew,
            "the ecosystem leg applied"
        );
        assertEq(chainContractAddress.protocolVersion(), ctmVersionBefore, "no chain-version edge was bought");

        vm.prank(governor);
        coordinator.stage2(operation);
        assertEq(address(ctmExecutor.activeOperation()), address(0), "the reservation is released");
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "migrations resume");
    }

    function test_revertWhen_operationChangesNothing() public {
        // The timer is deployed first: `expectRevert` applies to the very next call.
        address timer = _newOperationTimer();
        vm.expectRevert(OperationChangesNothing.selector);
        _deployOperation(address(0), _emptyInventory(), address(0), timer);
    }
}
