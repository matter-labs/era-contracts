// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

/// @dev The recurring prepare's admin-call surface, with only the output path settable.
contract RecurringAdminCallsHarness is DefaultCTMUpgrade {
    function setOutputPath(string memory _path) external {
        upgradeConfig.outputPath = _path;
    }
}

/// @dev Stands in for the ChainAdmin that owns the notifier and its ProxyAdmin.
contract ChainAdminStub is Ownable {}

/// @notice The ServerNotifier handover was the v35 bootstrap's one-time step (see
///         {docs/upgrade-operations.md}); its rendering left with `CTMUpgrade_v35`. What stays: a
///         recurring prepare has nothing to hand over, and governance cannot take the notifier
///         without the ChainAdmin's nomination.
contract ServerNotifierHandoverTest is CTMUpgradeExecutorFixture {
    using stdToml for string;

    ChainAdminStub internal chainAdmin;
    ProxyAdmin internal notifierAdmin;
    TransparentUpgradeableProxy internal notifierProxy;

    function setUp() public override {
        super.setUp();
        chainAdmin = new ChainAdminStub();
        notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(address(chainAdmin));
        notifierProxy = new TransparentUpgradeableProxy(
            address(new ServerNotifier()),
            address(notifierAdmin),
            abi.encodeCall(ServerNotifier.initialize, (address(chainAdmin)))
        );
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

    function _outputPath(string memory _tag) internal returns (string memory) {
        string memory dir = string.concat(vm.projectRoot(), "/script-out");
        vm.createDir(dir, true);
        return string.concat(dir, "/server-notifier-handover-", _tag, ".toml");
    }
}
