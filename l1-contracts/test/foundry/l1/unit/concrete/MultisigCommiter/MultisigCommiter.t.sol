// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {Unauthorized, TimeNotReached, RoleAccessDenied} from "contracts/common/L1ContractErrors.sol";
import {DummyBridgehub} from "contracts/dev-contracts/test/DummyBridgehub.sol";
import {AccessControlEnumerablePerChainAddressUpgradeable} from "contracts/state-transition/AccessControlEnumerablePerChainAddressUpgradeable.sol";


contract MultisigCommiterTest is Test {
	MultisigCommitter multisigCommitter;
    DummyChainTypeManagerForValidatorTimelock chainTypeManager;
    DummyBridgehub dummyBridgehub;

    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);

	address ecosystemOwner;
	address chainAdmin;
	address chainAddress;
	address sequencer;
	address verifier1Shared;
	address verifier2Shared;
	address verifier3Custom;
	uint256 chainId;
	uint256 lastBatchNumber;
	uint32 executionDelay;

	bytes32 committerRole;
	bytes32 verifierRole;

    function setUp() public {
		ecosystemOwner = makeAddr("ecosystemOwner");
        chainAdmin = makeAddr("chainAdmin");
        chainAddress = makeAddr("chainAddress");
		sequencer = makeAddr("sequencer");
		verifier1Shared = makeAddr("verifier1Shared");
		verifier2Shared = makeAddr("verifier2Shared");
		verifier3Custom = makeAddr("verifier3Custom");

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
        verifierRole = multisigCommitter.COMMIT_VERIFIER_ROLE();

        vm.prank(chainAdmin);
        multisigCommitter.addValidatorForChainId(chainId, sequencer);
		vm.prank(chainAdmin);
		multisigCommitter.grantRole(chainAddress, verifierRole, verifier3Custom);
		vm.prank(ecosystemOwner);
		multisigCommitter.addSharedVerifier(verifier1Shared);
		vm.prank(ecosystemOwner);
		multisigCommitter.addSharedVerifier(verifier2Shared);
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
		assertEq(multisigCommitter.sharedVerifiersCount(), 2);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 2);
		assertEq(multisigCommitter.getVerifiersCount(chainAddress), 2);
		
		vm.prank(chainAdmin);
		multisigCommitter.setSigningThreshold(chainAddress, 1);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 1);
		assertEq(multisigCommitter.getVerifiersCount(chainAddress), 1);

		vm.prank(chainAdmin);
		multisigCommitter.useSharedSigningSet(chainAddress);
		assertEq(multisigCommitter.getSigningThreshold(chainAddress), 2);
		assertEq(multisigCommitter.getVerifiersCount(chainAddress), 2);
	}
}
