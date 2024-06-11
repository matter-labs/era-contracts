// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StateTransitionManagerTest} from "./_StateTransitionManager_Shared.t.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

contract ProtocolVersion is StateTransitionManagerTest {
    // setNewVersionUpgrade
    function test_SuccessfulSetNewVersionUpgrade() public {
        createNewChain(getDiamondCutData(diamondInit));

        uint256 oldProtocolVersion = chainContractAddress.protocolVersion();
        uint256 oldProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(oldProtocolVersion);

        assertEq(oldProtocolVersion, 0);
        assertEq(oldProtocolVersionDeadline, type(uint256).max);

        chainContractAddress.setNewVersionUpgrade(getDiamondCutData(diamondInit), oldProtocolVersion, 1000, 1);

        uint256 newProtocolVersion = chainContractAddress.protocolVersion();
        uint256 newProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(newProtocolVersion);

        oldProtocolVersionDeadline = chainContractAddress.protocolVersionDeadline(oldProtocolVersion);

        assertEq(newProtocolVersion, 1);
        assertEq(newProtocolVersionDeadline, type(uint256).max);
        assertEq(oldProtocolVersionDeadline, 1000);
    }

    // protocolVersionIsActive
    function test_SuccessfulProtocolVersionIsActive() public {
        createNewChain(getDiamondCutData(diamondInit));

        chainContractAddress.setNewVersionUpgrade(getDiamondCutData(diamondInit), 0, 0, 1);

        assertEq(chainContractAddress.protocolVersionIsActive(0), false);
        assertEq(chainContractAddress.protocolVersionIsActive(1), true);
    }

    // setProtocolVersionDeadline
    function test_SuccessfulSetProtocolVersionDeadline() public {
        createNewChain(getDiamondCutData(diamondInit));

        uint256 deadlineBefore = chainContractAddress.protocolVersionDeadline(0);
        assertEq(deadlineBefore, type(uint256).max);

        uint256 newDeadline = 1000;
        chainContractAddress.setProtocolVersionDeadline(0, newDeadline);

        uint256 deadline = chainContractAddress.protocolVersionDeadline(0);
        assertEq(deadline, newDeadline);
    }

    // executeUpgrade
    function test_SuccessfulExecuteUpdate() public {
        createNewChain(getDiamondCutData(diamondInit));

        Diamond.FacetCut[] memory customFacetCuts = new Diamond.FacetCut[](1);
        customFacetCuts[0] = Diamond.FacetCut({
            facet: facetCuts[2].facet,
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: facetCuts[2].selectors
        });

        chainContractAddress.executeUpgrade(chainId, getDiamondCutDataWithCustomFacets(address(0), customFacetCuts));
    }

    // upgradeChainFromVersion
    function test_SuccessfulUpgradeChainFromVersion() public {
        createNewChain(getDiamondCutData(diamondInit));

        Diamond.FacetCut[] memory customFacetCuts = new Diamond.FacetCut[](1);
        customFacetCuts[0] = Diamond.FacetCut({
            facet: facetCuts[2].facet,
            action: Diamond.Action.Replace,
            isFreezable: true,
            selectors: facetCuts[2].selectors
        });

        chainContractAddress.setNewVersionUpgrade(
            getDiamondCutDataWithCustomFacets(address(0), customFacetCuts),
            0,
            0,
            1
        );

        vm.expectRevert(bytes("AdminFacet: protocolVersion mismatch in STC after upgrading"));
        chainContractAddress.upgradeChainFromVersion(
            chainId,
            0,
            getDiamondCutDataWithCustomFacets(address(0), customFacetCuts)
        );
    }
}
