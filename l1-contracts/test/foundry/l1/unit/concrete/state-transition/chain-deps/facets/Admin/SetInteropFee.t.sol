// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";

import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {NotL1} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

contract SetInteropFeeTest is AdminTest {
    function test_revertWhen_calledByNonAdmin() public {
        address nonAdmin = makeAddr("nonAdmin");
        uint256 fee = 0.01 ether;

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, nonAdmin));

        adminFacet.setInteropFee(fee);
    }

    function test_revertWhen_calledOnNonL1() public {
        address admin = utilsFacet.util_getAdmin();
        uint256 fee = 0.01 ether;

        // Change chain ID to simulate non-L1 environment
        uint256 originalChainId = block.chainid;
        uint256 newChainId = originalChainId + 1;
        vm.chainId(newChainId);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(NotL1.selector, newChainId));

        adminFacet.setInteropFee(fee);

        // Restore chain ID
        vm.chainId(originalChainId);
    }

    function test_successfulSetInteropFee() public {
        address admin = utilsFacet.util_getAdmin();
        uint256 fee = 0.01 ether;

        // Mock the requestL2ServiceTransaction call
        bytes memory expectedCalldata = abi.encodeCall(IInteropCenter.setInteropFee, (fee));
        bytes32 expectedTxHash = keccak256("mockTxHash");

        // The function calls IMailbox(address(this)).requestL2ServiceTransaction
        // We need to mock that call on the diamond proxy itself
        vm.mockCall(
            address(adminFacet),
            abi.encodeWithSignature(
                "requestL2ServiceTransaction(address,bytes)",
                L2_INTEROP_CENTER_ADDR,
                expectedCalldata
            ),
            abi.encode(expectedTxHash)
        );

        vm.prank(admin);
        bytes32 canonicalTxHash = adminFacet.setInteropFee(fee);

        assertEq(canonicalTxHash, expectedTxHash);
    }

    function test_setInteropFee_encodesCorrectCalldata() public {
        address admin = utilsFacet.util_getAdmin();
        uint256 fee = 0.05 ether;

        // Verify the expected calldata encoding
        bytes memory expectedCalldata = abi.encodeCall(IInteropCenter.setInteropFee, (fee));

        // Expected: function selector (4 bytes) + uint256 fee (32 bytes)
        assertEq(expectedCalldata.length, 36);

        // Verify selector
        bytes4 expectedSelector = IInteropCenter.setInteropFee.selector;
        bytes4 actualSelector;
        assembly {
            actualSelector := mload(add(expectedCalldata, 32))
        }
        assertEq(actualSelector, expectedSelector);

        // Mock the call
        vm.mockCall(
            address(adminFacet),
            abi.encodeWithSignature(
                "requestL2ServiceTransaction(address,bytes)",
                L2_INTEROP_CENTER_ADDR,
                expectedCalldata
            ),
            abi.encode(bytes32(0))
        );

        vm.prank(admin);
        adminFacet.setInteropFee(fee);
    }

    function test_setInteropFee_zeroFee() public {
        address admin = utilsFacet.util_getAdmin();
        uint256 fee = 0;

        bytes memory expectedCalldata = abi.encodeCall(IInteropCenter.setInteropFee, (fee));

        vm.mockCall(
            address(adminFacet),
            abi.encodeWithSignature(
                "requestL2ServiceTransaction(address,bytes)",
                L2_INTEROP_CENTER_ADDR,
                expectedCalldata
            ),
            abi.encode(bytes32(0))
        );

        vm.prank(admin);
        bytes32 canonicalTxHash = adminFacet.setInteropFee(fee);

        // Should not revert - zero fee is valid (disables fees)
        assertEq(canonicalTxHash, bytes32(0));
    }

    function test_setInteropFee_largeFee() public {
        address admin = utilsFacet.util_getAdmin();
        uint256 fee = type(uint256).max;

        bytes memory expectedCalldata = abi.encodeCall(IInteropCenter.setInteropFee, (fee));

        vm.mockCall(
            address(adminFacet),
            abi.encodeWithSignature(
                "requestL2ServiceTransaction(address,bytes)",
                L2_INTEROP_CENTER_ADDR,
                expectedCalldata
            ),
            abi.encode(bytes32(uint256(1)))
        );

        vm.prank(admin);
        bytes32 canonicalTxHash = adminFacet.setInteropFee(fee);

        // Should not revert
        assertEq(canonicalTxHash, bytes32(uint256(1)));
    }
}
