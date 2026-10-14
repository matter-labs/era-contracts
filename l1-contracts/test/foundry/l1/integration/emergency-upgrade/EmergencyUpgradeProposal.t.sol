// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {DeadlineNotYetPassed} from "contracts/common/L1ContractErrors.sol";

import {EmergencyStageUpgradeCalldata} from "deploy-scripts/upgrade/EmergencyStageUpgradeCalldata.s.sol";
import {VerifyStage1Pause} from "deploy-scripts/upgrade/VerifyStage1Pause.s.sol";
import {VerifyEmergencyApproveHash} from "deploy-scripts/upgrade/VerifyEmergencyApproveHash.s.sol";
import {SecurityCouncilEmergencyStageUpgrade} from "deploy-scripts/upgrade/SecurityCouncilEmergencyStageUpgrade.s.sol";
import {SecurityCouncilApproveStageUpgrade} from "deploy-scripts/upgrade/SecurityCouncilApproveStageUpgrade.s.sol";
import {IProtocolUpgradeHandler} from "deploy-scripts/interfaces/IProtocolUpgradeHandler.sol";
import {
    EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH,
    EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH,
    EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH
} from "deploy-scripts/utils/Utils.sol";

import {
    EmergencyUpgradeFixture,
    GUARDIANS_EIP1271_THRESHOLD,
    OneOwnerSafeDouble,
    ProtocolUpgradeHandlerDouble,
    SECURITY_COUNCIL_EIP1271_THRESHOLD
} from "./_EmergencyGovernanceDoubles.sol";

