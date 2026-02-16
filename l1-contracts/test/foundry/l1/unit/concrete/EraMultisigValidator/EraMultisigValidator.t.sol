// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {EraMultisigValidator} from "contracts/state-transition/validators/EraMultisigValidator.sol";
import {IEraMultisigValidator} from "contracts/state-transition/validators/interfaces/IEraMultisigValidator.sol";
import {IValidatorTimelock} from "contracts/state-transition/validators/interfaces/IValidatorTimelock.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {ICommitter} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {DummyChainTypeManagerForValidatorTimelock} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";
import {AddressHasNoCode} from "contracts/common/L1ContractErrors.sol";
import {RoleAccessDenied} from "contracts/common/L1ContractErrors.sol";

contract EraMultisigValidatorTest is Test {
    EraMultisigValidator eraMultisig;
    ValidatorTimelock validatorTimelock;
    DummyBridgehub dummyBridgehub;
    DummyChainTypeManagerForValidatorTimelock chainTypeManager;

    address owner;
    address chainAddress;
    address executor;
    address member1;
    address member2;
    address member3;
    address nonMember;

    uint256 chainId;
    uint32 executionDelay;

    bytes32 precommitterRole;
    bytes32 committerRole;
    bytes32 reverterRole;
    bytes32 proverRole;
    bytes32 executorRole;

    function setUp() public {
        owner = makeAddr("owner");
        chainAddress = makeAddr("chainAddress");
        executor = makeAddr("executor");
        member1 = makeAddr("member1");
        member2 = makeAddr("member2");
        member3 = makeAddr("member3");
        nonMember = makeAddr("nonMember");

        chainId = 1;
        executionDelay = 0;

        // Deploy dummy bridgehub and register chain
        dummyBridgehub = new DummyBridgehub();
        chainTypeManager = new DummyChainTypeManagerForValidatorTimelock(owner, chainAddress);
        vm.mockCall(chainAddress, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(owner));
        vm.mockCall(chainAddress, abi.encodeCall(IGetters.getChainId, ()), abi.encode(chainId));
        dummyBridgehub.setZKChain(chainId, chainAddress);

        // Deploy the downstream ValidatorTimelock (the one EraMultisig forwards to)
        validatorTimelock = ValidatorTimelock(_deployValidatorTimelock(owner, executionDelay));

        // Mock the validator timelock to accept forwarded calls
        vm.mockCall(
            address(validatorTimelock),
            abi.encodeWithSelector(ICommitter.commitBatchesSharedBridge.selector),
            ""
        );
        vm.mockCall(
            address(validatorTimelock),
            abi.encodeWithSelector(IExecutor.proveBatchesSharedBridge.selector),
            ""
        );
        vm.mockCall(
            address(validatorTimelock),
            abi.encodeWithSelector(IExecutor.executeBatchesSharedBridge.selector),
            ""
        );
        vm.mockCall(
            address(validatorTimelock),
            abi.encodeWithSelector(IExecutor.revertBatchesSharedBridge.selector),
            ""
        );
        vm.mockCall(
            address(validatorTimelock),
            abi.encodeWithSelector(IValidatorTimelock.precommitSharedBridge.selector),
            ""
        );

        // Deploy EraMultisigValidator via proxy
        eraMultisig = EraMultisigValidator(_deployEraMultisig(owner, executionDelay, address(validatorTimelock)));

        // Cache role identifiers
        precommitterRole = eraMultisig.PRECOMMITTER_ROLE();
        committerRole = eraMultisig.COMMITTER_ROLE();
        reverterRole = eraMultisig.REVERTER_ROLE();
        proverRole = eraMultisig.PROVER_ROLE();
        executorRole = eraMultisig.EXECUTOR_ROLE();

        // Grant executor all validator roles on the EraMultisigValidator
        vm.prank(owner);
        eraMultisig.addValidatorForChainId(chainId, executor);

        // Setup default multisig: 3 members, threshold 2
        address[] memory membersToAdd = new address[](3);
        membersToAdd[0] = member1;
        membersToAdd[1] = member2;
        membersToAdd[2] = member3;
        address[] memory membersToRemove = new address[](0);

        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(membersToAdd, membersToRemove);
        vm.prank(owner);
        eraMultisig.changeThreshold(2);
    }

    function _deployValidatorTimelock(address _owner, uint32 _delay) internal returns (address) {
        ProxyAdmin admin = new ProxyAdmin();
        ValidatorTimelock impl = new ValidatorTimelock(address(dummyBridgehub));
        return
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    address(admin),
                    abi.encodeCall(ValidatorTimelock.initialize, (_owner, _delay))
                )
            );
    }

    function _deployEraMultisig(
        address _owner,
        uint32 _delay,
        address _validatorTimelock
    ) internal returns (address) {
        ProxyAdmin admin = new ProxyAdmin();
        EraMultisigValidator impl = new EraMultisigValidator(address(dummyBridgehub));
        return
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    address(admin),
                    abi.encodeCall(EraMultisigValidator.initializeV2, (_owner, _delay, _validatorTimelock))
                )
            );
    }

    function _sampleBatchData() internal pure returns (uint256, uint256, bytes memory) {
        return (1, 10, hex"aabbccdd");
    }

    function _sampleHash() internal view returns (bytes32) {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();
        return eraMultisig.calculateHash(chainAddress, from, to, data);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════

    function test_initializeV2_setsOwner() public view {
        assertEq(eraMultisig.owner(), owner);
    }

    function test_initializeV2_setsValidatorTimelock() public view {
        assertEq(eraMultisig.validatorTimelock(), address(validatorTimelock));
    }

    function test_initializeV2_revertsOnDoubleInit() public {
        vm.expectRevert();
        eraMultisig.initializeV2(owner, executionDelay, address(validatorTimelock));
    }

    function test_initializeV2_revertsIfTimelockHasNoCode() public {
        address eoa = makeAddr("eoa");
        ProxyAdmin admin = new ProxyAdmin();
        EraMultisigValidator impl = new EraMultisigValidator(address(dummyBridgehub));
        vm.expectRevert(abi.encodeWithSelector(AddressHasNoCode.selector, eoa));
        new TransparentUpgradeableProxy(
            address(impl),
            address(admin),
            abi.encodeCall(EraMultisigValidator.initializeV2, (owner, executionDelay, eoa))
        );
    }

    function test_reinitializeV2_revertsIfAlreadyInitialized() public {
        vm.expectRevert();
        eraMultisig.reinitializeV2(address(validatorTimelock));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      THRESHOLD MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    function test_changeThreshold_setsNewValue() public {
        vm.prank(owner);
        eraMultisig.changeThreshold(5);
        assertEq(eraMultisig.threshold(), 5);
    }

    function test_changeThreshold_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(eraMultisig));
        emit IEraMultisigValidator.ThresholdChanged(3);
        eraMultisig.changeThreshold(3);
    }

    function test_changeThreshold_revertsIfNotOwner() public {
        vm.prank(nonMember);
        vm.expectRevert("Ownable: caller is not the owner");
        eraMultisig.changeThreshold(1);
    }

    function test_changeThreshold_canSetToZero() public {
        vm.prank(owner);
        eraMultisig.changeThreshold(0);
        assertEq(eraMultisig.threshold(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      MEMBERSHIP MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════

    function test_changeMembers_addsMembers() public view {
        assertTrue(eraMultisig.executionMultisigMember(member1));
        assertTrue(eraMultisig.executionMultisigMember(member2));
        assertTrue(eraMultisig.executionMultisigMember(member3));
    }

    function test_changeMembers_removesMembers() public {
        address[] memory toAdd = new address[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = member3;

        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);

        assertFalse(eraMultisig.executionMultisigMember(member3));
    }

    function test_changeMembers_emitsEventsOnAdd() public {
        address newMember = makeAddr("newMember");
        address[] memory toAdd = new address[](1);
        toAdd[0] = newMember;
        address[] memory toRemove = new address[](0);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(eraMultisig));
        emit IEraMultisigValidator.MultisigMemberChanged(newMember, true);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);
    }

    function test_changeMembers_emitsEventsOnRemove() public {
        address[] memory toAdd = new address[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = member1;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(eraMultisig));
        emit IEraMultisigValidator.MultisigMemberChanged(member1, false);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);
    }

    function test_changeMembers_revertsIfNotOwner() public {
        address[] memory toAdd = new address[](0);
        address[] memory toRemove = new address[](0);

        vm.prank(nonMember);
        vm.expectRevert("Ownable: caller is not the owner");
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);
    }

    function test_changeMembers_addAndRemoveInSameCall() public {
        address newMember = makeAddr("newMember");
        address[] memory toAdd = new address[](1);
        toAdd[0] = newMember;
        address[] memory toRemove = new address[](1);
        toRemove[0] = member1;

        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);

        assertTrue(eraMultisig.executionMultisigMember(newMember));
        assertFalse(eraMultisig.executionMultisigMember(member1));
    }

    function test_changeMembers_addThenRemoveSameAddress() public {
        // Add and then remove the same address in one call — remove wins (executed second)
        address target = makeAddr("target");
        address[] memory toAdd = new address[](1);
        toAdd[0] = target;
        address[] memory toRemove = new address[](1);
        toRemove[0] = target;

        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);

        assertFalse(eraMultisig.executionMultisigMember(target));
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      HASH APPROVAL
    // ═══════════════════════════════════════════════════════════════════

    function test_approveHash_recordsApproval() public {
        bytes32 hash = _sampleHash();

        vm.prank(member1);
        eraMultisig.approveHash(hash);

        assertTrue(eraMultisig.individualApprovals(member1, hash));
    }

    function test_approveHash_emitsEvent() public {
        bytes32 hash = _sampleHash();

        vm.prank(member1);
        vm.expectEmit(true, true, false, true, address(eraMultisig));
        emit IEraMultisigValidator.HashApproved(member1, hash);
        eraMultisig.approveHash(hash);
    }

    function test_approveHash_revertsIfNotMember() public {
        bytes32 hash = _sampleHash();

        vm.prank(nonMember);
        vm.expectRevert(IEraMultisigValidator.NotSigner.selector);
        eraMultisig.approveHash(hash);
    }

    function test_approveHash_revertsOnDoubleApproval() public {
        bytes32 hash = _sampleHash();

        vm.prank(member1);
        eraMultisig.approveHash(hash);

        vm.prank(member1);
        vm.expectRevert(IEraMultisigValidator.AlreadySigned.selector);
        eraMultisig.approveHash(hash);
    }

    function test_approveHash_multipleMembers() public {
        bytes32 hash = _sampleHash();

        vm.prank(member1);
        eraMultisig.approveHash(hash);

        vm.prank(member2);
        eraMultisig.approveHash(hash);

        assertEq(eraMultisig.getApprovals(hash), 2);
    }

    function test_approveHash_differentHashesAreIndependent() public {
        bytes32 hash1 = eraMultisig.calculateHash(chainAddress, 1, 10, hex"aa");
        bytes32 hash2 = eraMultisig.calculateHash(chainAddress, 1, 10, hex"bb");

        vm.prank(member1);
        eraMultisig.approveHash(hash1);

        vm.prank(member1);
        eraMultisig.approveHash(hash2);

        assertEq(eraMultisig.getApprovals(hash1), 1);
        assertEq(eraMultisig.getApprovals(hash2), 1);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      GET APPROVALS
    // ═══════════════════════════════════════════════════════════════════

    function test_getApprovals_returnsZeroForUnapprovedHash() public view {
        bytes32 hash = _sampleHash();
        assertEq(eraMultisig.getApprovals(hash), 0);
    }

    function test_getApprovals_countsOnlyCurrentMembers() public {
        bytes32 hash = _sampleHash();

        // member1 and member2 approve
        vm.prank(member1);
        eraMultisig.approveHash(hash);
        vm.prank(member2);
        eraMultisig.approveHash(hash);

        assertEq(eraMultisig.getApprovals(hash), 2);

        // Remove member1
        address[] memory toAdd = new address[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = member1;
        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);

        // Only member2's approval counts now
        assertEq(eraMultisig.getApprovals(hash), 1);
    }

    function test_getApprovals_readdedMemberCountsAgain() public {
        bytes32 hash = _sampleHash();

        // member1 approves
        vm.prank(member1);
        eraMultisig.approveHash(hash);

        assertEq(eraMultisig.getApprovals(hash), 1);

        // Remove member1
        address[] memory toAdd = new address[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = member1;
        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);

        assertEq(eraMultisig.getApprovals(hash), 0);

        // Re-add member1 — their old approval should count again
        address[] memory reAdd = new address[](1);
        reAdd[0] = member1;
        address[] memory noRemove = new address[](0);
        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(reAdd, noRemove);

        assertEq(eraMultisig.getApprovals(hash), 1);
    }

    function test_getApprovals_removingAllMembersZeroesCount() public {
        bytes32 hash = _sampleHash();

        vm.prank(member1);
        eraMultisig.approveHash(hash);
        vm.prank(member2);
        eraMultisig.approveHash(hash);
        vm.prank(member3);
        eraMultisig.approveHash(hash);

        assertEq(eraMultisig.getApprovals(hash), 3);

        // Remove all members
        address[] memory toAdd = new address[](0);
        address[] memory toRemove = new address[](3);
        toRemove[0] = member1;
        toRemove[1] = member2;
        toRemove[2] = member3;
        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);

        assertEq(eraMultisig.getApprovals(hash), 0);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      EXECUTE BATCHES
    // ═══════════════════════════════════════════════════════════════════

    function test_executeBatches_succeedsWhenThresholdMet() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();
        bytes32 hash = eraMultisig.calculateHash(chainAddress, from, to, data);

        vm.prank(member1);
        eraMultisig.approveHash(hash);
        vm.prank(member2);
        eraMultisig.approveHash(hash);

        vm.prank(executor);
        eraMultisig.executeBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_executeBatches_revertsWhenBelowThreshold() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();
        bytes32 hash = eraMultisig.calculateHash(chainAddress, from, to, data);

        // Only 1 approval, threshold is 2
        vm.prank(member1);
        eraMultisig.approveHash(hash);

        vm.prank(executor);
        vm.expectRevert(IEraMultisigValidator.NotEnoughSignatures.selector);
        eraMultisig.executeBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_executeBatches_revertsWithZeroApprovalsAndNonZeroThreshold() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();

        vm.prank(executor);
        vm.expectRevert(IEraMultisigValidator.NotEnoughSignatures.selector);
        eraMultisig.executeBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_executeBatches_succeedsWithThresholdZero() public {
        // Threshold 0 means no approvals needed
        vm.prank(owner);
        eraMultisig.changeThreshold(0);

        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();

        vm.prank(executor);
        eraMultisig.executeBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_executeBatches_failsAfterMemberRemovalDropsBelowThreshold() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();
        bytes32 hash = eraMultisig.calculateHash(chainAddress, from, to, data);

        // Both member1 and member2 approve (meets threshold of 2)
        vm.prank(member1);
        eraMultisig.approveHash(hash);
        vm.prank(member2);
        eraMultisig.approveHash(hash);

        // Remove member1 — drops valid approvals to 1
        address[] memory toAdd = new address[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = member1;
        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);

        vm.prank(executor);
        vm.expectRevert(IEraMultisigValidator.NotEnoughSignatures.selector);
        eraMultisig.executeBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_executeBatches_succeedsAfterReaddingMember() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();
        bytes32 hash = eraMultisig.calculateHash(chainAddress, from, to, data);

        vm.prank(member1);
        eraMultisig.approveHash(hash);
        vm.prank(member2);
        eraMultisig.approveHash(hash);

        // Remove member1
        address[] memory toAdd = new address[](0);
        address[] memory toRemove = new address[](1);
        toRemove[0] = member1;
        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(toAdd, toRemove);

        // Re-add member1 — restores to 2 valid approvals
        address[] memory reAdd = new address[](1);
        reAdd[0] = member1;
        address[] memory noRemove = new address[](0);
        vm.prank(owner);
        eraMultisig.changeExecutionMultisigMember(reAdd, noRemove);

        vm.prank(executor);
        eraMultisig.executeBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_executeBatches_revertsIfNotExecutorRole() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();

        vm.prank(nonMember);
        vm.expectRevert(
            abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress, executorRole, nonMember)
        );
        eraMultisig.executeBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_executeBatches_thresholdHigherThanMemberCount() public {
        // Set threshold to 5 but only 3 members exist — impossible to execute
        vm.prank(owner);
        eraMultisig.changeThreshold(5);

        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();
        bytes32 hash = eraMultisig.calculateHash(chainAddress, from, to, data);

        vm.prank(member1);
        eraMultisig.approveHash(hash);
        vm.prank(member2);
        eraMultisig.approveHash(hash);
        vm.prank(member3);
        eraMultisig.approveHash(hash);

        vm.prank(executor);
        vm.expectRevert(IEraMultisigValidator.NotEnoughSignatures.selector);
        eraMultisig.executeBatchesSharedBridge(chainAddress, from, to, data);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      PRECOMMIT / COMMIT / PROVE / REVERT FORWARDING
    // ═══════════════════════════════════════════════════════════════════

    function test_precommit_forwardsWithoutApprovalCheck() public {
        vm.prank(executor);
        eraMultisig.precommitSharedBridge(chainAddress, 1, hex"aa");
    }

    function test_precommit_revertsIfNotPrecommitterRole() public {
        vm.prank(nonMember);
        vm.expectRevert(
            abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress, precommitterRole, nonMember)
        );
        eraMultisig.precommitSharedBridge(chainAddress, 1, hex"aa");
    }

    function test_commitBatches_forwardsWithoutApprovalCheck() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();

        vm.prank(executor);
        eraMultisig.commitBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_commitBatches_revertsIfNotCommitterRole() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();

        vm.prank(nonMember);
        vm.expectRevert(
            abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress, committerRole, nonMember)
        );
        eraMultisig.commitBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_proveBatches_forwardsWithoutApprovalCheck() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();

        vm.prank(executor);
        eraMultisig.proveBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_proveBatches_revertsIfNotProverRole() public {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();

        vm.prank(nonMember);
        vm.expectRevert(
            abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress, proverRole, nonMember)
        );
        eraMultisig.proveBatchesSharedBridge(chainAddress, from, to, data);
    }

    function test_revertBatches_forwardsWithoutApprovalCheck() public {
        vm.prank(executor);
        eraMultisig.revertBatchesSharedBridge(chainAddress, 5);
    }

    function test_revertBatches_revertsIfNotReverterRole() public {
        vm.prank(nonMember);
        vm.expectRevert(
            abi.encodeWithSelector(RoleAccessDenied.selector, chainAddress, reverterRole, nonMember)
        );
        eraMultisig.revertBatchesSharedBridge(chainAddress, 5);
    }

    // ═══════════════════════════════════════════════════════════════════
    //                      CALCULATE HASH (EIP-712)
    // ═══════════════════════════════════════════════════════════════════

    function test_calculateHash_deterministic() public view {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();
        bytes32 hash1 = eraMultisig.calculateHash(chainAddress, from, to, data);
        bytes32 hash2 = eraMultisig.calculateHash(chainAddress, from, to, data);
        assertEq(hash1, hash2);
    }

    function test_calculateHash_differentParamsProduceDifferentHashes() public {
        address otherChain = makeAddr("otherChain");
        bytes32 hash1 = eraMultisig.calculateHash(chainAddress, 1, 10, hex"aa");
        bytes32 hash2 = eraMultisig.calculateHash(chainAddress, 1, 11, hex"aa");
        bytes32 hash3 = eraMultisig.calculateHash(chainAddress, 2, 10, hex"aa");
        bytes32 hash4 = eraMultisig.calculateHash(chainAddress, 1, 10, hex"bb");
        bytes32 hash5 = eraMultisig.calculateHash(otherChain, 1, 10, hex"aa");

        assertTrue(hash1 != hash2);
        assertTrue(hash1 != hash3);
        assertTrue(hash1 != hash4);
        assertTrue(hash1 != hash5);
    }

    function test_calculateHash_nonZero() public view {
        (uint256 from, uint256 to, bytes memory data) = _sampleBatchData();
        bytes32 hash = eraMultisig.calculateHash(chainAddress, from, to, data);
        assertTrue(hash != bytes32(0));
    }
}
