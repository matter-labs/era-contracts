// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {NoCommittedUpgradeCutForVersion} from "contracts/common/L1ContractErrors.sol";

/// @notice `setUpgradeDiamondCut` re-commits the cut of a LEGACY-committed departure only. The
///         refusal for a registry-committed departure needs a committed transition and lives with
///         the replacement suite (`TransitionReplacement.t.sol`).
contract SetUpgradeDiamondCutTest is ChainTypeManagerTest {
    function setUp() public {
        deploy();
        _mockMigrationPausedFromBridgehub();
    }

    function test_SettingUpgradeDiamondCutForALegacyCommittedVersion() public {
        Diamond.DiamondCutData memory committedCut = getDiamondCutData(makeAddr("committedDiamondInit"));
        address newRelease = _releaseAt(1);
        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(committedCut, 0, 999999999999, newRelease);
        assertEq(chainContractAddress.upgradeCutHash(0), keccak256(abi.encode(committedCut)));

        Diamond.DiamondCutData memory repairedCut = getDiamondCutData(makeAddr("repairedDiamondInit"));
        bytes32 repairedCutHash = keccak256(abi.encode(repairedCut));
        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewUpgradeCutHash(0, repairedCutHash);
        vm.prank(governor);
        chainContractAddress.setUpgradeDiamondCut(repairedCut, 0);

        assertEq(chainContractAddress.upgradeCutHash(0), repairedCutHash, "the repaired cut is committed");
        assertEq(chainContractAddress.upgradeCutDataBlock(0), block.number, "and located for legacy tooling");
        assertEq(chainContractAddress.protocolVersion(), 1, "the version does not move");
        assertEq(chainContractAddress.currentRelease(), newRelease, "nor does the release");
    }

    /// @dev Nothing was committed for the version, so there is no legacy cut to repair.
    function test_RevertWhen_NothingWasCommittedForTheVersion() public {
        Diamond.DiamondCutData memory cut = getDiamondCutData(makeAddr("randomDiamondInit"));

        vm.expectRevert(abi.encodeWithSelector(NoCommittedUpgradeCutForVersion.selector, 0));
        vm.prank(governor);
        chainContractAddress.setUpgradeDiamondCut(cut, 0);
        assertEq(chainContractAddress.upgradeCutHash(0), bytes32(0));
    }

    function test_RevertWhen_NotTheOwner() public {
        Diamond.DiamondCutData memory cut = getDiamondCutData(makeAddr("randomDiamondInit"));
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        chainContractAddress.setUpgradeDiamondCut(cut, 0);
    }
}
