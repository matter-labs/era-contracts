// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {NoCommittedUpgradeCutForVersion} from "contracts/common/L1ContractErrors.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

contract ProtocolVersion is ChainTypeManagerTest {
    function setUp() public {
        deploy();
    }

    // setNewVersionUpgrade
    function test_SuccessfulSetNewVersionUpgrade() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        uint256 oldProtocolVersion = chainContractAddress.protocolVersion();
        uint256 oldProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(oldProtocolVersion);

        assertEq(oldProtocolVersion, 0);
        assertEq(oldProtocolVersionDeadline, type(uint256).max);

        uint256 newProtocolVersionSemVer = SemVer.packSemVer(0, 1, 0);

        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        vm.startPrank(governor);
        chainContractAddress.setNewVersionUpgrade(
            getDiamondCutData(diamondInit),
            oldProtocolVersion,
            1000,
            newProtocolVersionSemVer
        );
        vm.stopPrank();

        uint256 newProtocolVersion = chainContractAddress.protocolVersion();
        uint256 newProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(newProtocolVersion);

        oldProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(oldProtocolVersion);

        (uint32 major, uint32 minor, uint32 patch) = chainContractAddress.getSemverProtocolVersion();

        assertEq(major, 0);
        assertEq(minor, 1);
        assertEq(patch, 0);
        assertEq(newProtocolVersion, newProtocolVersionSemVer);
        assertEq(newProtocolVersionDeadline, type(uint256).max);
        assertEq(oldProtocolVersionDeadline, 1000);
    }

    // protocolVersionIsActive
    function test_SuccessfulProtocolVersionIsActive() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        assertEq(chainContractAddress.protocolVersionIsActive(0), true);

        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        vm.startPrank(governor);
        chainContractAddress.setNewVersionUpgrade(getDiamondCutData(diamondInit), 0, 0, 1);
        vm.stopPrank();

        assertEq(chainContractAddress.protocolVersionIsActive(1), true);
    }

    // protocolVersionDeadline resolution: the current version is open-ended; a version that was
    // never current, has no committed transition and no stored write resolves to 0 (inactive).
    function test_ProtocolVersionDeadlineResolution() public {
        createNewChain(getDiamondCutData(diamondInit));

        assertEq(chainContractAddress.protocolVersionDeadline(0), type(uint256).max, "current version is open-ended");

        uint256 unknownVersion = SemVer.packSemVer(0, 99, 0);
        assertEq(chainContractAddress.protocolVersionDeadline(unknownVersion), 0, "unknown version has no deadline");
        assertEq(chainContractAddress.protocolVersionIsActive(unknownVersion), false, "unknown version inactive");
    }

    // setProtocolVersionDeadline: the deadline is operational state that keeps moving after the
    // commit, so the owner can override the value a departed version's edge was committed with.
    function test_SuccessfulSetProtocolVersionDeadline() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        vm.prank(governor);
        chainContractAddress.setNewVersionUpgrade(getDiamondCutData(diamondInit), 0, 1000, SemVer.packSemVer(0, 1, 0));
        assertEq(chainContractAddress.protocolVersionDeadline(0), 1000, "committed deadline");

        vm.expectEmit(true, false, false, true);
        emit IChainTypeManager.UpdateProtocolVersionDeadline(0, 2000);
        vm.prank(governor);
        chainContractAddress.setProtocolVersionDeadline(0, 2000);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 2000, "overridden deadline");

        // A past override retires the version.
        vm.warp(3000);
        assertEq(chainContractAddress.protocolVersionIsActive(0), false, "expired after override");
    }

    function test_RevertWhen_SetProtocolVersionDeadlineByNonOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        chainContractAddress.setProtocolVersionDeadline(0, 2000);
    }

    // executeUpgrade
    function test_SuccessfulExecuteUpdate() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        Diamond.FacetCut[] memory customFacetCuts = new Diamond.FacetCut[](1);
        customFacetCuts[0] = Diamond.FacetCut({
            facet: facetCuts[2].facet,
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: facetCuts[2].selectors
        });

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.executeUpgrade(chainId, getDiamondCutDataWithCustomFacets(address(0), customFacetCuts));
    }

    // upgradeChainFromVersion
    function test_RevertWhen_UpgradeChainFromVersionWithoutCommittedTransition() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        Diamond.FacetCut[] memory customFacetCuts = new Diamond.FacetCut[](1);
        customFacetCuts[0] = Diamond.FacetCut({
            facet: facetCuts[2].facet,
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: facetCuts[2].selectors
        });

        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        vm.startPrank(governor);
        chainContractAddress.setNewVersionUpgrade(
            getDiamondCutDataWithCustomFacets(address(0), customFacetCuts),
            0,
            0,
            1
        );

        // The edge above was committed via the legacy cut-taking setter, which registers no
        // transition — and a v32 chain derives its cut from the committed transition, so the
        // read fails before the chain's own version check would.
        vm.expectRevert(abi.encodeWithSelector(NoCommittedUpgradeCutForVersion.selector, 0));
        chainContractAddress.upgradeChainFromVersion(chainId, 0);
    }
}
