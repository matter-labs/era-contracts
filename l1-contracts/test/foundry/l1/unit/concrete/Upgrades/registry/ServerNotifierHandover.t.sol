// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {CTMUpgrade_v35} from "deploy-scripts/upgrade/v35/CTMUpgrade_v35.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";

/// @dev The recurring prepare's admin-call surface, with only the output path settable.
contract RecurringAdminCallsHarness is DefaultCTMUpgrade {
    function setOutputPath(string memory _path) external {
        upgradeConfig.outputPath = _path;
    }
}

/// @dev The bootstrap prepare's admin-call surface over a live notifier, CTM proxy and bound
///      executor; nothing else of the pipeline runs — the rendering reads only those.
// solhint-disable-next-line contract-name-capwords
contract BootstrapAdminCallsHarness is CTMUpgrade_v35 {
    function setLiveInputs(address _notifierProxy, address _ctmProxy, address _executor) external {
        ctmAddresses.stateTransition.proxies.serverNotifier = _notifierProxy;
        ctmAddresses.stateTransition.proxies.chainTypeManager = _ctmProxy;
        ctmUpgradeExecutor = CTMUpgradeExecutor(payable(_executor));
    }

    function setOutputPath(string memory _path) external {
        upgradeConfig.outputPath = _path;
    }
}

/// @dev Stands in for the ChainAdmin that owns the notifier and its ProxyAdmin.
contract ChainAdminStub is Ownable {}

contract CTMDomainImplStub {
    function version() external pure returns (uint256) {
        return 1;
    }
}

