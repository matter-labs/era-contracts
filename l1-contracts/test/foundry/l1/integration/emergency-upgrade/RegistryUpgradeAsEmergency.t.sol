// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {ICoreUpgradeExecutor} from "contracts/upgrades/registry/executors/ICoreUpgradeExecutor.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {IProxyUpgradeTransition} from "contracts/upgrades/registry/objects/IProxyUpgradeTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";

import {EmergencyUpgradeCalldata} from "deploy-scripts/upgrade/EmergencyUpgradeCalldata.s.sol";
import {VerifyEmergencyUpgrade} from "deploy-scripts/upgrade/VerifyEmergencyUpgrade.s.sol";
import {IProtocolUpgradeHandler} from "deploy-scripts/interfaces/IProtocolUpgradeHandler.sol";
import {Utils as DeployScriptUtils} from "deploy-scripts/utils/Utils.sol";

import {UpgradeIntegrationReleaseFixture} from "../UpgradeTest_Local.t.sol";
import {
    CoreUpgradeNoEcosystemLeg,
    CTMUpgradeValidatorTimelockOnly,
    CTMUpgradeVerifierRelease,
    RecurringCTMUpgradeForTests
} from "../UpgradeTestRecurring_Local.t.sol";
import {EmergencyUpgradeFixture, ProtocolUpgradeHandlerDouble} from "./_EmergencyGovernanceDoubles.sol";

