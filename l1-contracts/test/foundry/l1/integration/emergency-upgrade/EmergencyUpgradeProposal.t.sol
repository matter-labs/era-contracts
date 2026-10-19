// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

import {EmergencyUpgradeCalldata} from "deploy-scripts/upgrade/EmergencyUpgradeCalldata.s.sol";
import {VerifyEmergencyUpgrade} from "deploy-scripts/upgrade/VerifyEmergencyUpgrade.s.sol";
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
    CallRecorderDouble,
    EmergencyUpgradeFixture,
    GUARDIANS_EIP1271_THRESHOLD,
    OneOwnerSafeDouble,
    ProtocolUpgradeHandlerDouble,
    SECURITY_COUNCIL_EIP1271_THRESHOLD
} from "./_EmergencyGovernanceDoubles.sol";

/// @notice The emergency-upgrade tooling against packages in the layout the `upgrade-prepare-all`
///         merge writes — one `[governance_calls] calls` bundle — executed through test doubles of
///         the zk-governance handler, board, multisigs and Safes (`_EmergencyGovernanceDoubles.sol`
///         says why doubles). The bundles here are synthetic calls to a recorder; a registry
///         operation through the real prepare pipeline is `RegistryUpgradeAsEmergency.t.sol`.
contract EmergencyUpgradeProposalTest is EmergencyUpgradeFixture {
    /// @dev A double quote, for hand-written TOML.
    string internal constant QUOTE = hex"22";

    VerifyEmergencyUpgrade internal dryRun;
    CallRecorderDouble internal recorder;

    function setUp() public {
        _deployEmergencyGovernance(safeOwner.addr);
        dryRun = new VerifyEmergencyUpgrade();
        recorder = new CallRecorderDouble();
    }

    // ───────────────────────────── digests ─────────────────────────────

    /// @notice The digest round trip: what the tool asks the owner to approve is what the board
    ///         recomputes over its own EIP-712 domain (OpenZeppelin's `_hashTypedDataV4`, not the
    ///         tool's `EIP712Utils`), wrapped in each Safe's message hash, for the first
    ///         `EIP1271_THRESHOLD` members of each multisig in member order and the ZK Foundation.
    function test_proposal_approvesTheDigestsTheBoardChecks() public view {
        IProtocolUpgradeHandler.Call[] memory calls = _recordCalls(1);
        EmergencyUpgradeCalldata.EmergencyProposal memory proposal = _build(calls);

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

    /// @notice A package's governance bundle is ONE proposal: emitted, approved by the owner and
    ///         executed by anyone, every call in the bundle's order.
    function test_package_executesAsOneProposal() public {
        IProtocolUpgradeHandler.Call[] memory bundle = _recordCalls(3);
        string memory package = _writeBundlePackage("one-bundle", bundle);

        tool.run(address(handler), package);
        IProtocolUpgradeHandler.Call[] memory calls = tool.loadGovernanceCalls(package);
        assertEq(calls.length, 3, "the bundle's calls");
        for (uint256 i = 0; i < calls.length; ++i) {
            assertEq(calls[i].data, bundle[i].data, "in the bundle's order");
        }

        EmergencyUpgradeCalldata.EmergencyProposal memory proposal = _build(calls);
        _approve(proposal, type(uint256).max);
        bytes memory executeCalldata = tool.executeCalldata(proposal);
        vm.expectEmit(true, false, false, false, address(handler));
        emit ProtocolUpgradeHandlerDouble.EmergencyUpgradeExecuted(proposal.id);
        _send(proposal, executeCalldata);

        assertTrue(handler.emergencyUpgradeExecuted(proposal.id), "the handler recorded the proposal");
        assertEq(recorder.recordedCount(), 3, "every call ran");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(recorder.recorded(i), i + 1, "in order");
        }
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

    /// @notice The dry run executes the bundle as the board would, so a bundle that would revert
    ///         fails before any approval is collected — and a sound one runs through.
    function test_dryRun_executesTheBundleAsTheBoardWould() public {
        IProtocolUpgradeHandler.Call[] memory failing = new IProtocolUpgradeHandler.Call[](2);
        failing[0] = _recordCalls(1)[0];
        failing[1] = IProtocolUpgradeHandler.Call({
            target: address(recorder),
            value: 0,
            data: abi.encodeCall(CallRecorderDouble.fail, ())
        });
        string memory failingPackage = _writeBundlePackage("failing-bundle", failing);
        vm.expectRevert("recorder: failing call");
        dryRun.verify(address(handler), failingPackage);
        assertEq(recorder.recordedCount(), 0, "the bundle reverted as a whole");

        IProtocolUpgradeHandler.Call[] memory sound = _recordCalls(2);
        dryRun.verify(address(handler), _writeBundlePackage("sound-bundle", sound));
        assertTrue(handler.emergencyUpgradeExecuted(tool.proposalId(_board(), sound)), "the dry run executed it");
        assertEq(recorder.recordedCount(), 2);
    }

    // ───────────────────────────── the board's checks ─────────────────────────────

    /// @notice The approvals bind the exact calls and are needed in full: the same signatures over
    ///         another call list, a proposal missing one approval of any signer, and a replay all fail.
    function test_approvals_bindTheProposalAndAreNeededInFull() public {
        IProtocolUpgradeHandler.Call[] memory calls = _recordCalls(1);
        EmergencyUpgradeCalldata.EmergencyProposal memory proposal = _build(calls);
        _approve(proposal, type(uint256).max);

        EmergencyUpgradeCalldata.EmergencyProposal memory swapped = _build(calls);
        swapped.calls = _recordCalls(2);
        bytes memory swappedCalldata = tool.executeCalldata(swapped);
        vm.expectRevert("Invalid guardians signatures");
        _send(swapped, swappedCalldata);

        bytes memory executeCalldata = tool.executeCalldata(proposal);
        _send(proposal, executeCalldata);
        assertEq(recorder.recordedCount(), 1, "the approved calls ran");
        vm.expectRevert("Upgrade already exists");
        _send(proposal, executeCalldata);

        _assertOneApprovalShort(_build(_recordCalls(2)), 0, "Invalid guardians signatures");
        _assertOneApprovalShort(
            _build(_recordCalls(3)),
            GUARDIANS_EIP1271_THRESHOLD,
            "Invalid Security Council signatures"
        );
        EmergencyUpgradeCalldata.EmergencyProposal memory lastOne = _build(_recordCalls(4));
        _assertOneApprovalShort(lastOne, lastOne.approvals.length - 1, "Invalid ZK Foundation signatures");
    }

    /// @notice A marker stands for the owner's approval only on a 1-of-1 Safe of that owner, so a
    ///         board whose member Safes belong to someone else is refused at emission.
    function test_proposal_refusesASafeTheOwnerDoesNotSolelyOwn() public {
        _deployEmergencyGovernance(makeAddr("stranger"));
        IProtocolUpgradeHandler.Call[] memory calls = _recordCalls(1);

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

    /// @notice An empty bundle — the merge's `abi.encode` of no calls, or a bare `"0x"` — decodes to
    ///         no calls, and a package with no calls is not emitted.
    function test_package_anEmptyBundleIsNotEmitted() public {
        string memory encodedEmpty = _writeBundlePackage("empty-bundle", new IProtocolUpgradeHandler.Call[](0));
        assertEq(tool.loadGovernanceCalls(encodedEmpty).length, 0, "an encoded empty list has no calls");
        vm.expectRevert("the package carries no governance calls");
        tool.run(address(handler), encodedEmpty);

        string memory barePackage = string.concat(vm.projectRoot(), "/script-out/emergency-upgrade/bare.toml");
        vm.writeFile(barePackage, string.concat("[governance_calls]\n", _tomlEntry("calls", "")));
        assertEq(tool.loadGovernanceCalls(barePackage).length, 0, "a bare 0x bundle decodes to no calls");
        vm.expectRevert("the package carries no governance calls");
        tool.run(address(handler), barePackage);
    }

    /// @notice A package in the retired per-stage layout has no `calls` bundle and is refused rather
    ///         than read as an empty or partial proposal.
    function test_package_refusesTheRetiredPerStageLayout() public {
        vm.createDir(string.concat(vm.projectRoot(), "/script-out/emergency-upgrade"), true);
        string memory staged = string.concat(vm.projectRoot(), "/script-out/emergency-upgrade/staged.toml");
        vm.writeFile(
            staged,
            string.concat("[governance_calls]\n", _tomlEntry("stage0_calls", abi.encode(_recordCalls(1))))
        );
        vm.expectRevert();
        tool.loadGovernanceCalls(staged);
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
    ) internal view returns (EmergencyUpgradeCalldata.EmergencyProposal memory) {
        return tool.buildEmergencyProposal(IProtocolUpgradeHandler(address(handler)), _calls);
    }

    /// @dev `_count` calls recording tags `1.._count`: call lists that differ in length have distinct
    ///      proposal ids.
    function _recordCalls(uint256 _count) internal view returns (IProtocolUpgradeHandler.Call[] memory calls) {
        calls = new IProtocolUpgradeHandler.Call[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            calls[i] = IProtocolUpgradeHandler.Call({
                target: address(recorder),
                value: 0,
                data: abi.encodeCall(CallRecorderDouble.record, (i + 1))
            });
        }
    }

    /// @dev One `key = "<hex>"` line of a hand-written `[governance_calls]` table.
    function _tomlEntry(string memory _key, bytes memory _value) internal pure returns (string memory) {
        return string.concat(string.concat(_key, " = ", QUOTE), vm.toString(_value), string.concat(QUOTE, "\n"));
    }

    function _assertOneApprovalShort(
        EmergencyUpgradeCalldata.EmergencyProposal memory _proposal,
        uint256 _skippedApproval,
        string memory _expectedRevert
    ) internal {
        _approve(_proposal, _skippedApproval);
        bytes memory executeCalldata = tool.executeCalldata(_proposal);
        vm.expectRevert(bytes(_expectedRevert));
        _send(_proposal, executeCalldata);
    }

    function _assertApproval(
        EmergencyUpgradeCalldata.SafeApproval memory _approval,
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
