// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {
    Unauthorized,
    OnlyNormalMode,
    BaseTokenPreV31TotalSupplyAlreadySet
} from "contracts/common/L1ContractErrors.sol";
import {NotL1, NotZKsyncOS} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";

contract SetZkosPreV31TotalSupplyTest is AdminTest {
    function setUp() public override {
        super.setUp();
        // Enable zksyncOS for the chain
        utilsFacet.util_setZksyncOS(true);
        // DiamondInit sets baseTokenHasTotalSupply = true for all new chains;
        // reset it so we can test the setter flow for legacy ZKOS chains.
        utilsFacet.util_setBaseTokenHasTotalSupply(false);
    }

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.setZKsyncOSPreV31TotalSupply(100 ether);
    }

    function test_revertWhen_notL1() public {
        uint256 fakeChainId = 1337;
        vm.chainId(fakeChainId);
        address admin = utilsFacet.util_getAdmin();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotL1.selector, fakeChainId));
        adminFacet.setZKsyncOSPreV31TotalSupply(100 ether);
    }

    function test_revertWhen_notZksyncOS() public {
        // Disable zksyncOS
        utilsFacet.util_setZksyncOS(false);
        address admin = utilsFacet.util_getAdmin();

        vm.prank(admin);
        vm.expectRevert(NotZKsyncOS.selector);
        adminFacet.setZKsyncOSPreV31TotalSupply(100 ether);
    }

    function test_revertWhen_totalSupplyAlreadySet() public {
        address admin = utilsFacet.util_getAdmin();
        utilsFacet.util_setBaseTokenHasTotalSupply(true);

        vm.prank(admin);
        vm.expectRevert(BaseTokenPreV31TotalSupplyAlreadySet.selector);
        adminFacet.setZKsyncOSPreV31TotalSupply(100 ether);
    }

    function test_revertWhen_priorityModeActive() public {
        address admin = utilsFacet.util_getAdmin();
        utilsFacet.util_setPriorityModeActivated(true);

        vm.prank(admin);
        vm.expectRevert(OnlyNormalMode.selector);
        adminFacet.setZKsyncOSPreV31TotalSupply(100 ether);
    }

    function test_successfulCall() public {
        address admin = utilsFacet.util_getAdmin();
        uint256 totalSupply = 42 ether;

        // Mock the requestL2ServiceTransaction call on the same diamond (Mailbox facet)
        bytes32 expectedCanonicalTxHash = bytes32(uint256(0xabcdef));
        vm.mockCall(
            address(adminFacet),
            abi.encodeWithSelector(IMailboxImpl.requestL2ServiceTransaction.selector),
            abi.encode(expectedCanonicalTxHash)
        );

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit IAdmin.ZKsyncOSPreV31TotalSupplySet(totalSupply);
        bytes32 canonicalTxHash = adminFacet.setZKsyncOSPreV31TotalSupply(totalSupply);

        assertEq(canonicalTxHash, expectedCanonicalTxHash);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
