// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProtocolIdNotGreater} from "contracts/common/L1ContractErrors.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

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

    // setProtocolVersionDeadline
    function test_SuccessfulSetProtocolVersionDeadline() public {
        address chainAddress = createNewChain(getDiamondCutData(diamondInit));

        uint256 deadlineBefore = chainContractAddress.protocolVersionDeadline(0);
        assertEq(deadlineBefore, type(uint256).max);

        uint256 newDeadline = 1000;

        _mockGetZKChainFromBridgehub(chainAddress);

        vm.prank(governor);
        chainContractAddress.setProtocolVersionDeadline(0, newDeadline);

        uint256 deadline = chainContractAddress.protocolVersionDeadline(0);
        assertEq(deadline, newDeadline);
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

        vm.prank(governor); // In the ChainTypeManagerTest contract, governor is set as the owner of chainContractAddress
        chainContractAddress.executeUpgrade(chainId, getDiamondCutDataWithCustomFacets(address(0), customFacetCuts));
    }

    // upgradeChainFromVersion
    function test_SuccessfulUpgradeChainFromVersion() public {
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

        vm.expectRevert(ProtocolIdNotGreater.selector);
        chainContractAddress.upgradeChainFromVersion(
            chainId,
            0,
            getDiamondCutDataWithCustomFacets(address(0), customFacetCuts)
        );
    }
}
