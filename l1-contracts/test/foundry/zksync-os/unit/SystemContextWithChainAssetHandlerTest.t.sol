// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IL2ChainAssetHandler} from "contracts/core/chain-asset-handler/IL2ChainAssetHandler.sol";
import {NotSystemContext} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SystemContextTest} from "./SystemContextTest.t.sol";

/// @notice Integration tests that verify SystemContext correctly notifies the real L2ChainAssetHandler
/// when the settlement layer chain ID changes.
contract SystemContextWithChainAssetHandlerTest is SystemContextTest {
    using stdStorage for StdStorage;

    IChainAssetHandlerBase internal chainAssetHandlerAtAddr;

    /// @dev A dummy L1 chain ID distinct from block.chainid (default 31337 in Foundry).
    uint256 internal constant L1_CHAIN_ID = 1;

    /// @dev An example gateway chain ID used as an alternate settlement layer.
    uint256 internal constant GATEWAY_CHAIN_ID = 506;

    function setUp() public override {
        super.setUp();

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
        systemContext.setSettlementLayerChainId(newChainId);

        assertEq(
            systemContext.currentSettlementLayerChainId(),
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
        systemContext.setSettlementLayerChainId(chainId);

        uint256 migNumBefore = chainAssetHandlerAtAddr.migrationNumber(block.chainid);

        // Second call with the identical value: should be a no-op.
        vm.recordLogs();
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(chainId);

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
        systemContext.setSettlementLayerChainId(L1_CHAIN_ID);

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
        systemContext.setSettlementLayerChainId(L1_CHAIN_ID);

        uint256 migNumBefore = chainAssetHandlerAtAddr.migrationNumber(block.chainid);

        // Now migrate to Gateway: previous == L1_CHAIN_ID, current == GATEWAY_CHAIN_ID.
        vm.prank(L2_BOOTLOADER_ADDRESS);
        systemContext.setSettlementLayerChainId(GATEWAY_CHAIN_ID);

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
