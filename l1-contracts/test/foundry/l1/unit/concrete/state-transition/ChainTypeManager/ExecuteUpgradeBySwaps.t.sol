// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "./_ChainTypeManager_Shared.t.sol";
import {DiamondCutBuilder} from "contracts/state-transition/libraries/DiamondCutBuilder.sol";
import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";

/// @dev A self-describing facet with selectors disjoint from the fixture's facet set.
contract PingFacet is ISelfDescribingFacet {
    function ping() external pure returns (uint256) {
        return 42;
    }

    function selectors() public pure virtual returns (bytes4[] memory result) {
        result = new bytes4[](1);
        result[0] = PingFacet.ping.selector;
    }
}

/// @notice Tests the CTM passthrough of swap-based upgrades: CTM owner -> chain AdminFacet
///         `executeUpgradeBySwaps` -> the diamond composes its own cut.
contract CTMExecuteUpgradeBySwapsTest is ChainTypeManagerTest {
    address internal chainAddress;
    PingFacet internal pingFacet;

    function setUp() public {
        deploy();
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        pingFacet = new PingFacet();
    }

    function _swaps() internal view returns (DiamondCutBuilder.FacetSwap[] memory swaps) {
        swaps = new DiamondCutBuilder.FacetSwap[](1);
        swaps[0] = DiamondCutBuilder.FacetSwap({
            oldFacet: address(0),
            newFacet: address(pingFacet),
            isFreezable: false
        });
    }

    function test_revertWhen_calledByNonOwner() public {
        DiamondCutBuilder.FacetSwap[] memory swaps = _swaps();

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        chainContractAddress.executeUpgradeBySwaps(chainId, swaps, address(0), hex"");
    }

    function test_successfulExecuteUpgradeBySwaps_throughCTM() public {
        vm.prank(governor);
        chainContractAddress.executeUpgradeBySwaps(chainId, _swaps(), address(0), hex"");

        // The diamond composed and applied the cut: the new selector dispatches on the chain.
        assertEq(PingFacet(chainAddress).ping(), 42);
    }

    function test_successfulRemovalBySwaps_throughCTM() public {
        vm.startPrank(governor);
        chainContractAddress.executeUpgradeBySwaps(chainId, _swaps(), address(0), hex"");
        assertEq(PingFacet(chainAddress).ping(), 42);

        // Swap the facet out again (pure removal): the selector stops dispatching.
        DiamondCutBuilder.FacetSwap[] memory removal = new DiamondCutBuilder.FacetSwap[](1);
        removal[0] = DiamondCutBuilder.FacetSwap({
            oldFacet: address(pingFacet),
            newFacet: address(0),
            isFreezable: false
        });
        chainContractAddress.executeUpgradeBySwaps(chainId, removal, address(0), hex"");
        vm.stopPrank();

        vm.expectRevert();
        PingFacet(chainAddress).ping();
    }
}
