// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ZKChainDeployer} from "../_SharedZKChainDeployer.t.sol";
import {AdminFunctions} from "deploy-scripts/AdminFunctions.s.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {Call} from "contracts/governance/Common.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {
    BootstrapAuthorityNotHeld,
    BootstrapExecutorNotBound,
    BootstrapExecutorOwnerMismatch,
    BootstrapNominationPending,
    BootstrapServerNotifierNotBound,
    InvalidDAForPermanentRollup
} from "contracts/common/L1ContractErrors.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {RegistryAuthorityLib} from "contracts/upgrades/registry/libraries/RegistryAuthorityLib.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {Utils} from "deploy-scripts/utils/Utils.sol";

/// @notice Checks that the hand-off `protocol-ops hub init` / `ctm init` performs after the deploy scripts leaves
/// every contract with its intended owner and nothing with the deployer — and that a fresh ecosystem is born in
/// the registry model: the end state passes the same completion check a v35 bootstrap must pass.
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

    /// @dev The upgrade executors' nominations are accepted by the tests, through the steps protocol-ops runs.
    function _harnessAcceptsUpgradeExecutors() internal pure override returns (bool) {
        return false;
    }

    function test_fullHandOff_leavesEveryContractWithItsIntendedOwner() public {
        address governance = ecosystemAddresses.shared.governance;
        address ctmGovernance = ctmAddresses.admin.governance;
        address ctmChainAdmin = ctmAddresses.chainAdmin;
        address ownerEoa = ecosystemConfig.ownerAddress;
        address ctm = address(addresses.chainTypeManager);
        address serverNotifier = ctmAddresses.stateTransition.proxies.serverNotifier;
        address validatorTimelock = ctmAddresses.stateTransition.proxies.validatorTimelock;

        _runProtocolOpsHandOff();

        _assertHandedOff(address(addresses.bridgehub), governance);
        _assertHandedOff(address(addresses.sharedBridge), governance);
        _assertHandedOff(address(addresses.l1Nullifier), governance);
        _assertHandedOff(address(addresses.l1NativeTokenVault), governance);
        _assertHandedOff(address(addresses.l1InteropHandler), governance);
        _assertHandedOff(address(addresses.ctmDeploymentTracker), governance);
        _assertHandedOff(ecosystemAddresses.bridgehub.proxies.chainAssetHandler, governance);
        _assertHandedOff(address(addresses.chainRegistrationSender), governance);
        assertEq(ChainTypeManager(ctm).admin(), ctmChainAdmin, "CTM admin");
        _assertHandedOff(ctmAddresses.daAddresses.daContracts.rollupDAManager, ctmGovernance);
        _assertHandedOff(validatorTimelock, ownerEoa);

        // The registry authority: governance owns both executors, the CTM domain is the CTM executor's.
        _assertHandedOff(upgradeExecutors.coreExecutor, governance);
        _assertHandedOff(upgradeExecutors.ctmExecutor, governance);
        _assertHandedOff(ctm, upgradeExecutors.ctmExecutor);
        _assertHandedOff(serverNotifier, upgradeExecutors.ctmExecutor);
        assertEq(
            ProxyAdmin(ecosystemAddresses.shared.transparentProxyAdmin).owner(),
            upgradeExecutors.coreExecutor,
            "the ecosystem ProxyAdmin is the core executor's"
        );
        assertEq(
            ProxyAdmin(ctmAddresses.admin.transparentProxyAdmin).owner(),
            upgradeExecutors.ctmExecutor,
            "the CTM-domain ProxyAdmin is the CTM executor's"
        );
    }

    /// @notice THE fresh-deployment completion check: after the hand-off, the ecosystem is in the
    ///         registry-era authority shape.
    function test_freshEcosystem_passesTheCompletionCheck() public {
        _runProtocolOpsHandOff();
        RegistryAuthorityLib.requireRegistryAuthority(_freshAuthority());
    }

    /// @notice Each authority of the shape is checked: naming the wrong holder of the CTM, or a
    ///         ProxyAdmin the CTM executor does not hold, fails the check.
    function test_completionCheck_revertsOnTheWrongCTMOrProxyAdminHolder() public {
        _runProtocolOpsHandOff();
        RegistryAuthorityLib.Authority memory authority = _freshAuthority();
        authority.ctmExecutor = upgradeExecutors.coreExecutor;
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapAuthorityNotHeld.selector,
                address(addresses.chainTypeManager),
                upgradeExecutors.ctmExecutor
            )
        );
        this.checkAuthority(authority);

        authority = _freshAuthority();
        authority.ctmProxyAdmin = ProxyAdmin(ecosystemAddresses.shared.transparentProxyAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapAuthorityNotHeld.selector,
                ecosystemAddresses.shared.transparentProxyAdmin,
                upgradeExecutors.coreExecutor
            )
        );
        this.checkAuthority(authority);
    }

    /// @notice The CTM executor must be bound to the ProxyAdmin the shape names, not merely hold it.
    function test_completionCheck_revertsWhenTheCTMExecutorIsBoundToAnotherProxyAdmin() public {
        _runProtocolOpsHandOff();
        ProxyAdmin unbound = new ProxyAdmin();
        unbound.transferOwnership(upgradeExecutors.ctmExecutor);
        RegistryAuthorityLib.Authority memory authority = _freshAuthority();
        authority.ctmProxyAdmin = unbound;
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                upgradeExecutors.ctmExecutor,
                address(unbound),
                ctmAddresses.admin.transparentProxyAdmin
            )
        );
        this.checkAuthority(authority);
    }

    /// @notice An outstanding nomination on the CTM fails the check: the nominee could claim it.
    function test_completionCheck_revertsOnAPendingCTMNomination() public {
        _runProtocolOpsHandOff();
        address nominee = makeAddr("nominee");
        _forwardAsGovernance(
            upgradeExecutors.ctmExecutor,
            address(addresses.chainTypeManager),
            abi.encodeCall(Ownable2Step.transferOwnership, (nominee))
        );
        vm.expectRevert(
            abi.encodeWithSelector(BootstrapNominationPending.selector, address(addresses.chainTypeManager), nominee)
        );
        this.checkFreshAuthority();
    }

    /// @notice The ecosystem ProxyAdmin must stay the core executor's.
    function test_completionCheck_revertsWhenTheCoreExecutorLostTheEcosystemProxyAdmin() public {
        _runProtocolOpsHandOff();
        address stranger = makeAddr("stranger");
        _forwardAsGovernance(
            upgradeExecutors.coreExecutor,
            ecosystemAddresses.shared.transparentProxyAdmin,
            abi.encodeWithSignature("transferOwnership(address)", stranger)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapAuthorityNotHeld.selector,
                ecosystemAddresses.shared.transparentProxyAdmin,
                stranger
            )
        );
        this.checkFreshAuthority();
    }

    /// @notice The ServerNotifier must be the CTM's, serve the CTM, and be the CTM executor's.
    function test_completionCheck_revertsOnAnUnboundOrForeignServerNotifier() public {
        _runProtocolOpsHandOff();
        address notifier = ctmAddresses.stateTransition.proxies.serverNotifier;

        RegistryAuthorityLib.Authority memory authority = _freshAuthority();
        address otherNotifier = makeAddr("otherNotifier");
        authority.serverNotifier = otherNotifier;
        vm.expectRevert(abi.encodeWithSelector(BootstrapServerNotifierNotBound.selector, otherNotifier, notifier));
        this.checkAuthority(authority);

        address otherCTM = makeAddr("otherCTM");
        _forwardAsGovernance(
            upgradeExecutors.ctmExecutor,
            notifier,
            abi.encodeCall(ServerNotifier.setChainTypeManager, (IChainTypeManager(otherCTM)))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapServerNotifierNotBound.selector,
                address(addresses.chainTypeManager),
                otherCTM
            )
        );
        this.checkFreshAuthority();
    }

    /// @notice A ServerNotifier owned by anyone but the CTM executor fails the check.
    function test_completionCheck_revertsWhenTheNotifierLeftTheCTMDomain() public {
        _runProtocolOpsHandOff();
        address notifier = ctmAddresses.stateTransition.proxies.serverNotifier;
        address stranger = makeAddr("stranger");
        _forwardAsGovernance(
            upgradeExecutors.ctmExecutor,
            notifier,
            abi.encodeCall(Ownable2Step.transferOwnership, (stranger))
        );
        vm.prank(stranger);
        Ownable2Step(notifier).acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(BootstrapAuthorityNotHeld.selector, notifier, stranger));
        this.checkFreshAuthority();
    }

    /// @notice The deploy scripts construct the executors for the deployer and only nominate governance, so
    ///         a fresh ecosystem whose governance has not accepted yet is NOT in the registry shape.
    function test_freshEcosystem_failsTheCompletionCheckUntilGovernanceAccepts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorOwnerMismatch.selector,
                upgradeExecutors.ctmExecutor,
                ecosystemAddresses.shared.governance,
                deployer
            )
        );
        this.checkFreshAuthority();

        // hub init alone leaves the CTM executor's nomination outstanding.
        adminFunctions.governanceAcceptOwnerAggregated(
            ecosystemAddresses.shared.governance,
            address(addresses.bridgehub)
        );
        assertEq(Ownable2Step(upgradeExecutors.coreExecutor).owner(), ecosystemAddresses.shared.governance);
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorOwnerMismatch.selector,
                upgradeExecutors.ctmExecutor,
                ecosystemAddresses.shared.governance,
                deployer
            )
        );
        this.checkFreshAuthority();
    }

    /// @notice The executors are born bound to the domains they hold, and constructed exactly as the deploy
    ///         outputs record them (the record protocol-ops re-derives them from).
    function test_freshEcosystem_executorsAreBoundAndRecorded() public view {
        CoreUpgradeExecutor coreExecutor = CoreUpgradeExecutor(payable(upgradeExecutors.coreExecutor));
        CTMUpgradeExecutor ctmExecutor = CTMUpgradeExecutor(payable(upgradeExecutors.ctmExecutor));
        assertEq(address(coreExecutor.PROXY_ADMIN()), ecosystemAddresses.shared.transparentProxyAdmin);
        assertEq(address(ctmExecutor.CHAIN_TYPE_MANAGER()), address(addresses.chainTypeManager));
        assertEq(address(ctmExecutor.CTM_PROXY_ADMIN()), ctmAddresses.admin.transparentProxyAdmin);
        assertTrue(
            ctmAddresses.admin.transparentProxyAdmin != ecosystemAddresses.shared.transparentProxyAdmin,
            "the two domains have distinct ProxyAdmins"
        );

        string memory root = vm.projectRoot();
        string memory l1Output = vm.readFile(string.concat(root, vm.envString("L1_OUTPUT")));
        string memory ctmOutput = vm.readFile(string.concat(root, vm.envString("CTM_OUTPUT")));
        bytes32 salt = vm.parseTomlBytes32(l1Output, "$.upgrade_executors.core_executor.create2_salt");
        assertEq(
            Utils.canonicalCreate2Address(
                salt,
                vm.getCode("CoreUpgradeExecutor.sol:CoreUpgradeExecutor"),
                abi.encode(
                    vm.parseTomlAddress(l1Output, "$.upgrade_executors.core_executor.initial_owner"),
                    vm.parseTomlAddress(l1Output, "$.upgrade_executors.core_executor.proxy_admin")
                )
            ),
            vm.parseTomlAddress(l1Output, "$.upgrade_executors.core_executor.address"),
            "the core executor re-derives from its record"
        );
        assertEq(vm.parseTomlAddress(l1Output, "$.upgrade_executors.core_executor.address"), address(coreExecutor));
        assertFalse(vm.keyExistsToml(l1Output, "$.upgrade_executors.coordinator"), "no coordinator is deployed");
        assertEq(
            Utils.canonicalCreate2Address(
                vm.parseTomlBytes32(ctmOutput, "$.upgrade_executors.ctm_executor.create2_salt"),
                vm.getCode("CTMUpgradeExecutor.sol:CTMUpgradeExecutor"),
                abi.encode(
                    vm.parseTomlAddress(ctmOutput, "$.upgrade_executors.ctm_executor.initial_owner"),
                    vm.parseTomlAddress(ctmOutput, "$.upgrade_executors.ctm_executor.chain_type_manager"),
                    vm.parseTomlAddress(ctmOutput, "$.upgrade_executors.ctm_executor.ctm_proxy_admin")
                )
            ),
            address(ctmExecutor),
            "the CTM executor re-derives from its record"
        );
        assertEq(
            vm.parseTomlAddress(ctmOutput, "$.upgrade_executors.ctm_executor.initial_owner"),
            deployer,
            "constructed for the deployer, which nominated governance"
        );
    }

    /// @dev External so a revert can be expected on it.
    function checkFreshAuthority() external view {
        RegistryAuthorityLib.requireRegistryAuthority(_freshAuthority());
    }

    /// @dev External so a revert can be expected on it.
    function checkAuthority(RegistryAuthorityLib.Authority memory _authority) external view {
        RegistryAuthorityLib.requireRegistryAuthority(_authority);
    }

    /// @dev Governance drives an executor's owner-gated `forward`, the only way it acts on a domain.
    function _forwardAsGovernance(address _executor, address _target, bytes memory _data) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
        vm.prank(ecosystemAddresses.shared.governance);
        CTMUpgradeExecutor(payable(_executor)).forward(calls);
    }

    /// @dev The accept steps protocol-ops runs: `hub init` (`governanceAcceptOwnerAggregated`, which now also
    ///      accepts the core executor) and `ctm init` (the CTM admin through the ChainAdmin,
    ///      the CTM executor through governance, the validator timelock by the owner EOA). The ChainAdmin and
    ///      owner-EOA steps broadcast as the script `--sender`, which a test cannot choose, so they are issued as
    ///      the call each helper broadcasts.
    function _runProtocolOpsHandOff() internal {
        address governance = ecosystemAddresses.shared.governance;
        adminFunctions.governanceAcceptOwnerAggregated(governance, address(addresses.bridgehub));

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(addresses.chainTypeManager),
            value: 0,
            data: abi.encodeCall(ChainTypeManager.acceptAdmin, ())
        });
        vm.prank(Ownable2Step(ctmAddresses.chainAdmin).owner());
        ChainAdmin(payable(ctmAddresses.chainAdmin)).multicall(calls, true);
        adminFunctions.governanceAcceptOwner(governance, upgradeExecutors.ctmExecutor);
        vm.prank(ecosystemConfig.ownerAddress);
        Ownable2Step(ctmAddresses.stateTransition.proxies.validatorTimelock).acceptOwnership();
    }

    function _freshAuthority() internal view returns (RegistryAuthorityLib.Authority memory) {
        return
            RegistryAuthorityLib.Authority({
                ctm: address(addresses.chainTypeManager),
                ctmProxyAdmin: ProxyAdmin(ctmAddresses.admin.transparentProxyAdmin),
                serverNotifier: ctmAddresses.stateTransition.proxies.serverNotifier,
                ctmExecutor: upgradeExecutors.ctmExecutor,
                coreExecutor: upgradeExecutors.coreExecutor,
                governance: ecosystemAddresses.shared.governance
            });
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
