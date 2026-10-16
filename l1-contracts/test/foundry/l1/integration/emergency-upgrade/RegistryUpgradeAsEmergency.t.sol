// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {IEcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/IEcosystemUpgradeExecutor.sol";
import {IEcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/IEcosystemUpgradeOperation.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";

import {EmergencyUpgradeCalldata} from "deploy-scripts/upgrade/EmergencyUpgradeCalldata.s.sol";
import {VerifyEmergencyUpgrade} from "deploy-scripts/upgrade/VerifyEmergencyUpgrade.s.sol";
import {IProtocolUpgradeHandler} from "deploy-scripts/interfaces/IProtocolUpgradeHandler.sol";
import {Utils as DeployScriptUtils} from "deploy-scripts/utils/Utils.sol";

import {UpgradeIntegrationBootstrapFixture} from "../UpgradeTest_Local.t.sol";
import {
    CoreUpgradeNoEcosystemLeg,
    CTMUpgradeValidatorTimelockOnly,
    CTMUpgradeVerifierRelease,
    RecurringCTMUpgradeForTests
} from "../UpgradeTestRecurring_Local.t.sol";
import {EmergencyUpgradeFixture, ProtocolUpgradeHandlerDouble} from "./_EmergencyGovernanceDoubles.sol";

/// @notice A RECURRING registry-driven upgrade, prepared by the real pipeline on the ecosystem the v35
///         bootstrap fixture leaves behind, executed as ONE emergency proposal through the
///         EmergencyUpgradeBoard and ProtocolUpgradeHandler. The handler, board, multisigs and Safes
///         are doubles (`_EmergencyGovernanceDoubles.sol`); the prepare, the package and every
///         contract the calls reach are real.
/// @dev The package is written as the protocol-ops merge writes it (`upgrade.rs::write_merged_ecosystem_toml`):
///      one bundle of the core prepare's calls, the coordinator's `execute(operation)`, then the CTM
///      prepare's calls. The coordinator is handed to the handler with a real two-step ownership
///      transfer, the acceptance being the handler's first emergency proposal.
contract RegistryUpgradeAsEmergencyTest is UpgradeIntegrationBootstrapFixture, EmergencyUpgradeFixture {
    using stdToml for string;

    /// @dev Inputs as in `UpgradeTestRecurring_Local.t.sol`.
    string internal constant SAME_VERSION_INPUT = "/upgrade-envs/foundry-upgrade.toml";
    string internal constant NEXT_VERSION_INPUT = "/upgrade-envs/foundry-upgrade-recurring.toml";
    bytes32 internal constant HOP_SALT = keccak256("emergency-hop");

    address internal bridgehub;
    address internal ctm;
    address internal rollupDAManager;
    address internal governance;
    address internal eip7702Checker;
    EcosystemUpgradeExecutor internal coordinator;
    VerifyEmergencyUpgrade internal dryRun;

    function setUp() public override {
        super.setUp();
        _deployEmergencyGovernance(safeOwner.addr);
        dryRun = new VerifyEmergencyUpgrade();

        string memory root = vm.projectRoot();
        string memory deployL1 = vm.readFile(string.concat(root, ECOSYSTEM_INPUT));
        string memory deployCTM = vm.readFile(string.concat(root, CTM_INPUT));
        bridgehub = deployL1.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        ctm = ctmUpgrade.getCTMAddress();
        rollupDAManager = deployCTM.readAddress("$.deployed_addresses.blobs_zksync_os_l1_da_validator_addr");
        governance = deployL1.readAddress("$.deployed_addresses.governance_addr");
        eip7702Checker = ctmUpgrade.getAddresses().admin.eip7702Checker;
        coordinator = EcosystemUpgradeExecutor(payable(coreUpgrade.getEcosystemUpgradeExecutor()));

        vm.prank(coordinator.owner());
        coordinator.transferOwnership(address(handler));
        IProtocolUpgradeHandler.Call[] memory accept = new IProtocolUpgradeHandler.Call[](1);
        accept[0] = IProtocolUpgradeHandler.Call({
            target: address(coordinator),
            value: 0,
            data: abi.encodeCall(coordinator.acceptOwnership, ())
        });
        _approveAndExecute(tool.buildEmergencyProposal(IProtocolUpgradeHandler(address(handler)), accept));
        assertEq(coordinator.owner(), address(handler), "the handler governs the coordinator");
    }

    /// @notice A chain-release upgrade — new release, transition, committed version edge — runs as one
    ///         emergency proposal approved through the approved-hash route.
    function test_chainRelease_executesAsOneEmergencyProposal() public {
        RecurringCTMUpgradeForTests hop = new CTMUpgradeVerifierRelease();
        string memory package = _prepareAndMerge(hop, NEXT_VERSION_INPUT, "emergency-release");
        IEcosystemUpgradeOperation operation = IEcosystemUpgradeOperation(hop.preparedOperation());
        ICTMTransition transition = ICTMTransition(hop.preparedTransition());
        uint256 nextVersion = vm.readFile(string.concat(vm.projectRoot(), NEXT_VERSION_INPUT)).readUint(
            "$.contracts.latest_protocol_version"
        );

        tool.run(address(handler), package);
        IProtocolUpgradeHandler.Call[] memory calls = tool.loadGovernanceCalls(package);
        assertEq(calls.length, 1, "a registry-driven upgrade carries the one coordinator call only");
        assertEq(calls[0].target, address(coordinator));
        assertEq(calls[0].data, abi.encodeCall(EcosystemUpgradeExecutor.execute, (operation)));

        EmergencyUpgradeCalldata.EmergencyProposal memory proposal = tool.buildEmergencyProposal(
            IProtocolUpgradeHandler(address(handler)),
            calls
        );
        _approve(proposal, type(uint256).max);
        bytes memory executeCalldata = tool.executeCalldata(proposal);
        vm.expectEmit(true, false, false, false, address(coordinator));
        emit IEcosystemUpgradeExecutor.OperationExecuted(address(operation));
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
        ProxyUpgradeRow[] memory rows = IEcosystemUpgradeOperation(hop.preparedOperation()).ctmInfrastructureRows();
        assertEq(rows.length, 1, "the hop swaps the timelock");

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
            bytes32(uint256(1)),
            true
        );
        _hop.setEIP7702Checker(eip7702Checker);
        core.prepareEcosystemUpgrade();
        _hop.setCoreTransition(address(core.coreTransition()));
        _hop.prepareCTMUpgrade();

        Call[] memory coreCalls = core.prepareDefaultGovernanceCalls();
        Call[] memory ctmCalls = _hop.prepareDefaultGovernanceCalls();
        IEcosystemUpgradeOperation operation = IEcosystemUpgradeOperation(_hop.preparedOperation());
        package = _writeBundlePackage(
            _name,
            _merge(coreCalls, abi.encodeCall(EcosystemUpgradeExecutor.execute, (operation)), ctmCalls)
        );
    }

    /// @dev The merge: the core bundle, the coordinator call, the CTM bundle.
    function _merge(
        Call[] memory _core,
        bytes memory _coordinatorCall,
        Call[] memory _ctm
    ) internal view returns (IProtocolUpgradeHandler.Call[] memory merged) {
        merged = new IProtocolUpgradeHandler.Call[](_core.length + 1 + _ctm.length);
        for (uint256 i = 0; i < _core.length; ++i) {
            merged[i] = IProtocolUpgradeHandler.Call({
                target: _core[i].target,
                value: _core[i].value,
                data: _core[i].data
            });
        }
        merged[_core.length] = IProtocolUpgradeHandler.Call({
            target: address(coordinator),
            value: 0,
            data: _coordinatorCall
        });
        for (uint256 i = 0; i < _ctm.length; ++i) {
            merged[_core.length + 1 + i] = IProtocolUpgradeHandler.Call({
                target: _ctm[i].target,
                value: _ctm[i].value,
                data: _ctm[i].data
            });
        }
    }
}
