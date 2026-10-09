// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {ZKChainDeployer} from "../_SharedZKChainDeployer.t.sol";
import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {Call} from "contracts/governance/Common.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {InvalidDAForPermanentRollup} from "contracts/common/L1ContractErrors.sol";

/// @notice Checks that the hand-off `protocol-ops hub init` / `ctm init` performs after the deploy scripts leaves
/// every contract with its intended owner and nothing with the deployer.
contract DeployOwnershipHandOffTest is ZKChainDeployer {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @dev `Governance` treats timestamp 1 (the test default) as "executed", so zero-delay operations need a later one.
    uint256 internal constant GOVERNANCE_READY_TIMESTAMP = 1_000;

    AdminFunctions internal adminFunctions;
    address internal deployer;

    function setUp() public {
        vm.warp(GOVERNANCE_READY_TIMESTAMP);
        // The harness accepts only part of the hand-off; the tests drive the rest.
        _deployL1Contracts();
        adminFunctions = new AdminFunctions();
        deployer = l1CoreContractsScript.getDeployerAddress();
    }

    function test_fullHandOff_leavesEveryContractWithItsIntendedOwner() public {
        address governance = ecosystemAddresses.shared.governance;
        address ctmGovernance = ctmAddresses.admin.governance;
        address ctmChainAdmin = ctmAddresses.chainAdmin;
        address ownerEoa = ecosystemConfig.ownerAddress;
        address ctm = address(addresses.chainTypeManager);
        address serverNotifier = ctmAddresses.stateTransition.proxies.serverNotifier;
        address validatorTimelock = ctmAddresses.stateTransition.proxies.validatorTimelock;

        // hub init.
        adminFunctions.governanceAcceptOwnerAggregated(governance, address(addresses.bridgehub));

        // ctm init. The ChainAdmin and owner-EOA steps broadcast as the script `--sender`, which a test cannot
        // choose, so they are issued as the call each helper broadcasts.
        Call[] memory calls = new Call[](2);
        calls[0] = Call({target: ctm, value: 0, data: abi.encodeCall(ChainTypeManager.acceptAdmin, ())});
        calls[1] = Call({target: serverNotifier, value: 0, data: abi.encodeCall(Ownable2Step.acceptOwnership, ())});
        vm.prank(Ownable2Step(ctmChainAdmin).owner());
        ChainAdmin(payable(ctmChainAdmin)).multicall(calls, true);
        vm.prank(ownerEoa);
        Ownable2Step(validatorTimelock).acceptOwnership();

        _assertHandedOff(address(addresses.bridgehub), governance);
        _assertHandedOff(address(addresses.sharedBridge), governance);
        _assertHandedOff(address(addresses.l1Nullifier), governance);
        _assertHandedOff(address(addresses.l1NativeTokenVault), governance);
        _assertHandedOff(address(addresses.l1InteropHandler), governance);
        _assertHandedOff(address(addresses.ctmDeploymentTracker), governance);
        _assertHandedOff(ecosystemAddresses.bridgehub.proxies.chainAssetHandler, governance);
        _assertHandedOff(address(addresses.chainRegistrationSender), governance);
        _assertHandedOff(ctm, ctmGovernance);
        assertEq(ChainTypeManager(ctm).admin(), ctmChainAdmin, "CTM admin");
        _assertHandedOff(ctmAddresses.daAddresses.daContracts.rollupDAManager, ctmGovernance);
        _assertHandedOff(serverNotifier, ctmChainAdmin);
        _assertHandedOff(validatorTimelock, ownerEoa);
    }

    function test_chainAdminAcceptOwner_acceptsThroughMulticall() public {
        // The script broadcasts as the test's default `tx.origin`, so that is the ChainAdmin owner here.
        ChainAdminOwnable chainAdmin = new ChainAdminOwnable(tx.origin, address(0));
        RollupDAManager target = new RollupDAManager();
        target.transferOwnership(address(chainAdmin));

        vm.expectEmit(true, true, false, false, address(target));
        emit OwnershipTransferred(address(this), address(chainAdmin));
        adminFunctions.chainAdminAcceptOwner(ChainAdmin(payable(address(chainAdmin))), address(target));

        assertEq(target.owner(), address(chainAdmin));
        assertEq(target.pendingOwner(), address(0));
    }

    function test_chainAdminAcceptOwner_revertsWhenSenderIsNotChainAdminOwner() public {
        ChainAdminOwnable chainAdmin = new ChainAdminOwnable(makeAddr("someoneElse"), address(0));
        RollupDAManager target = new RollupDAManager();
        target.transferOwnership(address(chainAdmin));

        vm.expectRevert("Ownable: caller is not the owner");
        adminFunctions.chainAdminAcceptOwner(ChainAdmin(payable(address(chainAdmin))), address(target));
        assertEq(target.pendingOwner(), address(chainAdmin));
    }

    function test_zksyncOSBlobsRollup_canBecomePermanentRollup() public {
        _deployEra();
        IZKChain chain = IZKChain(addresses.bridgehub.getZKChain(eraZKChainId));
        address chainAdmin = chain.getAdmin();
        address blobsValidator = ctmAddresses.daAddresses.l1BlobsDAValidatorZKsyncOS;

        vm.startPrank(chainAdmin);
        chain.setDAValidatorPair(blobsValidator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);
        chain.makePermanentRollup();

        (address l1DAValidator, L2DACommitmentScheme scheme) = chain.getDAValidatorPair();
        assertEq(l1DAValidator, blobsValidator);
        assertEq(uint256(scheme), uint256(L2DACommitmentScheme.BLOBS_ZKSYNC_OS));

        // The validator is not whitelisted with the calldata/blobs scheme.
        vm.expectRevert(InvalidDAForPermanentRollup.selector);
        chain.setDAValidatorPair(blobsValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);
        vm.stopPrank();
    }

    function _assertHandedOff(address _target, address _expectedOwner) internal view {
        address owner = Ownable2Step(_target).owner();
        assertEq(owner, _expectedOwner, vm.toString(_target));
        assertEq(Ownable2Step(_target).pendingOwner(), address(0), vm.toString(_target));
        assertTrue(owner != deployer, vm.toString(_target));
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
