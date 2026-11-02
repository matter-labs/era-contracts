// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Call} from "contracts/governance/Common.sol";
import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {ExecutionImplNew, ExecutionImplOld, ExecutionImplOther} from "./UpgradeBundleExecution.t.sol";
import {DefaultProxyUpgradeEngine} from "contracts/upgrades/registry/engines/DefaultProxyUpgradeEngine.sol";
import {IProxyUpgradeEngine} from "contracts/upgrades/registry/engines/IProxyUpgradeEngine.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {IProxyUpgradeTransition} from "contracts/upgrades/registry/objects/IProxyUpgradeTransition.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {
    ProxyUpgradeEngineAuthorityMismatch,
    ProxyUpgradeRowMismatch,
    RegistryTargetHasNoCode,
    UpgradeEngineChangedExecutorOwnership,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    ProxyUpgradeContext,
    ProxyUpgradeDomain,
    ProxyUpgradeRow,
    ProxyUpgradeTransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

/// @dev Raised by {TimelockWiringEngine} when the CTM's timelock is neither the reviewed source nor
///      the target.
error UnexpectedTimelock(address live);
/// @dev Raised by {TimelockWiringEngine}'s postcondition.
error TimelockNotWired(address live);

/// @notice A release engine of the shape EVM-1657 asks for: the rows, then one cross-contract
///         follow-up call written as typed Solidity — re-pointing the CTM's post-v29 validator
///         timelock, an owner-only CTM setter the CTM executor holds the authority for — then a
///         postcondition that reads it back.
/// @dev Configuration lives in the engine's OWN storage, written by its constructor, and the hooks
///      read it through an external call to `_context.upgradeEngine`: while delegatecalled, every
///      storage slot is the executor's.
contract TimelockWiringEngine is DefaultProxyUpgradeEngine {
    address public sourceTimelock;
    address public targetTimelock;

    /// @dev Test switch: a wrong engine that "forgets" its follow-up, to show the postcondition is
    ///      what catches that.
    bool public skipWiring;

    constructor(address _sourceTimelock, address _targetTimelock, bool _skipWiring) {
        sourceTimelock = _sourceTimelock;
        targetTimelock = _targetTimelock;
        skipWiring = _skipWiring;
    }

    function _afterSwaps(ProxyUpgradeContext memory _context, ProxyUpgradeRow[] memory) internal override {
        TimelockWiringEngine config = TimelockWiringEngine(_context.upgradeEngine);
        if (config.skipWiring()) {
            return;
        }
        IChainTypeManager ctm = IChainTypeManager(_context.chainTypeManager);
        address live = ctm.validatorTimelockPostV29();
        address target = config.targetTimelock();
        // Source-checked like a row: already wired is a replay, the reviewed source is wired,
        // anything else is a state this engine was not reviewed against.
        if (live == target) {
            return;
        }
        if (live != config.sourceTimelock()) {
            revert UnexpectedTimelock(live);
        }
        ctm.setValidatorTimelockPostV29(target);
    }

    function _checkPostconditions(ProxyUpgradeContext memory _context, ProxyUpgradeRow[] memory) internal view override {
        address live = IChainTypeManager(_context.chainTypeManager).validatorTimelockPostV29();
        if (live != TimelockWiringEngine(_context.upgradeEngine).targetTimelock()) {
            revert TimelockNotWired(live);
        }
    }
}

/// @notice Records, in the order they ran, which implementation the row's proxy served when each
///         hook ran — through events, since the engine must not write the executor's storage.
contract HookOrderEngine is DefaultProxyUpgradeEngine {
    event HookSaw(string hook, uint256 version);

    function _beforeSwaps(ProxyUpgradeContext memory, ProxyUpgradeRow[] memory _inventory) internal override {
        emit HookSaw("before", ExecutionImplOld(_firstProxy(_inventory)).version());
    }

    function _afterSwaps(ProxyUpgradeContext memory, ProxyUpgradeRow[] memory _inventory) internal override {
        emit HookSaw("after", ExecutionImplOld(_firstProxy(_inventory)).version());
    }

    function _firstProxy(ProxyUpgradeRow[] memory _inventory) private pure returns (address) {
        for (uint256 i = 0; i < _inventory.length; ++i) {
            if (_inventory[i].implNew != address(0)) {
                return _inventory[i].proxy;
            }
        }
        revert();
    }
}

/// @notice A malicious engine: writes the executor's `Ownable` owner slot (slot 0) while
///         delegatecalled. The executor's own check must refuse it.
contract OwnerClobberingEngine is DefaultProxyUpgradeEngine {
    function _afterSwaps(ProxyUpgradeContext memory, ProxyUpgradeRow[] memory) internal override {
        assembly {
            sstore(0, 0xdead)
        }
    }
}

/// @notice A malicious engine: after the swaps, moves the row's proxy on to another implementation.
///         The executor's own re-check of the rows must refuse it.
contract ProxyMovingEngine is DefaultProxyUpgradeEngine {
    address public immutable OTHER_IMPL;

    constructor(address _otherImpl) {
        OTHER_IMPL = _otherImpl;
    }

    function _afterSwaps(ProxyUpgradeContext memory _context, ProxyUpgradeRow[] memory _inventory) internal override {
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(
            _inventory,
            ProxyUpgradeRowLib.inventoryLength(_context.domain)
        );
        ProxyAdmin(_context.proxyAdmin).upgrade(ITransparentUpgradeableProxy(rows[0].proxy), OTHER_IMPL);
    }
}

/// @notice A follow-up that reverts: the whole leg, swaps included, must roll back.
contract RevertingFollowUpEngine is DefaultProxyUpgradeEngine {
    error FollowUpFailed();

    function _afterSwaps(ProxyUpgradeContext memory, ProxyUpgradeRow[] memory) internal pure override {
        revert FollowUpFailed();
    }
}

/// @notice The pinned upgrade engine (EVM-1657): both domain executors apply a `ProxyUpgradeTransition`
///         by delegatecalling the engine it pins, so an upgrade's follow-up calls are audited code in
///         a release's `DefaultProxyUpgradeEngine` subclass instead of governance calldata. Runs on the
///         real CTM fixture, so the follow-up's authority (the CTM executor owning the CTM) is real.
contract ProxyUpgradeEngineTest is CTMUpgradeExecutorFixture {
    address internal implOld;
    address internal implNew;
    address internal implOther;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    TransparentUpgradeableProxy internal ecosystemProxy;

    address internal sourceTimelock;
    address internal targetTimelock = makeAddr("targetTimelock");

    function setUp() public override {
        super.setUp();
        implOld = address(new ExecutionImplOld());
        implNew = address(new ExecutionImplNew());
        implOther = address(new ExecutionImplOther());
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        ecosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        sourceTimelock = chainContractAddress.validatorTimelockPostV29();
        assertTrue(sourceTimelock != targetTimelock, "fixture timelock differs from the target");
    }

    // ─────────────────────────── fixtures ───────────────────────────

    function _ctmTransition(address _engine) internal returns (IProxyUpgradeTransition) {
        ProxyUpgradeRow[] memory inventory = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        inventory[uint256(CTMContract.ValidatorTimelock)] = _row(address(ctmDomainProxy), implOld, implNew);
        return
            new ProxyUpgradeTransition(
                ProxyUpgradeTransitionManifest({
                    domain: ProxyUpgradeDomain.CTM,
                    proxyUpgrades: inventory,
                    upgradeEngine: _engine
                })
            );
    }

    function _coreTransition(address _engine) internal returns (IProxyUpgradeTransition) {
        ProxyUpgradeRow[] memory inventory = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        inventory[uint256(L1EcosystemContract.L1MessageRoot)] = _row(address(ecosystemProxy), implOld, implNew);
        return
            new ProxyUpgradeTransition(
                ProxyUpgradeTransitionManifest({
                    domain: ProxyUpgradeDomain.Core,
                    proxyUpgrades: inventory,
                    upgradeEngine: _engine
                })
            );
    }

    function _wiringEngine(bool _skipWiring) internal returns (address) {
        return address(new TimelockWiringEngine(sourceTimelock, targetTimelock, _skipWiring));
    }

    function _applyInfrastructure(IProxyUpgradeTransition _transition) internal {
        vm.prank(governor);
        ctmExecutor.applyInfrastructureUpgrade(_transition);
    }

    function _liveImpl(TransparentUpgradeableProxy _proxy, ProxyAdmin _admin) internal view returns (address) {
        return _admin.getProxyImplementation(ITransparentUpgradeableProxy(address(_proxy)));
    }

    // ─────────────────────────── the object pins its engine ───────────────────────────

    function test_theTransitionPinsItsEngineInTheManifest() public {
        address engine = _wiringEngine(false);
        IProxyUpgradeTransition t = _ctmTransition(engine);
        assertEq(t.upgradeEngine(), engine, "getter");
        assertEq(t.getManifest().upgradeEngine, engine, "manifest");
        // The engine is part of what `manifestHash` commits to.
        assertTrue(t.manifestHash() != _ctmTransition(address(proxyUpgradeEngine)).manifestHash(), "hash binds it");
    }

    /// @dev There is no implicit default: a transition always names the code that applies it.
    function test_revertWhen_theEngineIsZero() public {
        ProxyUpgradeRow[] memory inventory = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        inventory[uint256(CTMContract.ValidatorTimelock)] = _row(address(ctmDomainProxy), implOld, implNew);
        vm.expectRevert(ZeroAddress.selector);
        new ProxyUpgradeTransition(
            ProxyUpgradeTransitionManifest({
                domain: ProxyUpgradeDomain.CTM,
                proxyUpgrades: inventory,
                upgradeEngine: address(0)
            })
        );
    }

    /// @dev A codeless delegatecall target would succeed silently; the executor refuses it first.
    function test_revertWhen_theEngineHasNoCode() public {
        address codeless = makeAddr("codelessEngine");
        IProxyUpgradeTransition t = _ctmTransition(codeless);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        ctmExecutor.applyInfrastructureUpgrade(t);
        assertEq(_liveImpl(ctmDomainProxy, ctmProxyAdmin), implOld, "nothing applied");
    }

    // ─────────────────────────── the follow-up, with real authority ───────────────────────────

    /// @notice The happy path: the row is swapped AND the CTM is re-wired in the same leg, under the
    ///         CTM executor's authority, with the setter's own event.
    function test_aReleaseEngineWiresTheCtmAfterTheSwaps() public {
        IProxyUpgradeTransition t = _ctmTransition(_wiringEngine(false));

        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ctmDomainProxy), implNew);
        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewValidatorTimelockPostV29(sourceTimelock, targetTimelock);
        _applyInfrastructure(t);

        assertEq(_liveImpl(ctmDomainProxy, ctmProxyAdmin), implNew, "row applied");
        assertEq(chainContractAddress.validatorTimelockPostV29(), targetTimelock, "CTM wired");
        // The executor still answers to governance: the engine never touched its storage.
        assertEq(ctmExecutor.owner(), governor, "executor owner");
        assertEq(ctmExecutor.pendingOwner(), address(0), "no nomination");
    }

    /// @notice A replay of an applied transition is a no-op: every row is already at its target and
    ///         the source-checked hook skips the wiring it already did.
    function test_replayingAnAppliedTransitionIsANoOp() public {
        IProxyUpgradeTransition t = _ctmTransition(_wiringEngine(false));
        _applyInfrastructure(t);

        vm.recordLogs();
        _applyInfrastructure(t);
        assertEq(vm.getRecordedLogs().length, 1, "only the executor's applied event");
        assertEq(_liveImpl(ctmDomainProxy, ctmProxyAdmin), implNew);
        assertEq(chainContractAddress.validatorTimelockPostV29(), targetTimelock);
    }

    /// @notice The engine refuses a wiring state it was not reviewed against, and the swap it had
    ///         already made rolls back with it.
    function test_revertWhen_theWiredContractIsInAnUnreviewedState() public {
        address elsewhere = makeAddr("elsewhereTimelock");
        vm.prank(governor);
        ctmExecutor.forward(_setTimelockCall(elsewhere));

        IProxyUpgradeTransition t = _ctmTransition(_wiringEngine(false));
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedTimelock.selector, elsewhere));
        ctmExecutor.applyInfrastructureUpgrade(t);
        assertEq(_liveImpl(ctmDomainProxy, ctmProxyAdmin), implOld, "the swap rolled back");
    }

    /// @notice A forgotten follow-up fails the leg: the postcondition reads the wiring back.
    function test_revertWhen_theFollowUpIsSkipped() public {
        IProxyUpgradeTransition t = _ctmTransition(_wiringEngine(true));
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(TimelockNotWired.selector, sourceTimelock));
        ctmExecutor.applyInfrastructureUpgrade(t);
        assertEq(_liveImpl(ctmDomainProxy, ctmProxyAdmin), implOld, "the swap rolled back");
        assertEq(chainContractAddress.validatorTimelockPostV29(), sourceTimelock, "nothing wired");
    }

    /// @notice A failing follow-up reverts the whole leg with the engine's own error.
    function test_revertWhen_theFollowUpReverts() public {
        IProxyUpgradeTransition t = _ctmTransition(address(new RevertingFollowUpEngine()));
        vm.prank(governor);
        vm.expectRevert(RevertingFollowUpEngine.FollowUpFailed.selector);
        ctmExecutor.applyInfrastructureUpgrade(t);
        assertEq(_liveImpl(ctmDomainProxy, ctmProxyAdmin), implOld, "the swap rolled back");
    }

    /// @notice The core executor holds the ecosystem ProxyAdmin only: a follow-up needing the CTM's
    ///         owner fails there, which is why governance-owned wiring stays an external action.
    function test_revertWhen_aCoreEngineReachesForAuthorityItDoesNotHold() public {
        IProxyUpgradeTransition t = _coreTransition(_wiringEngine(false));
        vm.prank(governor);
        // The Core context carries no CTM, so the hook's call lands on address(0) and fails.
        vm.expectRevert();
        coreExecutor.applyL1Upgrade(t);
        assertEq(_liveImpl(ecosystemProxy, ecosystemProxyAdmin), implOld, "the swap rolled back");
    }

    // ─────────────────────────── order and the executor's own guarantees ───────────────────────────

    /// @notice `_beforeSwaps` sees the departing implementation and `_afterSwaps` the new one, in the
    ///         Core domain too.
    function test_hooksRunAroundTheSwaps() public {
        IProxyUpgradeTransition t = _coreTransition(address(new HookOrderEngine()));
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit HookOrderEngine.HookSaw("before", 1);
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit HookOrderEngine.HookSaw("after", 2);
        vm.prank(governor);
        coreExecutor.applyL1Upgrade(t);
        assertEq(_liveImpl(ecosystemProxy, ecosystemProxyAdmin), implNew);
    }

    /// @notice An engine that writes the executor's ownership is refused by the executor itself.
    function test_revertWhen_theEngineChangesTheExecutorsOwnership() public {
        address engine = address(new OwnerClobberingEngine());
        IProxyUpgradeTransition t = _ctmTransition(engine);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(UpgradeEngineChangedExecutorOwnership.selector, engine));
        ctmExecutor.applyInfrastructureUpgrade(t);
        assertEq(ctmExecutor.owner(), governor);
    }

    /// @notice An engine that moves a row's proxy past its `implNew` is refused by the executor's own
    ///         re-check of the rows after the engine returns.
    function test_revertWhen_theEngineMovesARowAway() public {
        IProxyUpgradeTransition t = _ctmTransition(address(new ProxyMovingEngine(implOther)));
        vm.prank(governor);
        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implNew, implOther)
        );
        ctmExecutor.applyInfrastructureUpgrade(t);
    }

    /// @notice Called directly, an engine has no authority to lend: the ProxyAdmin is not its own.
    function test_revertWhen_theEngineIsCalledDirectly() public {
        IProxyUpgradeTransition t = _ctmTransition(address(proxyUpgradeEngine));
        ProxyUpgradeContext memory context = ProxyUpgradeContext({
            transition: address(t),
            upgradeEngine: address(proxyUpgradeEngine),
            domain: ProxyUpgradeDomain.CTM,
            proxyAdmin: address(ctmProxyAdmin),
            chainTypeManager: address(chainContractAddress)
        });
        ProxyUpgradeRow[] memory inventory = t.getManifest().proxyUpgrades;
        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeEngineAuthorityMismatch.selector,
                address(ctmProxyAdmin),
                address(ctmExecutor)
            )
        );
        IProxyUpgradeEngine(address(proxyUpgradeEngine)).executeUpgrade(context, inventory);
    }

    /// @notice Only governance drives the leg; the engine adds no entrypoint.
    function test_revertWhen_aStrangerAppliesAnEngineTransition() public {
        IProxyUpgradeTransition t = _ctmTransition(_wiringEngine(false));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.applyInfrastructureUpgrade(t);
    }

    function _setTimelockCall(address _timelock) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setValidatorTimelockPostV29, (_timelock))
        });
    }
}
