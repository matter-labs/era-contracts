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

/// @notice Runs the hub and CTM deploy scripts, then accepts every pending ownership transfer through the
///         same AdminFunctions calls `protocol-ops hub init` / `ctm init` issue, and checks that each contract
///         ends with its intended owner, no pending owner, and nothing left with the deployer.
contract DeployOwnershipHandOffTest is ZKChainDeployer {
    /// @dev OZ `Ownable.OwnershipTransferred`, redeclared for `vm.expectEmit`.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @dev `IChainTypeManager.NewAdmin`, redeclared for `vm.expectEmit`.
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    /// @dev Any timestamp past `Governance.EXECUTED_PROPOSAL_TIMESTAMP` (1).
    uint256 internal constant GOVERNANCE_READY_TIMESTAMP = 1_000;

    AdminFunctions internal adminFunctions;
    address internal deployer;
    address internal ecosystemGovernance;
    address internal ctmGovernance;
    address internal ctmChainAdmin;
    address internal ownerEoa;

    function setUp() public {
        // `Governance` reserves timestamp 1 for "executed", so an operation scheduled with zero delay at
        // the default test timestamp (1) is never ready; move past it.
        vm.warp(GOVERNANCE_READY_TIMESTAMP);
        _deployL1ContractsWithoutAcceptingOwnership();
        adminFunctions = new AdminFunctions();

        // The deploy scripts broadcast as `tx.origin` (see `getDeployerAddress`).
        deployer = l1CoreContractsScript.getDeployerAddress();
        ecosystemGovernance = ecosystemAddresses.shared.governance;
        ctmGovernance = ctmAddresses.admin.governance;
        ctmChainAdmin = ctmAddresses.chainAdmin;
        ownerEoa = ecosystemConfig.ownerAddress;
        // Sanity: the roles the hand-off is checked against are distinct from the deployer.
        assertTrue(deployer != ownerEoa, "deployer and owner must differ for the test to mean anything");
    }

    /// @dev `hub init`: `governanceAcceptOwnerAggregated` (the bridgehub admin is already accepted by
    ///      `DeployL1CoreContracts.runForTest`).
    function _acceptHubOwnership() internal {
        // The three contracts the aggregated helper used to miss.
        vm.expectEmit(true, true, false, false, address(addresses.l1NativeTokenVault));
        emit OwnershipTransferred(deployer, ecosystemGovernance);
        vm.expectEmit(true, true, false, false, address(addresses.l1InteropHandler));
        emit OwnershipTransferred(deployer, ecosystemGovernance);
        vm.expectEmit(true, true, false, false, address(addresses.chainRegistrationSender));
        emit OwnershipTransferred(deployer, ecosystemGovernance);
        adminFunctions.governanceAcceptOwnerAggregated(ecosystemGovernance, address(addresses.bridgehub));
    }

    /// @dev `ctm init`: governance accepts CTM + RollupDAManager, the ChainAdmin (driven by its owner)
    ///      accepts the CTM admin + ServerNotifier, the owner EOA accepts ValidatorTimelock.
    ///      `chainAdminAcceptAdmin` / `chainAdminAcceptOwner` / `governanceAcceptOwnerConditional` broadcast as
    ///      the script `--sender` (bare `vm.startBroadcast()`), which a test cannot point at a chosen EOA
    ///      (pranks and broadcasts are incompatible). Those three steps are therefore issued here as the exact
    ///      call each helper broadcasts, from the sender protocol-ops passes; the helpers themselves are covered
    ///      by `test_chainAdminAcceptOwner_acceptsThroughMulticall` and the governance helpers run as-is.
    function _acceptCtmOwnership() internal {
        address ctm = address(addresses.chainTypeManager);
        address rollupDAManager = ctmAddresses.daAddresses.daContracts.rollupDAManager;
        address serverNotifier = ctmAddresses.stateTransition.proxies.serverNotifier;
        address validatorTimelock = ctmAddresses.stateTransition.proxies.validatorTimelock;
        address chainAdminOwner = Ownable2Step(ctmChainAdmin).owner();

        adminFunctions.governanceAcceptOwner(ctmGovernance, ctm);

        vm.expectEmit(false, true, false, false, ctm);
        emit NewAdmin(address(0), ctmChainAdmin);
        vm.prank(chainAdminOwner);
        ChainAdmin(payable(ctmChainAdmin)).multicall(
            _singleCall(ctm, abi.encodeCall(ChainTypeManager.acceptAdmin, ())),
            true
        );

        vm.expectEmit(true, true, false, false, rollupDAManager);
        emit OwnershipTransferred(deployer, ctmGovernance);
        adminFunctions.governanceAcceptOwner(ctmGovernance, rollupDAManager);

        vm.expectEmit(true, true, false, false, serverNotifier);
        emit OwnershipTransferred(deployer, ctmChainAdmin);
        vm.prank(chainAdminOwner);
        ChainAdmin(payable(ctmChainAdmin)).multicall(
            _singleCall(serverNotifier, abi.encodeCall(Ownable2Step.acceptOwnership, ())),
            true
        );

        vm.expectEmit(true, true, false, false, validatorTimelock);
        emit OwnershipTransferred(deployer, ownerEoa);
        vm.prank(ownerEoa);
        Ownable2Step(validatorTimelock).acceptOwnership();
    }

    function _singleCall(address _target, bytes memory _data) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
    }

    function _assertHandedOff(address _target, address _expectedOwner, string memory _name) internal view {
        assertEq(Ownable2Step(_target).owner(), _expectedOwner, string.concat(_name, ": owner"));
        assertEq(Ownable2Step(_target).pendingOwner(), address(0), string.concat(_name, ": pendingOwner"));
        assertTrue(Ownable2Step(_target).owner() != deployer, string.concat(_name, ": still owned by deployer"));
    }

    function test_fullFlow_leavesEveryContractWithItsIntendedOwner() public {
        _acceptHubOwnership();
        _acceptCtmOwnership();

        // Hub.
        _assertHandedOff(address(addresses.bridgehub), ecosystemGovernance, "Bridgehub");
        _assertHandedOff(address(addresses.sharedBridge), ecosystemGovernance, "L1AssetRouter");
        _assertHandedOff(address(addresses.l1Nullifier), ecosystemGovernance, "L1Nullifier");
        _assertHandedOff(address(addresses.l1NativeTokenVault), ecosystemGovernance, "L1NativeTokenVault");
        _assertHandedOff(address(addresses.l1InteropHandler), ecosystemGovernance, "L1InteropHandler");
        _assertHandedOff(address(addresses.ctmDeploymentTracker), ecosystemGovernance, "CTMDeploymentTracker");
        _assertHandedOff(
            ecosystemAddresses.bridgehub.proxies.chainAssetHandler,
            ecosystemGovernance,
            "L1ChainAssetHandler"
        );
        _assertHandedOff(address(addresses.chainRegistrationSender), ecosystemGovernance, "ChainRegistrationSender");
        assertEq(addresses.bridgehub.admin(), ecosystemAddresses.shared.bridgehubAdmin, "Bridgehub: admin");

        // CTM.
        _assertHandedOff(address(addresses.chainTypeManager), ctmGovernance, "ChainTypeManager");
        assertEq(ChainTypeManager(address(addresses.chainTypeManager)).admin(), ctmChainAdmin, "CTM: admin");
        _assertHandedOff(ctmAddresses.daAddresses.daContracts.rollupDAManager, ctmGovernance, "RollupDAManager");
        _assertHandedOff(ctmAddresses.stateTransition.proxies.serverNotifier, ctmChainAdmin, "ServerNotifier");
        _assertHandedOff(ctmAddresses.stateTransition.proxies.validatorTimelock, ownerEoa, "ValidatorTimelock");
    }

    /// @dev Re-running the aggregated helper after the hand-off is a no-op, as its doc promises.
    function test_aggregatedAccept_isIdempotent() public {
        _acceptHubOwnership();
        adminFunctions.governanceAcceptOwnerAggregated(ecosystemGovernance, address(addresses.bridgehub));
        _assertHandedOff(address(addresses.l1NativeTokenVault), ecosystemGovernance, "L1NativeTokenVault");
        _assertHandedOff(address(addresses.l1InteropHandler), ecosystemGovernance, "L1InteropHandler");
        _assertHandedOff(address(addresses.chainRegistrationSender), ecosystemGovernance, "ChainRegistrationSender");
    }

    /// @dev Before the hand-off the deployer still owns the vault, the interop handler and the
    ///      registration sender — the state `hub init` used to leave behind.
    function test_beforeAccept_deployerStillOwnsPendingContracts() public view {
        address[3] memory targets = [
            address(addresses.l1NativeTokenVault),
            address(addresses.l1InteropHandler),
            address(addresses.chainRegistrationSender)
        ];
        for (uint256 i = 0; i < targets.length; ++i) {
            assertEq(Ownable2Step(targets[i]).owner(), deployer);
            assertEq(Ownable2Step(targets[i]).pendingOwner(), ecosystemGovernance);
        }
    }

    /// @dev `chainAdminAcceptOwner` accepts a transfer pending to the ChainAdmin through its multicall, when the
    ///      script sender (here the test's default `tx.origin`) owns the ChainAdmin.
    function test_chainAdminAcceptOwner_acceptsThroughMulticall() public {
        address sender = tx.origin;
        ChainAdminOwnable chainAdmin = new ChainAdminOwnable(sender, address(0));
        RollupDAManager target = new RollupDAManager();
        target.transferOwnership(address(chainAdmin));

        vm.expectEmit(true, true, false, false, address(target));
        emit OwnershipTransferred(address(this), address(chainAdmin));
        adminFunctions.chainAdminAcceptOwner(ChainAdmin(payable(address(chainAdmin))), address(target));

        assertEq(target.owner(), address(chainAdmin));
        assertEq(target.pendingOwner(), address(0));
    }

    /// @dev `ChainAdminOwnable.multicall` is `onlyOwner`, so the step reverts when the sender does not own the
    ///      ChainAdmin — e.g. the ChainAdmin contract itself, which standalone `ctm init` used to pass.
    function test_chainAdminAcceptOwner_revertsWhenSenderIsNotChainAdminOwner() public {
        ChainAdminOwnable chainAdmin = new ChainAdminOwnable(makeAddr("someoneElse"), address(0));
        RollupDAManager target = new RollupDAManager();
        target.transferOwnership(address(chainAdmin));

        vm.expectRevert("Ownable: caller is not the owner");
        adminFunctions.chainAdminAcceptOwner(ChainAdmin(payable(address(chainAdmin))), address(target));
        assertEq(target.pendingOwner(), address(chainAdmin));
    }

    /// @dev The ZKsync OS blobs validator is whitelisted with the ZKsync OS blobs scheme (the scheme protocol-ops
    ///      picks for an L1-settling rollup), not with the calldata/blobs scheme `RollupL1DAValidator` uses.
    function test_rollupDAManager_whitelistsZKsyncOSBlobsPair() public view {
        RollupDAManager manager = RollupDAManager(ctmAddresses.daAddresses.daContracts.rollupDAManager);
        address blobsValidator = ctmAddresses.daAddresses.l1BlobsDAValidatorZKsyncOS;
        address rollupValidator = ctmAddresses.daAddresses.daContracts.rollupSLDAValidator;

        assertTrue(manager.isPairAllowed(blobsValidator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS));
        assertFalse(manager.isPairAllowed(blobsValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256));
        assertTrue(manager.isPairAllowed(rollupValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256));
        assertFalse(manager.isPairAllowed(rollupValidator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS));
    }

    /// @dev End to end: after the full hand-off, a ZKsync OS chain using the blobs validator can become a
    ///      permanent rollup, and is then locked to whitelisted pairs.
    function test_zksyncOSRollup_canBecomePermanentRollup() public {
        _acceptHubOwnership();
        _acceptCtmOwnership();
        addresses.bridgehubOwnerAddress = addresses.bridgehub.owner();

        _deployEra();
        IZKChain chain = IZKChain(addresses.bridgehub.getZKChain(eraZKChainId));
        address chainAdmin = chain.getAdmin();
        address blobsValidator = ctmAddresses.daAddresses.l1BlobsDAValidatorZKsyncOS;

        vm.startPrank(chainAdmin);
        chain.setDAValidatorPair(blobsValidator, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);
        chain.makePermanentRollup();
        vm.stopPrank();

        (address l1DAValidator, L2DACommitmentScheme scheme) = chain.getDAValidatorPair();
        assertEq(l1DAValidator, blobsValidator);
        assertEq(uint256(scheme), uint256(L2DACommitmentScheme.BLOBS_ZKSYNC_OS));

        // Permanent: a pair the manager has not whitelisted is now refused.
        vm.prank(chainAdmin);
        vm.expectRevert(InvalidDAForPermanentRollup.selector);
        chain.setDAValidatorPair(blobsValidator, L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256);
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