/// @notice A RECURRING registry-driven upgrade, prepared by the real pipeline on the ecosystem the
///         release fixture leaves behind, executed as ONE emergency proposal through the
///         EmergencyUpgradeBoard and ProtocolUpgradeHandler. The handler, board, multisigs and Safes
///         are doubles (`_EmergencyGovernanceDoubles.sol`); the prepare, the package and every
///         contract the calls reach are real.
/// @dev The package is written as the protocol-ops merge writes it (`upgrade.rs::write_merged_ecosystem_toml`):
///      one bundle of the core prepare's calls, the ordered executor legs (`applyL1Upgrade`,
///      `applyInfrastructureUpgrade`, `applyCTMUpgrade` — those the hop prepared), then the CTM
///      prepare's calls. Both executors are handed to the handler with a real two-step ownership
///      transfer, the acceptances being the handler's first emergency proposal.
contract RegistryUpgradeAsEmergencyTest is UpgradeIntegrationReleaseFixture, EmergencyUpgradeFixture {
    using stdToml for string;

    /// @dev Inputs as in `UpgradeTestRecurring_Local.t.sol`.
    string internal constant SAME_VERSION_INPUT = RELEASE_UPGRADE_INPUT;
    string internal constant NEXT_VERSION_INPUT = "/upgrade-envs/foundry-upgrade-recurring.toml";
    bytes32 internal constant HOP_SALT = keccak256("emergency-hop");

    address internal bridgehub;
    address internal ctm;
    address internal rollupDAManager;
    address internal governance;
    address internal eip7702Checker;
    address internal coreExecutor;
    address internal ctmExecutor;
    VerifyEmergencyUpgrade internal dryRun;

    function setUp() public override {
        super.setUp();
        _deployEmergencyGovernance(safeOwner.addr);
        dryRun = new VerifyEmergencyUpgrade();

        bridgehub = previousRelease.bridgehub;
        ctm = ctmUpgrade.getCTMAddress();
        rollupDAManager = ctmUpgrade.getAddresses().daAddresses.daContracts.rollupDAManager;
        governance = previousRelease.governance;
        eip7702Checker = ctmUpgrade.getAddresses().admin.eip7702Checker;
        coreExecutor = address(coreUpgrade.getCoreUpgradeExecutor());
        ctmExecutor = IOwnable(ctm).owner();

        address[2] memory executors = [coreExecutor, ctmExecutor];
        IProtocolUpgradeHandler.Call[] memory accept = new IProtocolUpgradeHandler.Call[](2);
        for (uint256 i = 0; i < executors.length; ++i) {
            vm.prank(IOwnable(executors[i]).owner());
            IOwnable(executors[i]).transferOwnership(address(handler));
            accept[i] = IProtocolUpgradeHandler.Call({
                target: executors[i],
                value: 0,
                data: abi.encodeCall(IOwnable.acceptOwnership, ())
            });
        }
        _approveAndExecute(tool.buildEmergencyProposal(IProtocolUpgradeHandler(address(handler)), accept));
        assertEq(IOwnable(coreExecutor).owner(), address(handler), "the handler governs the core executor");
        assertEq(IOwnable(ctmExecutor).owner(), address(handler), "and the CTM executor");
    }

    /// @notice A chain-release upgrade — new release, transition, committed version edge — runs as one
    ///         emergency proposal approved through the approved-hash route.
    function test_chainRelease_executesAsOneEmergencyProposal() public {
        RecurringCTMUpgradeForTests hop = new CTMUpgradeVerifierRelease();
        string memory package = _prepareAndMerge(hop, NEXT_VERSION_INPUT, "emergency-release");
        ICTMTransition transition = ICTMTransition(hop.preparedTransition());
        uint256 nextVersion = vm.readFile(string.concat(vm.projectRoot(), NEXT_VERSION_INPUT)).readUint(
            "$.contracts.latest_protocol_version"
        );

        tool.run(address(handler), package);
        IProtocolUpgradeHandler.Call[] memory calls = tool.loadGovernanceCalls(package);
        assertEq(calls.length, 1, "a transition-only upgrade carries the one commit call only");
        assertEq(calls[0].target, ctmExecutor);
        assertEq(calls[0].data, abi.encodeCall(ICTMUpgradeExecutor.applyCTMUpgrade, (transition)));

        EmergencyUpgradeCalldata.EmergencyProposal memory proposal = tool.buildEmergencyProposal(
            IProtocolUpgradeHandler(address(handler)),
            calls
        );
        _approve(proposal, type(uint256).max);
        bytes memory executeCalldata = tool.executeCalldata(proposal);
        vm.expectEmit(true, false, false, false, ctmExecutor);
        emit ICTMUpgradeExecutor.CTMUpgradeApplied(address(transition), 0, 0);
        vm.expectEmit(true, false, false, false, address(handler));
        emit ProtocolUpgradeHandlerDouble.EmergencyUpgradeExecuted(proposal.id);
        _send(proposal, executeCalldata);

        assertEq(IChainTypeManager(ctm).protocolVersion(), nextVersion, "the CTM committed the edge");
        assertEq(IChainTypeManager(ctm).currentRelease(), transition.newRelease(), "and installed the release");
        _assertNoMigrationPause();
    }

    /// @notice An infrastructure-only upgrade dry-run through `VerifyEmergencyUpgrade`: the
    ///         package's call, executed by the handler as its board would call it, swaps the
    ///         timelock.
    function test_infrastructureOnly_dryRunExecutesThePackage() public {
        RecurringCTMUpgradeForTests hop = new CTMUpgradeValidatorTimelockOnly();
        string memory package = _prepareAndMerge(hop, SAME_VERSION_INPUT, "emergency-infra");
        ProxyUpgradeRow[] memory rows = IProxyUpgradeTransition(hop.preparedInfrastructure()).rows();
        assertEq(rows.length, 1, "the hop swaps the timelock");
        IProtocolUpgradeHandler.Call[] memory calls = tool.loadGovernanceCalls(package);
        assertEq(calls.length, 1, "the one infrastructure leg");
        assertEq(calls[0].target, ctmExecutor);
        assertEq(
            calls[0].data,
            abi.encodeCall(
                ICTMUpgradeExecutor.applyInfrastructureUpgrade,
                (IProxyUpgradeTransition(hop.preparedInfrastructure()))
            )
        );

        dryRun.verify(address(handler), package);

        assertEq(
            DeployScriptUtils.getImplementation(rows[0].proxy),
            rows[0].implNew,
            "the timelock proxy runs the new implementation"
        );
        assertTrue(
            handler.emergencyUpgradeExecuted(tool.proposalId(_board(), tool.loadGovernanceCalls(package))),
            "the handler recorded the proposal"
        );
        _assertNoMigrationPause();
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _assertNoMigrationPause() internal view {
        assertFalse(
            IChainAssetHandlerBase(IBridgehubBase(bridgehub).chainAssetHandler()).migrationPausedFor(ctm),
            "the upgrade takes no migration pause"
        );
    }

    /// @dev Both prepares, wired as protocol-ops wires them, then the merged package.
    function _prepareAndMerge(
        RecurringCTMUpgradeForTests _hop,
        string memory _input,
        string memory _name
    ) internal returns (string memory package) {
        CoreUpgradeNoEcosystemLeg core = new CoreUpgradeNoEcosystemLeg();
        core.initializeWithArgs(
            bridgehub,
            HOP_SALT,
            _input,
            string.concat("/script-out/foundry-upgrade/", _name, "-core.toml")
        );
        // solhint-disable-next-line func-named-parameters
        _hop.initializeWithArgs(
            ctm,
            rollupDAManager,
            HOP_SALT,
            _input,
            string.concat("/script-out/foundry-upgrade/", _name, "-ctm.toml"),
            governance,
            previousRelease.zkTokenAssetId,
            true
        );
        _hop.setEIP7702Checker(eip7702Checker);
        core.prepareEcosystemUpgrade();
        _hop.setCoreTransition(address(core.coreTransition()));
        _hop.prepareCTMUpgrade();

        Call[] memory coreCalls = core.prepareDefaultGovernanceCalls();
        Call[] memory ctmCalls = _hop.prepareDefaultGovernanceCalls();
        package = _writeBundlePackage(_name, _merge(coreCalls, _legs(address(core.coreTransition()), _hop), ctmCalls));
    }

    /// @dev The executor legs the merge derives, in canonical order: core, CTM infrastructure, commit.
    function _legs(
        address _coreTransition,
        RecurringCTMUpgradeForTests _hop
    ) internal view returns (Call[] memory legs) {
        address infrastructure = _hop.preparedInfrastructure();
        address transition = _hop.preparedTransition();
        legs = new Call[](
            (_coreTransition != address(0) ? 1 : 0) +
                (infrastructure != address(0) ? 1 : 0) +
                (transition != address(0) ? 1 : 0)
        );
        uint256 next = 0;
        if (_coreTransition != address(0)) {
            legs[next++] = Call({
                target: coreExecutor,
                value: 0,
                data: abi.encodeCall(ICoreUpgradeExecutor.applyL1Upgrade, (IProxyUpgradeTransition(_coreTransition)))
            });
        }
        if (infrastructure != address(0)) {
            legs[next++] = Call({
                target: ctmExecutor,
                value: 0,
                data: abi.encodeCall(
                    ICTMUpgradeExecutor.applyInfrastructureUpgrade,
                    (IProxyUpgradeTransition(infrastructure))
                )
            });
        }
        if (transition != address(0)) {
            legs[next++] = Call({
                target: ctmExecutor,
                value: 0,
                data: abi.encodeCall(ICTMUpgradeExecutor.applyCTMUpgrade, (ICTMTransition(transition)))
            });
        }
    }

    /// @dev The merge: the core bundle, the executor legs, the CTM bundle.
    function _merge(
        Call[] memory _core,
        Call[] memory _legsInOrder,
        Call[] memory _ctm
    ) internal pure returns (IProtocolUpgradeHandler.Call[] memory merged) {
        merged = new IProtocolUpgradeHandler.Call[](_core.length + _legsInOrder.length + _ctm.length);
        uint256 next = 0;
        Call[][3] memory parts = [_core, _legsInOrder, _ctm];
        for (uint256 p = 0; p < parts.length; ++p) {
            for (uint256 i = 0; i < parts[p].length; ++i) {
                merged[next++] = IProtocolUpgradeHandler.Call({
                    target: parts[p][i].target,
                    value: parts[p][i].value,
                    data: parts[p][i].data
                });
            }
        }
    }
}
