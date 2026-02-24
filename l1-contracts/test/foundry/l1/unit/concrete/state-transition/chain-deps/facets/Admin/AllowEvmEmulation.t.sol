// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotL1} from "contracts/state-transition/L1StateTransitionErrors.sol";

import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailboxImpl.sol";

contract AllowEvmEmulationTest is AdminTest {
    event EnableEvmEmulator();

    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));
        adminFacet.allowEvmEmulation();
    }

    function test_revertWhen_notL1() public {
        uint256 fakeChainId = 1337;
        vm.chainId(fakeChainId);
        address admin = utilsFacet.util_getAdmin();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotL1.selector, fakeChainId));
        adminFacet.allowEvmEmulation();
    }

    function test_successfulCall() public {
        address admin = utilsFacet.util_getAdmin();

        // Mock the requestL2ServiceTransaction call on the same diamond (Mailbox facet)
        bytes32 expectedCanonicalTxHash = bytes32(uint256(0xabcdef));
        vm.mockCall(
            address(adminFacet),
            abi.encodeWithSelector(IMailboxImpl.requestL2ServiceTransaction.selector),
            abi.encode(expectedCanonicalTxHash)
        );

        vm.startPrank(admin);
        vm.expectEmit(false, false, false, false);
        emit EnableEvmEmulator();
        bytes32 canonicalTxHash = adminFacet.allowEvmEmulation();

        assertEq(canonicalTxHash, expectedCanonicalTxHash);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
