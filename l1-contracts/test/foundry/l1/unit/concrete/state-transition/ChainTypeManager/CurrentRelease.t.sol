// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {
    DEFAULT_L2_LOGS_TREE_ROOT_HASH,
    EMPTY_STRING_KECCAK,
    GENESIS_BATCH_COMMITMENT
} from "contracts/common/Config.sol";
import {
    GenesisBatchHashZero,
    ReleaseProtocolVersionMismatch,
    TransitionReleaseMismatch,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {ICommittedUpgrade} from "contracts/upgrades/registry/objects/ICommittedUpgrade.sol";
import {L2UpgradePlan} from "contracts/upgrades/registry/RegistryTypes.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";

/// @notice The CTM's `currentRelease` — the release new chains are created from — moves only
///         together with its protocol version, because a release IS one version: both version edges
///         install the release of the version they move to, in the same call. The releases (and the
///         transition) are mocked, as everywhere in this suite: the fixture CTM runs at version 0,
///         and the subject here is the CTM's bookkeeping, not the objects. The registry-driven path
///         with real objects is covered in `Upgrades/registry/CTMUpgradeExecutor.t.sol`.
contract CurrentReleaseTest is ChainTypeManagerTest {
    uint256 internal constant NEW_VERSION = uint256(1) << 32;

    function setUp() public {
        deploy();
    }

    /// @dev A stand-in transition answering exactly the reads `setNewVersionUpgradeFromTransition`
    ///      makes, so each test can make one of them disagree with the CTM.
    function _mockTransition(
        address _fromRelease,
        uint256 _oldVersion,
        uint256 _newVersion,
        address _newRelease
    ) internal returns (ICTMTransition transition) {
        transition = ICTMTransition(makeAddr("transition"));
        vm.etch(address(transition), hex"00");
        vm.mockCall(address(transition), abi.encodeCall(ICTMTransition.fromRelease, ()), abi.encode(_fromRelease));
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.oldProtocolVersion, ()),
            abi.encode(_oldVersion)
        );
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.newProtocolVersion, ()),
            abi.encode(_newVersion)
        );
        vm.mockCall(address(transition), abi.encodeCall(ICTMTransition.newRelease, ()), abi.encode(_newRelease));
        vm.mockCall(
            address(transition),
            abi.encodeCall(ICTMTransition.upgradeEngine, ()),
            abi.encode(makeAddr("upgradeEngine"))
        );
        // The commit's own checks: the code the transition names, and an L2 plan with nothing to
        // publish.
        vm.mockCall(address(transition), abi.encodeCall(ICTMTransition.validate, ()), "");
        L2UpgradePlan memory emptyPlan;
        vm.mockCall(address(transition), abi.encodeCall(ICommittedUpgrade.l2Plan, ()), abi.encode(emptyPlan));
    }

    function test_initializationStartsAtTheReleasesVersion() public view {
        assertEq(chainContractAddress.currentRelease(), Utils.TEST_GENESIS_REGISTRY, "genesis release");
        assertEq(
            chainContractAddress.protocolVersion(),
            ICTMRelease(Utils.TEST_GENESIS_REGISTRY).protocolVersion(),
            "the CTM starts at its genesis release's version"
        );
    }

    function test_theCutTakingEdgeInstallsTheReleaseOfItsVersion() public {
        address newRelease = _releaseAt(NEW_VERSION);
        address newGenesisUpgrade = makeAddr("newGenesisUpgrade");
        bytes32 genesisBatchHash = bytes32(uint256(0x02));
        uint64 genesisIndexRepeatedStorageChanges = 2;
        vm.mockCall(
            newRelease,
            abi.encodeWithSelector(ICTMRelease.genesisParams.selector),
            abi.encode(newGenesisUpgrade, genesisBatchHash, genesisIndexRepeatedStorageChanges)
        );

        vm.expectEmit(true, true, false, false);
        emit IChainTypeManager.NewCurrentRelease(NEW_VERSION, newRelease);
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(getDiamondCutData(diamondInit), 0, type(uint256).max, newRelease);

        assertEq(chainContractAddress.protocolVersion(), NEW_VERSION, "the version is the release's own");
        assertEq(chainContractAddress.currentRelease(), newRelease, "the release moved with it");
        assertEq(
            ICTMRelease(newRelease).protocolVersion(),
            chainContractAddress.protocolVersion(),
            "the installed release is the release of the CTM's version"
        );
        assertEq(chainContractAddress.l1GenesisUpgrade(), newGenesisUpgrade, "genesis reads the new release");
        IExecutor.StoredBatchInfo memory batchZero = IExecutor.StoredBatchInfo({
            batchNumber: 0,
            batchHash: genesisBatchHash,
            indexRepeatedStorageChanges: genesisIndexRepeatedStorageChanges,
            numberOfLayer1Txs: 0,
            priorityOperationsHash: EMPTY_STRING_KECCAK,
            l2LogsTreeRoot: DEFAULT_L2_LOGS_TREE_ROOT_HASH,
            dependencyRootsRollingHash: bytes32(0),
            timestamp: 0,
            commitment: GENESIS_BATCH_COMMITMENT
        });
        assertEq(chainContractAddress.storedBatchZero(), keccak256(abi.encode(batchZero)), "batch zero too");
    }

    function test_revertWhen_theCutTakingEdgeNamesNoRelease() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(getDiamondCutData(diamondInit), 0, type(uint256).max, address(0));
    }

    function test_revertWhen_theCutTakingEdgeIsNotTheOwners() public {
        address newRelease = _releaseAt(NEW_VERSION);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("notOwner"));
        chainContractAddress.setNewVersionUpgrade(getDiamondCutData(diamondInit), 0, type(uint256).max, newRelease);
    }

    function test_theTransitionEdgeInstallsItsTargetRelease() public {
        address newRelease = _releaseAt(NEW_VERSION);
        ICTMTransition transition = _mockTransition(Utils.TEST_GENESIS_REGISTRY, 0, NEW_VERSION, newRelease);

        vm.expectEmit(true, true, false, false);
        emit IChainTypeManager.NewCurrentRelease(NEW_VERSION, newRelease);
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgradeFromTransition(transition);

        assertEq(chainContractAddress.protocolVersion(), NEW_VERSION, "the version moved");
        assertEq(chainContractAddress.currentRelease(), newRelease, "and the release with it, in the same call");
        assertEq(
            ICTMRelease(chainContractAddress.currentRelease()).protocolVersion(),
            chainContractAddress.protocolVersion(),
            "the installed release is the release of the CTM's version"
        );
        assertEq(chainContractAddress.upgradeTransition(0), address(transition), "the edge is committed");
    }

    /// @dev The cut is derived from `fromRelease`'s routing, so the CTM refuses a transition that
    ///      departs from any release but its own — whoever the owner is.
    function test_revertWhen_theTransitionDepartsFromAnotherRelease() public {
        address otherRelease = _releaseAt(0);
        ICTMTransition transition = _mockTransition(otherRelease, 0, NEW_VERSION, _releaseAt(NEW_VERSION));

        vm.expectRevert(
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, otherRelease, Utils.TEST_GENESIS_REGISTRY)
        );
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgradeFromTransition(transition);
    }

    /// @dev A genuine `CTMTransition` cannot disagree with its own target release — it READS its
    ///      version from it — so this is the counterfeit case: an object claiming one version and
    ///      naming a release of another. The pointer and the version never come apart.
    function test_revertWhen_theTransitionsReleaseIsOfAnotherVersion() public {
        uint256 claimedVersion = NEW_VERSION;
        uint256 releaseVersion = SemVer.packSemVer(0, 2, 0);
        ICTMTransition transition = _mockTransition(
            Utils.TEST_GENESIS_REGISTRY,
            0,
            claimedVersion,
            _releaseAt(releaseVersion)
        );

        vm.expectRevert(
            abi.encodeWithSelector(ReleaseProtocolVersionMismatch.selector, claimedVersion, releaseVersion)
        );
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgradeFromTransition(transition);
    }

    /// @dev The transition is mocked: a real `CTMTransition` reads its target's version off
    ///      `newRelease` at construction, so it can never name a zero one.
    function test_revertWhen_theTransitionNamesNoRelease() public {
        ICTMTransition transition = _mockTransition(Utils.TEST_GENESIS_REGISTRY, 0, NEW_VERSION, address(0));

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgradeFromTransition(transition);

        assertEq(chainContractAddress.currentRelease(), Utils.TEST_GENESIS_REGISTRY, "the release did not move");
        assertEq(chainContractAddress.protocolVersion(), 0, "nor did the version");
    }

    /// @dev Every chain created from a release with a zero genesis batch hash would get an unusable
    ///      batch zero. A real `CTMRelease` refuses one at construction, so the release is mocked
    ///      here to isolate the CTM's own check.
    function test_revertWhen_theTransitionsReleaseHasNoGenesisBatchHash() public {
        address newRelease = _releaseAt(NEW_VERSION);
        vm.mockCall(
            newRelease,
            abi.encodeWithSelector(ICTMRelease.genesisParams.selector),
            abi.encode(makeAddr("genesisUpgrade"), bytes32(0), uint64(1))
        );
        ICTMTransition transition = _mockTransition(Utils.TEST_GENESIS_REGISTRY, 0, NEW_VERSION, newRelease);

        vm.expectRevert(GenesisBatchHashZero.selector);
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgradeFromTransition(transition);

        assertEq(chainContractAddress.currentRelease(), Utils.TEST_GENESIS_REGISTRY, "the release did not move");
        assertEq(chainContractAddress.protocolVersion(), 0, "nor did the version");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "nor was the edge committed");
    }
}