/// @notice The emergency-upgrade tooling against packages in the shape the `upgrade-prepare-all`
///         merge writes, executed through test doubles of the zk-governance handler, board,
///         multisigs and Safes (`_EmergencyGovernanceDoubles.sol` says why doubles). These packages
///         are BOOTSTRAP-shaped: the first bundle starts a `GovernanceUpgradeTimer` itself and the
///         later ones check it, as the one-time edge's declared bundles do. A registry operation,
///         through the real prepare pipeline, is `RegistryUpgradeAsEmergency.t.sol`.
contract EmergencyUpgradeProposalTest is EmergencyUpgradeFixture {
    /// @dev A stage-1 hold one block cannot pass.
    uint256 internal constant TIMER_DELAY = 1200;
    /// @dev The `MAX_ADDITIONAL_DELAY` the CTM prepare deploys every timer with.
    uint256 internal constant TIMER_MAX_ADDITIONAL_DELAY = 2 weeks;
    /// @dev A double quote, for hand-written TOML.
    string internal constant QUOTE = hex"22";

    VerifyStage1Pause internal dryRun;

    function setUp() public {
        _deployEmergencyGovernance(safeOwner.addr);
        dryRun = new VerifyStage1Pause();
    }

    // ───────────────────────────── digests ─────────────────────────────

    /// @notice The digest round trip: what the tool asks the owner to approve is what the board
    ///         recomputes over its own EIP-712 domain (OpenZeppelin's `_hashTypedDataV4`, not the
    ///         tool's `EIP712Utils`), wrapped in each Safe's message hash, for the first
    ///         `EIP1271_THRESHOLD` members of each multisig in member order and the ZK Foundation.
    function test_proposal_approvesTheDigestsTheBoardChecks() public {
        (, IProtocolUpgradeHandler.Call[] memory calls) = _startTimerCall(0);
        EmergencyStageUpgradeCalldata.EmergencyProposal memory proposal = _build(calls);

        assertEq(address(proposal.board), address(board), "the handler's board executes the proposal");
        assertEq(proposal.owner, safeOwner.addr, "the ZK Foundation Safe's owner approves");
        assertEq(
            proposal.id,
            keccak256(
                abi.encode(
                    IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: address(board), salt: bytes32(0)})
                )
            ),
            "the handler's id: the calls, the board as executor, the zero salt"
        );

        bytes32 guardiansDigest = board.typedDigest(EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH, proposal.id);
        bytes32 councilDigest = board.typedDigest(EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH, proposal.id);
        bytes32 foundationDigest = board.typedDigest(EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH, proposal.id);
        assertEq(
            tool.boardDigest(_board(), EXECUTE_EMERGENCY_UPGRADE_GUARDIANS_TYPEHASH, proposal.id),
            guardiansDigest
        );
        assertEq(
            tool.boardDigest(_board(), EXECUTE_EMERGENCY_UPGRADE_SECURITY_COUNCIL_TYPEHASH, proposal.id),
            councilDigest
        );
        assertEq(
            tool.boardDigest(_board(), EXECUTE_EMERGENCY_UPGRADE_ZK_FOUNDATION_TYPEHASH, proposal.id),
            foundationDigest
        );

        assertEq(
            proposal.approvals.length,
            GUARDIANS_EIP1271_THRESHOLD + SECURITY_COUNCIL_EIP1271_THRESHOLD + 1,
            "one approval per required signer"
        );
        for (uint256 i = 0; i < GUARDIANS_EIP1271_THRESHOLD; ++i) {
            _assertApproval(proposal.approvals[i], guardians.members(i), guardiansDigest);
        }
        for (uint256 i = 0; i < SECURITY_COUNCIL_EIP1271_THRESHOLD; ++i) {
            _assertApproval(
                proposal.approvals[GUARDIANS_EIP1271_THRESHOLD + i],
                securityCouncil.members(i),
                councilDigest
            );
        }
        _assertApproval(proposal.approvals[proposal.approvals.length - 1], address(zkFoundation), foundationDigest);

        (address[] memory signers, bytes[] memory markers) = abi.decode(
            proposal.guardiansSignatures,
            (address[], bytes[])
        );
        assertEq(signers.length, GUARDIANS_EIP1271_THRESHOLD, "exactly the threshold signs");
        assertEq(signers[0], guardians.members(0), "in member order");
        assertEq(markers[0], _marker(safeOwner.addr), "an approved-hash marker for the owner");
        assertEq(proposal.zkFoundationSignatures, _marker(safeOwner.addr));
    }

    // ───────────────────────────── the one proposal ─────────────────────────────

    /// @notice A package's governance calls, every `[governance_calls]` entry in key order whatever
    ///         order the file lists them in, are ONE proposal: emitted, approved by the owner and
    ///         executed by anyone. With a zero timer delay the check of the timer passes in the block
    ///         that started it.
    function test_package_executesAsOneProposalInKeyOrder() public {
        (GovernanceUpgradeTimer timer, IProtocolUpgradeHandler.Call[] memory start) = _startTimerCall(0);
        // Written by hand: forge's TOML writer would sort the keys itself.
        string memory package = string.concat(vm.projectRoot(), "/script-out/emergency-upgrade/key-order.toml");
        vm.writeFile(
            package,
            string.concat(
                string.concat("[governance_calls]\n", _tomlEntry("stage2_calls", _checkDeadlineCalls(timer, 2))),
                _tomlEntry("stage0_calls", start),
                _tomlEntry("stage1_calls", _checkDeadlineCalls(timer, 1))
            )
        );

        tool.run(address(handler), package);
        IProtocolUpgradeHandler.Call[] memory calls = tool.loadGovernanceCalls(package);
        assertEq(calls.length, 4, "every entry, concatenated");
        assertEq(calls[0].data, abi.encodeCall(GovernanceUpgradeTimer.startTimer, ()), "stage0_calls first");
        assertEq(calls[1].data, abi.encodeCall(GovernanceUpgradeTimer.checkDeadline, ()), "then the rest");

        EmergencyStageUpgradeCalldata.EmergencyProposal memory proposal = _build(calls);
        _approve(proposal, type(uint256).max);
        bytes memory executeCalldata = tool.executeCalldata(proposal);
        vm.expectEmit(true, false, false, false, address(handler));
        emit ProtocolUpgradeHandlerDouble.EmergencyUpgradeExecuted(proposal.id);
        _send(proposal, executeCalldata);

        assertTrue(handler.emergencyUpgradeExecuted(proposal.id), "the handler recorded the proposal");
        assertEq(timer.deadline(), block.timestamp, "the timer started and was checked in one block");
        for (uint256 i = 0; i < proposal.approvals.length; ++i) {
            assertEq(
                OneOwnerSafeDouble(proposal.approvals[i].safe).approvedHashes(
                    safeOwner.addr,
                    proposal.approvals[i].safeMessageHash
                ),
                1,
                "every approval landed on its Safe"
            );
        }
    }

    /// @notice A package whose governance calls are ONE list is read and dry-run the same way.
    function test_package_aSingleListIsOneProposal() public {
        (GovernanceUpgradeTimer timer, IProtocolUpgradeHandler.Call[] memory start) = _startTimerCall(0);
        IProtocolUpgradeHandler.Call[] memory all = new IProtocolUpgradeHandler.Call[](2);
        all[0] = start[0];
        all[1] = _checkDeadlineCalls(timer, 1)[0];
        string[] memory keys = new string[](1);
        keys[0] = "calls";
        IProtocolUpgradeHandler.Call[][] memory lists = new IProtocolUpgradeHandler.Call[][](1);
        lists[0] = all;
        string memory package = _writePackage("single-list", keys, lists);

        assertEq(tool.proposalId(_board(), tool.loadGovernanceCalls(package)), tool.proposalId(_board(), all));
        dryRun.verify(address(handler), package);
        assertTrue(handler.emergencyUpgradeExecuted(tool.proposalId(_board(), all)), "the dry run executed it");
        assertEq(timer.deadline(), block.timestamp);
    }

    /// @notice A timer the proposal starts with a delay would revert the later check of it after
    ///         every approval was collected, so emission and the dry run both refuse the package.
    function test_package_refusedWhileATimerItStartsHoldsTheRest() public {
        (GovernanceUpgradeTimer timer, string memory package) = _bootstrapShapedPackage("held", TIMER_DELAY);
        bytes memory refusal = bytes(
            string.concat(
                "upgrade timer ",
                vm.toString(address(timer)),
                " holds the rest of the upgrade for 1200s, so it cannot execute as one proposal: prepare it with a zero governance_upgrade_timer_initial_delay"
            )
        );
        vm.expectRevert(refusal);
        tool.run(address(handler), package);
        vm.expectRevert(refusal);
        dryRun.verify(address(handler), package);

        // The refusal is not caution: the handler itself would revert on the timer check.
        IProtocolUpgradeHandler.Call[] memory calls = tool.loadGovernanceCalls(package);
        vm.prank(address(board));
        vm.expectRevert(DeadlineNotYetPassed.selector);
        handler.executeEmergencyUpgrade(
            IProtocolUpgradeHandler.UpgradeProposal({calls: calls, executor: address(board), salt: bytes32(0)})
        );
    }

    // ───────────────────────────── the board's checks ─────────────────────────────

    /// @notice The approvals bind the exact calls and are needed in full: the same signatures over
    ///         another call list, a proposal missing one approval of any signer, and a replay all fail.
    function test_approvals_bindTheProposalAndAreNeededInFull() public {
        (GovernanceUpgradeTimer timer, IProtocolUpgradeHandler.Call[] memory calls) = _startTimerCall(0);
        EmergencyStageUpgradeCalldata.EmergencyProposal memory proposal = _build(calls);
        _approve(proposal, type(uint256).max);

        EmergencyStageUpgradeCalldata.EmergencyProposal memory swapped = _build(calls);
        swapped.calls = _checkDeadlineCalls(timer, 1);
        bytes memory swappedCalldata = tool.executeCalldata(swapped);
        vm.expectRevert("Invalid guardians signatures");
        _send(swapped, swappedCalldata);

        bytes memory executeCalldata = tool.executeCalldata(proposal);
        _send(proposal, executeCalldata);
        assertEq(timer.deadline(), block.timestamp, "the approved calls ran");
        vm.expectRevert("Upgrade already exists");
        _send(proposal, executeCalldata);

        _assertOneApprovalShort(_build(_checkDeadlineCalls(timer, 1)), 0, "Invalid guardians signatures");
        _assertOneApprovalShort(
            _build(_checkDeadlineCalls(timer, 2)),
            GUARDIANS_EIP1271_THRESHOLD,
            "Invalid Security Council signatures"
        );
        EmergencyStageUpgradeCalldata.EmergencyProposal memory lastOne = _build(_checkDeadlineCalls(timer, 3));
        _assertOneApprovalShort(lastOne, lastOne.approvals.length - 1, "Invalid ZK Foundation signatures");
    }

    /// @notice A marker stands for the owner's approval only on a 1-of-1 Safe of that owner, so a
    ///         board whose member Safes belong to someone else is refused at emission.
    function test_proposal_refusesASafeTheOwnerDoesNotSolelyOwn() public {
        _deployEmergencyGovernance(makeAddr("stranger"));
        (, IProtocolUpgradeHandler.Call[] memory calls) = _startTimerCall(0);

        vm.expectRevert(
            bytes(
                string.concat(
                    "GUARDIANS 1 Safe ",
                    vm.toString(guardians.members(0)),
                    " is not a 1-of-1 Safe of ",
                    vm.toString(safeOwner.addr)
                )
            )
        );
        _build(calls);
    }

    // ───────────────────────────── reading the package ─────────────────────────────

    /// @notice An empty entry — the merge's `abi.encode` of no calls, or a bare `"0x"` as
    ///         protocol-ops' own fixtures write it — contributes no calls, and a package with no calls
    ///         at all is not emitted.
    function test_package_emptyEntriesContributeNothing() public {
        (, IProtocolUpgradeHandler.Call[] memory calls) = _startTimerCall(0);
        string memory package = _writeStagedPackage("empty-entry", calls, new IProtocolUpgradeHandler.Call[](0), calls);
        assertEq(tool.loadGovernanceCalls(package).length, 2, "the empty entry adds nothing");

        string memory barePackage = string.concat(vm.projectRoot(), "/script-out/emergency-upgrade/bare.toml");
        vm.writeFile(
            barePackage,
            string.concat(
                "[governance_calls]\n",
                string.concat(_tomlEntry("stage0_calls", ""), _tomlEntry("stage1_calls", "")),
                _tomlEntry("stage2_calls", "")
            )
        );
        assertEq(tool.loadGovernanceCalls(barePackage).length, 0, "bare 0x entries decode to no calls");
        vm.expectRevert("the package carries no governance calls");
        tool.run(address(handler), barePackage);
    }

    // ───────────────────────────── the other restored scripts ─────────────────────────────

    /// @notice `VerifyEmergencyApproveHash`: the approved-hash route executes an empty proposal.
    function test_verifyEmergencyApproveHash_executesTheEmptyProposal() public {
        bytes32 emptyProposalId = tool.proposalId(_board(), new IProtocolUpgradeHandler.Call[](0));
        vm.expectEmit(true, false, false, false, address(handler));
        emit ProtocolUpgradeHandlerDouble.EmergencyUpgradeExecuted(emptyProposalId);
        new VerifyEmergencyApproveHash().run(address(handler));
        assertTrue(handler.emergencyUpgradeExecuted(emptyProposalId));
    }

    /// @notice The SIGNED route (`Utils.executeEmergencyProtocolUpgrade`, driven by
    ///         `SecurityCouncilEmergencyStageUpgrade`): the Safe owner's ECDSA signatures for every
    ///         member pass the same board.
    function test_signedRoute_executesThroughTheBoard() public {
        vm.setEnv("PROTOCOL_UPGRADE_HANDLER", vm.toString(address(handler)));
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(safeOwner.privateKey)));
        bytes32 emptyProposalId = tool.proposalId(_board(), new IProtocolUpgradeHandler.Call[](0));

        vm.expectEmit(true, false, false, false, address(handler));
        emit ProtocolUpgradeHandlerDouble.EmergencyUpgradeExecuted(emptyProposalId);
        new SecurityCouncilEmergencyStageUpgrade().run();
        assertTrue(handler.emergencyUpgradeExecuted(emptyProposalId));
    }

    /// @notice `SecurityCouncilApproveStageUpgrade` (`Utils.securityCouncilApproveUpgrade`): the
    ///         Security Council's standard-path approval of a proposal id, under its own domain.
    function test_signedRoute_securityCouncilApprovesAnUpgrade() public {
        bytes32 upgradeId = keccak256("a standard-path proposal");
        vm.setEnv("PROTOCOL_UPGRADE_HANDLER", vm.toString(address(handler)));
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(safeOwner.privateKey)));
        vm.setEnv("UPGRADE_ID", vm.toString(upgradeId));

        vm.expectEmit(true, false, false, false, address(handler));
        emit ProtocolUpgradeHandlerDouble.UpgradeApprovedBySecurityCouncil(upgradeId);
        new SecurityCouncilApproveStageUpgrade().run();
        assertTrue(handler.securityCouncilApproved(upgradeId));
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _build(
        IProtocolUpgradeHandler.Call[] memory _calls
    ) internal view returns (EmergencyStageUpgradeCalldata.EmergencyProposal memory) {
        return tool.buildEmergencyProposal(IProtocolUpgradeHandler(address(handler)), _calls);
    }

    /// @dev A timer the handler starts, and the call that starts it.
    function _startTimerCall(
        uint256 _delay
    ) internal returns (GovernanceUpgradeTimer timer, IProtocolUpgradeHandler.Call[] memory calls) {
        timer = new GovernanceUpgradeTimer({
            _initialDelay: _delay,
            _maxAdditionalDelay: TIMER_MAX_ADDITIONAL_DELAY,
            _timerGovernance: address(handler),
            _initialOwner: address(handler)
        });
        calls = new IProtocolUpgradeHandler.Call[](1);
        calls[0] = IProtocolUpgradeHandler.Call({
            target: address(timer),
            value: 0,
            data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ())
        });
    }

    /// @dev `_count` deadline checks: call lists that differ only in length have distinct proposal ids.
    function _checkDeadlineCalls(
        GovernanceUpgradeTimer _timer,
        uint256 _count
    ) internal pure returns (IProtocolUpgradeHandler.Call[] memory calls) {
        calls = new IProtocolUpgradeHandler.Call[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            calls[i] = IProtocolUpgradeHandler.Call({
                target: address(_timer),
                value: 0,
                data: abi.encodeCall(GovernanceUpgradeTimer.checkDeadline, ())
            });
        }
    }

    /// @dev The bootstrap edge's timing: stage 0 starts the timer, stages 1 and 2 check it.
    function _bootstrapShapedPackage(
        string memory _name,
        uint256 _delay
    ) internal returns (GovernanceUpgradeTimer timer, string memory package) {
        IProtocolUpgradeHandler.Call[] memory stage0;
        (timer, stage0) = _startTimerCall(_delay);
        package = _writeStagedPackage(_name, stage0, _checkDeadlineCalls(timer, 1), _checkDeadlineCalls(timer, 1));
    }

    /// @dev One `key = "0x<abi.encode(calls)>"` line of a hand-written `[governance_calls]` table.
    function _tomlEntry(
        string memory _key,
        IProtocolUpgradeHandler.Call[] memory _calls
    ) internal pure returns (string memory) {
        return _tomlEntry(_key, abi.encode(_calls));
    }

    /// @dev One `key = "<hex>"` line of a hand-written `[governance_calls]` table.
    function _tomlEntry(string memory _key, bytes memory _value) internal pure returns (string memory) {
        return string.concat(string.concat(_key, " = ", QUOTE), vm.toString(_value), string.concat(QUOTE, "\n"));
    }

    function _assertOneApprovalShort(
        EmergencyStageUpgradeCalldata.EmergencyProposal memory _proposal,
        uint256 _skippedApproval,
        string memory _expectedRevert
    ) internal {
        _approve(_proposal, _skippedApproval);
        bytes memory executeCalldata = tool.executeCalldata(_proposal);
        vm.expectRevert(bytes(_expectedRevert));
        _send(_proposal, executeCalldata);
    }

    function _assertApproval(
        EmergencyStageUpgradeCalldata.SafeApproval memory _approval,
        address _safe,
        bytes32 _digest
    ) internal view {
        assertEq(_approval.safe, _safe, "the approving Safe");
        assertEq(
            _approval.safeMessageHash,
            OneOwnerSafeDouble(_safe).getMessageHash(abi.encode(_digest)),
            "the Safe message hash of the board's digest"
        );
    }

    function _marker(address _owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(_owner))), bytes32(0), uint8(1));
    }
}
