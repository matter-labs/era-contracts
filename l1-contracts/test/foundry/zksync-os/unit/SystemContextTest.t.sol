// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SystemContext} from "contracts/l2-system/zksync-os/SystemContext.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";

contract SystemContextTest is Test {
    SystemContext internal systemContext;

    function setUp() public virtual {
        // Etch the real L2ChainAssetHandler bytecode at its canonical address so that
        // SystemContext's external call does not revert with "call to non-contract address".
        L2ChainAssetHandler cahImpl = new L2ChainAssetHandler();
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(cahImpl).code);

        // Etch the real SystemContext bytecode at its canonical system address so that
        // the onlySystemContext modifier in L2ChainAssetHandler (msg.sender check) passes.
        SystemContext scImpl = new SystemContext();
        vm.etch(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, address(scImpl).code);
        systemContext = SystemContext(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);
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