/// @notice The one-time ServerNotifier handover the registry bootstrap requires (see
///         {docs/upgrade-operations.md}): the bootstrap prepare RENDERS the ChainAdmin's half
///         from live state — move the proxy under the CTM-domain ProxyAdmin, nominate the CTM
///         executor — and governance completes it through the executor's `forward`. A recurring
///         prepare has nothing to hand over.
/// @dev The rendered calls are executed as the LIVE owner of each call's target, which is how
///      protocol-ops runs them (`AdminFunctions.executeOwnableCallsWithWraps`).
contract ServerNotifierHandoverTest is CTMUpgradeExecutorFixture {
    using stdToml for string;

    BootstrapAdminCallsHarness internal harness;
    ChainAdminStub internal chainAdmin;
    ProxyAdmin internal notifierAdmin;
    TransparentUpgradeableProxy internal notifierProxy;
    /// @dev Stands in for the CTM proxy: the rendering only reads its EIP-1967 admin slot.
    TransparentUpgradeableProxy internal ctmProxy;

    function setUp() public override {
        super.setUp();
        harness = new BootstrapAdminCallsHarness();
        chainAdmin = new ChainAdminStub();
        notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(address(chainAdmin));
        notifierProxy = new TransparentUpgradeableProxy(
            address(new ServerNotifier()),
            address(notifierAdmin),
            abi.encodeCall(ServerNotifier.initialize, (address(chainAdmin)))
        );
        ctmProxy = new TransparentUpgradeableProxy(address(new CTMDomainImplStub()), address(ctmProxyAdmin), hex"");
        harness.setLiveInputs(address(notifierProxy), address(ctmProxy), address(ctmExecutor));
    }

    // ─────────────────────────────── bootstrap rendering ───────────────────────────────

    function test_bootstrapRendersBothChainAdminSteps() public {
        Call[] memory calls = harness.serverNotifierHandoverCalls();

        assertEq(calls.length, 2, "move the proxy, then nominate the executor");
        assertEq(calls[0].target, address(notifierAdmin), "the notifier's own ProxyAdmin moves it");
        assertEq(
            calls[0].data,
            abi.encodeCall(
                ProxyAdmin.changeProxyAdmin,
                (ITransparentUpgradeableProxy(address(notifierProxy)), address(ctmProxyAdmin))
            )
        );
        assertEq(calls[1].target, address(notifierProxy), "the notifier's owner nominates");
        assertEq(calls[1].data, abi.encodeCall(Ownable2Step.transferOwnership, (address(ctmExecutor))));

        _executeAsLiveOwners(calls);
        _acceptAsGovernance();
        _assertHandedOver();
    }

    /// @dev The frozen v34 fixture's shape: the notifier's deployer nominated the ChainAdmin, which
    ///      never accepted. The live owner issues the nomination, overriding the stale one.
    function test_bootstrapRendersTheNominationForANeverAcceptedNotifier() public {
        address deployer = makeAddr("deployer");
        TransparentUpgradeableProxy stale = new TransparentUpgradeableProxy(
            address(new ServerNotifier()),
            address(notifierAdmin),
            abi.encodeCall(ServerNotifier.initialize, (deployer))
        );
        vm.prank(deployer);
        Ownable2Step(address(stale)).transferOwnership(address(chainAdmin));
        harness.setLiveInputs(address(stale), address(ctmProxy), address(ctmExecutor));

        Call[] memory calls = harness.serverNotifierHandoverCalls();
        assertEq(calls.length, 2);
        assertEq(Ownable(calls[1].target).owner(), deployer, "the nomination is the deployer's to make");

        _executeAsLiveOwners(calls);
        assertEq(Ownable2Step(address(stale)).pendingOwner(), address(ctmExecutor), "the stale nomination is replaced");
        _acceptAsGovernanceFor(address(stale));
        assertEq(Ownable2Step(address(stale)).owner(), address(ctmExecutor));
        assertEq(ctmProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(address(stale))), address(ctmProxyAdmin));
    }

    /// @dev Rendered from live state: a step already done is not repeated.
    function test_bootstrapRendersOnlyTheMissingSteps() public {
        // The proxy already moved: only the nomination is left.
        vm.prank(address(chainAdmin));
        notifierAdmin.changeProxyAdmin(ITransparentUpgradeableProxy(address(notifierProxy)), address(ctmProxyAdmin));
        Call[] memory calls = harness.serverNotifierHandoverCalls();
        assertEq(calls.length, 1, "only the nomination");
        assertEq(calls[0].target, address(notifierProxy));

        // Nominated as well: nothing is left for the ChainAdmin (governance still has to accept).
        _executeAsLiveOwners(calls);
        assertEq(harness.serverNotifierHandoverCalls().length, 0, "the ChainAdmin's half is done");

        _acceptAsGovernance();
        assertEq(harness.serverNotifierHandoverCalls().length, 0, "and stays done");
        _assertHandedOver();
    }

    function test_bootstrapAdminCallsSectionRecordsTheHandover() public {
        string memory outputPath = _outputPath("bootstrap");
        harness.setOutputPath(outputPath);

        Call[] memory calls = harness.prepareDefaultCTMAdminCalls();
        assertEq(calls.length, 2, "the section carries both steps");

        // Each declared action carries the call itself: that identity is what the merge holds an
        // emitted bundle to.
        string[] memory declared = harness.externalActionEntries();
        assertEq(declared.length, 2, "both steps are declared");
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(vm.parseJsonString(declared[i], "$.phase"), "admin", "declared as an admin action");
            assertEq(vm.parseJsonAddress(declared[i], "$.target"), calls[i].target, "declared target");
            assertEq(vm.parseJsonBytes(declared[i], "$.data"), calls[i].data, "declared calldata");
        }

        string memory toml = vm.readFile(outputPath);
        assertEq(toml.readAddress("$.ctm_admin_calls.chain_admin"), address(chainAdmin), "the administrator");
        assertEq(toml.readAddress("$.ctm_admin_calls.chain_admin_owner"), address(this), "and its owner");
        Call[] memory written = abi.decode(toml.readBytes("$.ctm_admin_calls.server_notifier_handover"), (Call[]));
        assertEq(written.length, 2, "both written");
        for (uint256 i = 0; i < 2; ++i) {
            assertEq(written[i].target, calls[i].target, "written target");
            assertEq(written[i].data, calls[i].data, "written calldata");
        }
    }

    // ─────────────────────────────── recurring prepare ───────────────────────────────

    /// @dev After the bootstrap the notifier is administered like the rest of the CTM domain, so a
    ///      recurring prepare has no admin call; the section is still written in one shape.
    function test_recurringPrepareRendersNoAdminCall() public {
        RecurringAdminCallsHarness recurring = new RecurringAdminCallsHarness();
        string memory outputPath = _outputPath("recurring");
        recurring.setOutputPath(outputPath);

        assertEq(recurring.serverNotifierHandoverCalls().length, 0, "nothing to hand over");
        Call[] memory calls = recurring.prepareDefaultCTMAdminCalls();
        assertEq(calls.length, 0, "no call");
        assertEq(recurring.externalActionEntries().length, 0, "no declared action");

        string memory toml = vm.readFile(outputPath);
        assertEq(toml.readAddress("$.ctm_admin_calls.chain_admin"), address(0), "no administrator");
        Call[] memory written = abi.decode(toml.readBytes("$.ctm_admin_calls.server_notifier_handover"), (Call[]));
        assertEq(written.length, 0, "an empty call list");
    }

    // ─────────────────────────────── unhappy path ───────────────────────────────

    /// @dev Governance's accept is only its half: before the ChainAdmin nominated the executor it
    ///      reverts.
    function test_revertWhen_governanceAcceptsBeforeTheNomination() public {
        Call[] memory accept = new Call[](1);
        accept[0] = Call({
            target: address(notifierProxy),
            value: 0,
            data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
        });
        vm.prank(governor);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        ctmExecutor.forward(accept);
        assertEq(Ownable2Step(address(notifierProxy)).owner(), address(chainAdmin), "nothing moved");
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    /// @dev Each call as the live owner of its target, read right before it runs.
    function _executeAsLiveOwners(Call[] memory _calls) internal {
        for (uint256 i = 0; i < _calls.length; ++i) {
            vm.prank(Ownable(_calls[i].target).owner());
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, ) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            assertTrue(success, "the rendered call must succeed for its live owner");
        }
    }

    function _acceptAsGovernance() internal {
        _acceptAsGovernanceFor(address(notifierProxy));
    }

    /// @dev Governance's half: the CTM executor accepts through `forward`.
    function _acceptAsGovernanceFor(address _notifier) internal {
        Call[] memory accept = new Call[](1);
        accept[0] = Call({target: _notifier, value: 0, data: abi.encodeCall(Ownable2Step.acceptOwnership, ())});
        vm.prank(governor);
        ctmExecutor.forward(accept);
    }

    /// @dev The state the bootstrap bundle needs the notifier in: under the CTM-domain ProxyAdmin (for
    ///      `migrate`'s row) and owned by the CTM executor (what the bundle's accept establishes).
    function _assertHandedOver() internal view {
        assertEq(
            ctmProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(address(notifierProxy))),
            address(ctmProxyAdmin),
            "the notifier sits under the CTM-domain ProxyAdmin"
        );
        assertEq(Ownable2Step(address(notifierProxy)).owner(), address(ctmExecutor), "owned by the CTM executor");
        assertEq(Ownable2Step(address(notifierProxy)).pendingOwner(), address(0), "with no nomination left");
    }

    function _outputPath(string memory _tag) internal returns (string memory) {
        string memory dir = string.concat(vm.projectRoot(), "/script-out");
        vm.createDir(dir, true);
        return string.concat(dir, "/server-notifier-handover-", _tag, ".toml");
    }
}
