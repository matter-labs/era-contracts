// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Utils} from "../Utils/Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MultisigCommitter} from "contracts/state-transition/MultisigCommitter.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {DummyChainTypeManagerForValidatorTimelock} from "contracts/dev-contracts/test/DummyChainTypeManagerForValidatorTimelock.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Unauthorized, TimeNotReached, RoleAccessDenied, ChainRequiresValidatorsSignaturesForCommit, NotEnoughSigners, SignerNotAuthorized, SignersNotSorted} from "contracts/common/L1ContractErrors.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {AccessControlEnumerablePerChainAddressUpgradeable} from "contracts/state-transition/AccessControlEnumerablePerChainAddressUpgradeable.sol";


contract MultisigCommitterTest is Test {
	MultisigCommitter multisigCommitter;
    DummyChainTypeManagerForValidatorTimelock chainTypeManager;
    DummyBridgehub dummyBridgehub;

    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);

	address ecosystemOwner;
	address chainAdmin;
	address chainAddress;
	address sequencer;
	address validator1Shared;
	uint256 validator1SharedKey;
	address validator2Shared;
	uint256 validator2SharedKey;
	address validator1Custom;
	uint256 validator1CustomKey;
	uint256 chainId;
	uint256 lastBatchNumber;
	uint32 executionDelay;

	bytes32 committerRole;
	bytes32 validatorRole;
	bytes32 constant EIP712_DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
	bytes32 constant EIP712_NAME_HASH = keccak256("MultisigCommitter");
	bytes32 constant EIP712_VERSION_HASH = keccak256("1");

    function setUp() public {
		ecosystemOwner = makeAddr("ecosystemOwner");
        chainAdmin = makeAddr("chainAdmin");
        chainAddress = makeAddr("chainAddress");
		sequencer = makeAddr("sequencer");
		
		// we want to have the validators sorted
		Vm.Wallet[3] memory validators = [
			vm.createWallet("validator1"),
			vm.createWallet("validator2"),
			vm.createWallet("validator3")
		];

		for (uint256 i = 0; i < validators.length; i++) {
			for (uint256 j = i + 1; j < validators.length; j++) {
				if (validators[j].addr < validators[i].addr) {
					Vm.Wallet memory tmp = validators[i];
					validators[i] = validators[j];
					validators[j] = tmp;
				}
			}
		}

		validator1Shared = validators[0].addr;
		validator1SharedKey = validators[0].privateKey;
		validator2Shared = validators[1].addr;
		validator2SharedKey = validators[1].privateKey;
		validator1Custom = validators[2].addr;
		validator1CustomKey = validators[2].privateKey;

        chainId = 1;
        lastBatchNumber = 123;
        executionDelay = 10;

        dummyBridgehub = new DummyBridgehub();

        chainTypeManager = new DummyChainTypeManagerForValidatorTimelock(chainAdmin, chainAddress);

        vm.mockCall(chainAddress, abi.encodeCall(IGetters.getAdmin, ()), abi.encode(chainAdmin));
        vm.mockCall(chainAddress, abi.encodeCall(IGetters.getChainId, ()), abi.encode(chainId));
        dummyBridgehub.setZKChain(chainId, chainAddress);

        multisigCommitter = MultisigCommitter(_deployMultisigCommitter(ecosystemOwner, executionDelay));
        committerRole = multisigCommitter.COMMITTER_ROLE();
        validatorRole = multisigCommitter.COMMIT_VALIDATOR_ROLE();

        vm.prank(chainAdmin);
        multisigCommitter.addValidatorForChainId(chainId, sequencer);
		vm.prank(chainAdmin);
		multisigCommitter.grantRole(chainAddress, validatorRole, validator1Custom);
		vm.prank(ecosystemOwner);
		multisigCommitter.addSharedValidator(validator1Shared);
		vm.prank(ecosystemOwner);
		multisigCommitter.addSharedValidator(validator2Shared);
		vm.prank(ecosystemOwner);
		multisigCommitter.setSharedSigningThreshold(2);
    }

	function _deployMultisigCommitter(address _initialOwner, uint32 _initialExecutionDelay) internal returns (address) {
		ProxyAdmin admin = new ProxyAdmin();
		MultisigCommitter multisigCommitterImplementation = new MultisigCommitter(address(dummyBridgehub));
		return
			address(
				new TransparentUpgradeableProxy(
					address(multisigCommitterImplementation),
					address(admin),
					abi.encodeCall(MultisigCommitter.initialize, (_initialOwner, _initialExecutionDelay))
				)
			);
	}

	function test_SuccessfulConstruction() public {
		MultisigCommitter multisigCommitter = MultisigCommitter(_deployMultisigCommitter(ecosystemOwner, executionDelay));
		assertEq(multisigCommitter.owner(), ecosystemOwner);
		assertEq(multisigCommitter.executionDelay(), executionDelay);
	}

	function test_customVsDefaultSigningSet() public {
		assertEq(multisigCommitter.sharedSigningThreshold(), 2);
		assertEq(multisigCommitter.sharedValidatorsCount(), 2);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 2);
		assertEq(multisigCommitter.getValidatorsCount(chainAddress), 2);
		
		vm.prank(chainAdmin);
		multisigCommitter.setSigningThreshold(chainAddress, 1);
		// setting the threshold has no effect unless customValidatorSet is enabled
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 2);
		assertEq(multisigCommitter.getValidatorsCount(chainAddress), 2);

		vm.prank(ecosystemOwner);
        multisigCommitter.useCustomSigningSet(chainAddress);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 1);
		assertEq(multisigCommitter.getValidatorsCount(chainAddress), 1);

		vm.prank(chainAdmin);
		multisigCommitter.useSharedSigningSet(chainAddress);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 2);
		assertEq(multisigCommitter.getValidatorsCount(chainAddress), 2);
	}

	function test_custom_validator_set_enablemenet_permissions() public {
		vm.prank(chainAdmin);
		vm.expectRevert(); // chain admin cannot enable custom validator set
		multisigCommitter.useCustomSigningSet(chainAddress);

		vm.prank(ecosystemOwner);
		multisigCommitter.useCustomSigningSet(chainAddress);

		vm.prank(ecosystemOwner);
		vm.expectRevert(); // ecosystem owner cannot revoke custom validator set
		multisigCommitter.useSharedSigningSet(chainAddress); 

		vm.prank(chainAdmin);
		multisigCommitter.useSharedSigningSet(chainAddress); 
	}

	function test_addingRemovingSharedValidators() public {
		address validator3Shared = makeAddr("validator3Shared");
		vm.prank(ecosystemOwner);
		multisigCommitter.addSharedValidator(validator3Shared);
		assertEq(multisigCommitter.sharedValidatorsCount(), 3);
		assertEq(multisigCommitter.getValidatorsCount(chainAddress), 3);
		assertTrue(multisigCommitter.isSharedValidator(validator3Shared));
		assertTrue(multisigCommitter.isValidator(chainAddress, validator3Shared));
		
		vm.prank(ecosystemOwner);
		multisigCommitter.removeSharedValidator(validator1Shared);
		assertEq(multisigCommitter.sharedValidatorsCount(), 2);
		assertEq(multisigCommitter.getValidatorsCount(chainAddress), 2);
		assertFalse(multisigCommitter.isSharedValidator(validator1Shared));
		assertFalse(multisigCommitter.isValidator(chainAddress, validator1Shared));

		vm.prank(ecosystemOwner);
		multisigCommitter.removeSharedValidator(validator3Shared);
		assertEq(multisigCommitter.sharedValidatorsCount(), 1);
		assertEq(multisigCommitter.getValidatorsCount(chainAddress), 1);
		assertFalse(multisigCommitter.isSharedValidator(validator3Shared));
		assertFalse(multisigCommitter.isValidator(chainAddress, validator3Shared));

		vm.prank(ecosystemOwner);
		multisigCommitter.addSharedValidator(validator1Shared);
		assertEq(multisigCommitter.sharedValidatorsCount(), 2);
		assertEq(multisigCommitter.getValidatorsCount(chainAddress), 2);
		assertTrue(multisigCommitter.isSharedValidator(validator1Shared));
		assertTrue(multisigCommitter.isValidator(chainAddress, validator1Shared));
	}

	function test_changeSharedSigningThreshold() public {
		vm.prank(ecosystemOwner);
		multisigCommitter.setSharedSigningThreshold(0);
		assertEq(multisigCommitter.sharedSigningThreshold(), 0);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 0);

		vm.prank(ecosystemOwner);
		multisigCommitter.setSharedSigningThreshold(2);
		assertEq(multisigCommitter.sharedSigningThreshold(), 2);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 2);
	}

	function prepareCommit() internal returns (uint256, uint256, bytes memory) {
		vm.mockCall(chainAddress, abi.encodeWithSelector(IExecutor.commitBatchesSharedBridge.selector), abi.encode(chainId));

        IExecutor.StoredBatchInfo memory storedBatch = Utils.createStoredBatchInfo();
        IExecutor.CommitBatchInfo memory batchToCommit = Utils.createCommitBatchInfo();

        IExecutor.CommitBatchInfo[] memory batchesToCommit = new IExecutor.CommitBatchInfo[](1);
        batchesToCommit[0] = batchToCommit;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils.encodeCommitBatchesData(
            storedBatch,
            batchesToCommit
        );
        return (commitBatchFrom, commitBatchTo, commitData);
	}

	function test_cannot_commit_without_signatures() public {
		(uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = prepareCommit();
		vm.prank(sequencer);
        vm.expectRevert(abi.encodeWithSelector(ChainRequiresValidatorsSignaturesForCommit.selector));
        multisigCommitter.commitBatchesSharedBridge(chainAddress, commitBatchFrom, commitBatchTo, commitData);
	}

	function test_multisig_can_be_disabled() public {
		vm.prank(ecosystemOwner);
		multisigCommitter.setSharedSigningThreshold(0);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 0);
		
		(uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = prepareCommit();
		vm.prank(sequencer);
        multisigCommitter.commitBatchesSharedBridge(chainAddress, commitBatchFrom, commitBatchTo, commitData);
	}

	function hashCommitData(uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) internal view returns (bytes32) {
		// build the same EIP-712 digest as in MultisigCommitter.commitBatchesMultisig
		bytes32 typeHash = keccak256(
			"CommitBatchesMultisig(address chainAddress,uint256 processBatchFrom,uint256 processBatchTo,bytes batchData)"
		);
		bytes32 structHash = keccak256(
			abi.encode(typeHash, chainAddress, commitBatchFrom, commitBatchTo, keccak256(commitData))
		);
		bytes32 domainSeparator = keccak256(
			abi.encode(
				EIP712_DOMAIN_TYPEHASH,
				EIP712_NAME_HASH,
				EIP712_VERSION_HASH,
				block.chainid,
				address(multisigCommitter)
			)
		);
		bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));	
		return digest;
	}

	function sign_digest(uint256 key, bytes32 digest) internal view returns (bytes memory) {
		(uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
		return abi.encodePacked(r, s, v);
	}

	function test_commit_with_signatures() public {
		(uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = prepareCommit();
		bytes32 digest = hashCommitData(commitBatchFrom, commitBatchTo, commitData);

		// we have a guarantee that signers are sorted
		address[] memory signers = new address[](2);
		signers[0] = validator1Shared;
		signers[1] = validator2Shared;

		uint256[] memory keys = new uint256[](2);
		keys[0] = validator1SharedKey;
		keys[1] = validator2SharedKey;

		bytes[] memory signatures = new bytes[](2);
		for (uint256 i = 0; i < 2; i++) {
			signatures[i] = sign_digest(keys[i], digest);
		}

		vm.prank(sequencer);
		multisigCommitter.commitBatchesMultisig(
			chainAddress,
			commitBatchFrom,
			commitBatchTo,
			commitData,
			signers,
			signatures
		);
	}

	function test_commit_with_signatures_failure_cases() public {
		(uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = prepareCommit();
		bytes32 digest = hashCommitData(commitBatchFrom, commitBatchTo, commitData);

		// Not enough signers case

		address[] memory signers = new address[](1);
		signers[0] = validator1Shared;
		uint256[] memory keys = new uint256[](1);
		keys[0] = validator1SharedKey;
		bytes[] memory signatures = new bytes[](1);
		signatures[0] = sign_digest(keys[0], digest);

		vm.prank(sequencer);
		vm.expectRevert(abi.encodeWithSelector(NotEnoughSigners.selector, 1, 2));
		multisigCommitter.commitBatchesMultisig(
			chainAddress,
			commitBatchFrom,
			commitBatchTo,
			commitData,
			signers,
			signatures
		);

		// Unauthorized signer case

		signers = new address[](2);
		signers[0] = validator1Shared;
		signers[1] = validator1Custom;
		keys = new uint256[](2);
		keys[0] = validator1SharedKey;
		keys[1] = validator1CustomKey;
		signatures = new bytes[](2);
		signatures[0] = sign_digest(keys[0], digest);
		signatures[1] = sign_digest(keys[1], digest);

		vm.prank(sequencer);
		vm.expectRevert(abi.encodeWithSelector(SignerNotAuthorized.selector, validator1Custom));
		multisigCommitter.commitBatchesMultisig(
			chainAddress,
			commitBatchFrom,
			commitBatchTo,
			commitData,
			signers,
			signatures
		);

		// Duplicated signer

		signers[1] = signers[0];
		signatures[1] = signatures[0];

		vm.prank(sequencer);
		vm.expectRevert(abi.encodeWithSelector(SignersNotSorted.selector));
		multisigCommitter.commitBatchesMultisig(
			chainAddress,
			commitBatchFrom,
			commitBatchTo,
			commitData,
			signers,
			signatures
		);
	}
}
