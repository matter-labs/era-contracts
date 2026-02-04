// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import "contracts/l2-system/zksync-os/SystemContext.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/ZKOSContractErrors.sol";

contract SystemContextTest is Test {
    SystemContext systemContext;

    function setUp() public {
        systemContext = new SystemContext();
    }

    function test_setSettlementLayerChainId_works_andEmitsEvent() public {
        uint256 newChainId = 123456;

        // Prank as bootloader
        vm.prank(L2_BOOTLOADER_ADDRESS);

        // Expect the event
        vm.expectEmit(true, false, false, false);
        emit SystemContext.SettlementLayerChainIdUpdated(newChainId);

        systemContext.setSettlementLayerChainId(newChainId);

        // Verify the state was updated
        assertEq(
            systemContext.currentSettlementLayerChainId(),
            newChainId,
            "Settlement layer chain id should be updated"
        );
    }

    function test_setSettlementLayerChainId_revertsWhenNotCalledByBootloader() public {
        uint256 newChainId = 123456;
        address unauthorizedCaller = address(0x1234);

        // Prank as unauthorized caller
        vm.prank(unauthorizedCaller);

        // Expect revert with Unauthorized error
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, unauthorizedCaller));

        systemContext.setSettlementLayerChainId(newChainId);
    }

    function test_setSettlementLayerChainId_doesNotEmitEventWhenValueUnchanged() public {
        uint256 chainId = 123456;

        // Set initial value
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(chainId);

        // Try to set the same value again
        vm.prank(L2_BOOTLOADER_ADDRESS);

        // We should NOT see an event emission
        vm.recordLogs();
        systemContext.setSettlementLayerChainId(chainId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "No event should be emitted when value is unchanged");

        // Verify the state remains the same
        assertEq(
            systemContext.currentSettlementLayerChainId(),
            chainId,
            "Settlement layer chain id should remain unchanged"
        );
    }

    function test_setSettlementLayerChainId_canUpdateMultipleTimes() public {
        uint256 firstChainId = 111;
        uint256 secondChainId = 222;
        uint256 thirdChainId = 333;

        // First update
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(firstChainId);
        assertEq(systemContext.currentSettlementLayerChainId(), firstChainId);

        // Second update
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(secondChainId);
        assertEq(systemContext.currentSettlementLayerChainId(), secondChainId);

        // Third update
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(thirdChainId);
        assertEq(systemContext.currentSettlementLayerChainId(), thirdChainId);
    }

    function testFuzz_setSettlementLayerChainId_worksWithAnyChainId(uint256 chainId) public {
        // Prank as bootloader
        vm.prank(L2_BOOTLOADER_ADDRESS);

        systemContext.setSettlementLayerChainId(chainId);

        // Verify the state was updated
        assertEq(
            systemContext.currentSettlementLayerChainId(),
            chainId,
            "Settlement layer chain id should be set to any value"
        );
    }

    function testFuzz_setSettlementLayerChainId_revertsForAnyUnauthorizedCaller(address caller) public {
        vm.assume(caller != L2_BOOTLOADER_ADDRESS);

        uint256 newChainId = 123456;

        // Prank as unauthorized caller
        vm.prank(caller);

        // Expect revert with Unauthorized error
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, caller));

        systemContext.setSettlementLayerChainId(newChainId);
    }

    function test_initialState_isZero() public view {
        assertEq(systemContext.currentSettlementLayerChainId(), 0, "Initial settlement layer chain id should be 0");
    }
}
