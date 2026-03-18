// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {L2_BOOTLOADER_ADDRESS, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SystemContext} from "contracts/l2-system/zksync-os/SystemContext.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {L2ChainAssetHandler} from "contracts/core/chain-asset-handler/L2ChainAssetHandler.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {NotSystemContext} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

contract SystemContextTest is Test {
    SystemContext systemContext;

    function setUp() public {
        systemContext = new SystemContext();
        // Mock the L2ChainAssetHandler call so unit tests focus on SystemContext logic only,
        // without needing the handler deployed at its canonical address.
        vm.mockCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeWithSelector(IL2ChainAssetHandler.setSettlementLayerChainId.selector),
            ""
        );
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

/// @notice Integration tests that verify SystemContext correctly notifies the real L2ChainAssetHandler
/// when the settlement layer chain ID changes.
contract SystemContextWithChainAssetHandlerTest is Test {
    using stdStorage for StdStorage;

    SystemContext internal systemContextAtAddr;
    IChainAssetHandlerBase internal chainAssetHandlerAtAddr;

    /// @dev A dummy L1 chain ID distinct from block.chainid (default 31337 in Foundry).
    uint256 internal constant L1_CHAIN_ID = 1;

    /// @dev An example gateway chain ID used as an alternate settlement layer.
    uint256 internal constant GATEWAY_CHAIN_ID = 506;

    function setUp() public {
        // Etch the real SystemContext bytecode at its canonical system address so that
        // the onlySystemContext modifier in L2ChainAssetHandler (msg.sender check) passes.
        SystemContext scImpl = new SystemContext();
        vm.etch(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR, address(scImpl).code);
        systemContextAtAddr = SystemContext(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT_ADDR);

        // Etch the real L2ChainAssetHandler bytecode at its canonical address so that
        // the hard-coded address in SystemContext resolves correctly.
        L2ChainAssetHandler cahImpl = new L2ChainAssetHandler();
        vm.etch(L2_CHAIN_ASSET_HANDLER_ADDR, address(cahImpl).code);
        chainAssetHandlerAtAddr = IChainAssetHandlerBase(L2_CHAIN_ASSET_HANDLER_ADDR);

        // Initialise L1_CHAIN_ID in the etched L2ChainAssetHandler so that the
        // "initial L1 settlement" early-return check inside setSettlementLayerChainId works.
        stdstore.target(L2_CHAIN_ASSET_HANDLER_ADDR).sig("L1_CHAIN_ID()").checked_write(L1_CHAIN_ID);
    }

    // ═══════════════════════════════════════════════════════════════
    //  SystemContext → L2ChainAssetHandler call verification
    // ═══════════════════════════════════════════════════════════════

    /// @notice Verifies that L2ChainAssetHandler.setSettlementLayerChainId is called with the
    /// correct *previous* and *new* chain IDs when the settlement layer changes.
    function test_setSettlementLayerChainId_callsL2ChainAssetHandlerWithCorrectParams() public {
        uint256 previousChainId = 0; // initial state
        uint256 newChainId = GATEWAY_CHAIN_ID;

        vm.expectCall(
            L2_CHAIN_ASSET_HANDLER_ADDR,
            abi.encodeCall(IL2ChainAssetHandler.setSettlementLayerChainId, (previousChainId, newChainId))
        );

        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContextAtAddr.setSettlementLayerChainId(newChainId);

        assertEq(
            systemContextAtAddr.currentSettlementLayerChainId(),
            newChainId,
            "Settlement layer chain id should be updated"
        );
    }

    /// @notice Verifies that when the same value is set again the guard check prevents any call
    /// to L2ChainAssetHandler (no logs emitted, no state change).
    function test_setSettlementLayerChainId_noopWhenValueUnchanged() public {
        uint256 chainId = GATEWAY_CHAIN_ID;

        // First call – establishes the value.
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContextAtAddr.setSettlementLayerChainId(chainId);

        uint256 migNumBefore = chainAssetHandlerAtAddr.migrationNumber(block.chainid);

        // Second call with the identical value: should be a no-op.
        vm.recordLogs();
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContextAtAddr.setSettlementLayerChainId(chainId);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "No events should be emitted when value is unchanged");

        assertEq(
            chainAssetHandlerAtAddr.migrationNumber(block.chainid),
            migNumBefore,
            "Migration number must not change when settlement layer is unchanged"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //  L2ChainAssetHandler.setSettlementLayerChainId checks
    // ═══════════════════════════════════════════════════════════════

    /// @notice Verifies L2ChainAssetHandler's early-return: when previous == 0 and current == L1_CHAIN_ID
    /// (the very first batch settling on L1), migrationNumber must NOT be incremented.
    function test_setSettlementLayerChainId_initialL1SettlementSkipsMigration() public {
        uint256 migNumBefore = chainAssetHandlerAtAddr.migrationNumber(block.chainid);

        // Migrate from 0 → L1: L2ChainAssetHandler should hit the early-return.
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContextAtAddr.setSettlementLayerChainId(L1_CHAIN_ID);

        assertEq(
            chainAssetHandlerAtAddr.migrationNumber(block.chainid),
            migNumBefore,
            "Migration number must not change for the initial L1 settlement"
        );
    }

    /// @notice Verifies that migrationNumber increments when the settlement layer actually changes
    /// (e.g. from L1 to Gateway), demonstrating the real L2ChainAssetHandler is invoked.
    function test_setSettlementLayerChainId_migrationNumberIncrements() public {
        // First: settle on L1 (no migration recorded – initial case).
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContextAtAddr.setSettlementLayerChainId(L1_CHAIN_ID);

        uint256 migNumBefore = chainAssetHandlerAtAddr.migrationNumber(block.chainid);

        // Now migrate to Gateway: previous == L1_CHAIN_ID, current == GATEWAY_CHAIN_ID.
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContextAtAddr.setSettlementLayerChainId(GATEWAY_CHAIN_ID);

        assertEq(
            chainAssetHandlerAtAddr.migrationNumber(block.chainid),
            migNumBefore + 1,
            "Migration number should increment when settlement layer changes"
        );
    }

    /// @notice Verifies that calling L2ChainAssetHandler.setSettlementLayerChainId directly
    /// from a non-SystemContext address reverts.
    function test_setSettlementLayerChainId_L2ChainAssetHandler_revertsForNonSystemContext() public {
        address notSystemContext = makeAddr("notSystemContext");
        vm.prank(notSystemContext);
        vm.expectRevert(abi.encodeWithSelector(NotSystemContext.selector, notSystemContext));
        IL2ChainAssetHandler(L2_CHAIN_ASSET_HANDLER_ADDR).setSettlementLayerChainId(0, GATEWAY_CHAIN_ID);
    }
}
