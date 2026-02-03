// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {GW_ASSET_TRACKER, GW_ASSET_TRACKER_ADDR, L2_ASSET_TRACKER, L2_ASSET_TRACKER_ADDR, L2_CHAIN_ASSET_HANDLER, L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_BASE_TOKEN_HOLDER_ADDR, L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {MAX_TOKEN_BALANCE} from "contracts/bridge/asset-tracker/IAssetTrackerBase.sol";
import {L2AssetTracker} from "contracts/bridge/asset-tracker/L2AssetTracker.sol";
import {IL2AssetTracker} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";

import {L2AssetTrackerData} from "./L2AssetTrackerData.sol";

abstract contract L2AssetTrackerTest is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function test_processLogsAndMessages() public {
        finalizeDepositWithChainId(271);
        finalizeDepositWithChainId(260);

        vm.chainId(GATEWAY_CHAIN_ID);

        bytes[] memory input2 = L2AssetTrackerData.getData2();
        for (uint256 i = 0; i < input2.length; i++) {
            this.printProcess(abi.decode(input2[i], (ProcessLogsInput)));
            return;
        }

        ProcessLogsInput[] memory testData = L2AssetTrackerData.getData();

        // Verify test data is not empty
        assertTrue(testData.length > 0, "Test data should not be empty");

        // Add the required previous batch roots for batches 1-4
        // The test is trying to add batch 5, so we need batches 1-4 to exist first
        bytes32 dummyBatchRoot = keccak256("dummy_batch_root");
        for (uint256 i = 1; i <= 4; i++) {
            stdstore
                .target(address(L2_MESSAGE_ROOT_ADDR))
                .sig("chainBatchRoots(uint256,uint256)")
                .with_key(271)
                .with_key(i)
                .checked_write(bytes32(uint256(dummyBatchRoot) + i));
        }

        uint256 successCount = 0;

        for (uint256 i = 0; i < testData.length; i++) {
            // Verify each test data entry has valid chain ID
            assertTrue(testData[i].chainId > 0, "Chain ID should be positive");

            // Set the current batch number to 4 so that batch 5 can be added next
            if (testData[i].batchNumber > 0) {
                stdstore
                    .target(address(L2_MESSAGE_ROOT_ADDR))
                    .sig("currentChainBatchNumber(uint256)")
                    .with_key(testData[i].chainId)
                    .checked_write(testData[i].batchNumber - 1);
            }

            storeChainBalance(
                testData[i].chainId,
                0x444c07697a6b15219c574dcc0ee09b479f6171009a6afd65b93e6f028cfa031b,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0xa6203e30497f83b9f5f056745b6ff94f7e22d88bacea03d4dd4393d66217a86f,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0x8592bf3100a24d737aba8ba9895f6801b9ec30200dc016dd8369f3171cbd1921,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0xb615cd4917043452e354e4797dc23e4d6106663f7a37249d54f5996dd2347710,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0xb1f317b7effffcd4e3cf53784ae442ecc4e835c532aaf0e60a046fa8efb96e85,
                100
            );
            storeChainBalance(
                testData[i].chainId,
                0xb5eab7cc8c9114c3115a034b49b3d87b0b352aa88c2a9d5ff7339cde105aa44c,
                100
            );

            stdstore
                .target(address(L2_CHAIN_ASSET_HANDLER))
                .sig("migrationNumber(uint256)")
                .with_key(271)
                .checked_write(uint256(1));

            bytes32[] memory txHashes = getTxHashes(testData[i]);

            // Loop over l1TxHashes in testData[i] and for each mark balanceChange version number as 1
            // Note: balanceChange is internal, so we calculate storage slot manually
            // balanceChange is at slot 155 in GWAssetTracker
            for (uint256 j = 0; j < txHashes.length; j++) {
                // Calculate storage slot: keccak256(txHash, keccak256(chainId, 155))
                bytes32 innerSlot = keccak256(abi.encode(testData[i].chainId, uint256(155)));
                bytes32 structSlot = keccak256(abi.encode(txHashes[j], innerSlot));
                // Write 1 to the version field (first byte of the struct)
                vm.store(address(GW_ASSET_TRACKER), structSlot, bytes32(uint256(1)));
            }

            vm.prank(L2_BRIDGEHUB.getZKChain(testData[i].chainId));

            (bool success, bytes memory data) = GW_ASSET_TRACKER_ADDR.call(
                abi.encodeCall(GW_ASSET_TRACKER.processLogsAndMessages, testData[i])
            );

            if (!success) {
                assembly {
                    revert(add(data, 0x20), mload(data))
                }
            }

            assertTrue(success, string.concat("processLogsAndMessages should succeed for iteration ", vm.toString(i)));
            successCount++;
            console.log("success", i);
        }

        // Verify all iterations succeeded
        assertEq(successCount, testData.length, "All processLogsAndMessages calls should succeed");
    }

    function getTxHashes(ProcessLogsInput memory input) public returns (bytes32[] memory) {
        bytes32[] memory txHashes = new bytes32[](input.logs.length);
        uint256 length = 0;
        for (uint256 i = 0; i < input.logs.length; i++) {
            if (input.logs[i].sender == L2_BOOTLOADER_ADDRESS) {
                length++;
            }
        }
        uint256 j;
        for (uint256 i = 0; i < input.logs.length; i++) {
            if (input.logs[i].sender == L2_BOOTLOADER_ADDRESS) {
                txHashes[j++] = input.logs[i].key;
            }
        }
        return txHashes;
    }

    function storeChainBalance(uint256 chainId, bytes32 assetId, uint256 balance) public {
        stdstore
            .target(address(GW_ASSET_TRACKER))
            .sig("chainBalance(uint256,bytes32)")
            .with_key(chainId)
            .with_key(assetId)
            .checked_write(balance);
    }

    function printProcess(ProcessLogsInput memory) public {
        /// its just here so that the ProcessLogsInput is printed in console
    }

    function test_migrateTokenBalanceFromNTVV31() public {
        // Test migrating token balance from NTV to AssetTracker for V31 upgrade
        bytes32 assetId = keccak256("test_asset_id");

        // Mock the asset as being native to the current chain
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(assetId)
            .checked_write(block.chainid);

        // Mock token address
        address mockTokenAddress = address(0x1234);
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("tokenAddress(bytes32)")
            .with_key(assetId)
            .checked_write(uint256(uint160(mockTokenAddress)));

        // Set initial chainBalance (pre-V31 tracking)
        uint256 initialChainBalance = 1000;
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("chainBalance(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(assetId)
            .checked_write(initialChainBalance);

        // Mock NTV balance (tokens locked from previous bridge operations)
        uint256 ntvBalance = 300;
        vm.mockCall(
            mockTokenAddress,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(L2_NATIVE_TOKEN_VAULT_ADDR)),
            abi.encode(ntvBalance)
        );

        // Call the migration function
        L2_ASSET_TRACKER.migrateTokenBalanceFromNTVV31(assetId);

        // Verify chainBalance was calculated correctly
        // Expected: MAX_TOKEN_BALANCE - initialChainBalance - ntvBalance
        uint256 expectedBalance = MAX_TOKEN_BALANCE - initialChainBalance - ntvBalance;
        uint256 actualBalance = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, assetId);

        assertEq(actualBalance, expectedBalance, "Chain balance should be correctly migrated");
    }

    function test_handleInitiateBaseTokenBridgingOnL2() public {
        // Test handling base token bridging out from L2
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");
        uint256 amount = 500;

        // Mock base token asset ID
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        // Mock origin chain ID for base token
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(block.chainid);

        // Set initial chain balance
        uint256 initialBalance = 1000;
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("chainBalance(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(baseTokenAssetId)
            .checked_write(initialBalance);

        // Set migration number
        stdstore
            .target(address(L2_CHAIN_ASSET_HANDLER))
            .sig("migrationNumber(uint256)")
            .with_key(block.chainid)
            .checked_write(uint256(1));

        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("assetMigrationNumber(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(baseTokenAssetId)
            .checked_write(uint256(1));

        // Call as L2 Base Token Holder (new caller after upgrade)
        vm.prank(L2_BASE_TOKEN_HOLDER_ADDR);
        L2_ASSET_TRACKER.handleInitiateBaseTokenBridgingOnL2(amount);

        // Verify chain balance decreased
        uint256 finalBalance = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, baseTokenAssetId);
        assertEq(finalBalance, initialBalance - amount, "Chain balance should decrease by bridged amount");
    }

    function test_handleFinalizeBaseTokenBridgingOnL2() public {
        // Test handling base token bridging into L2
        bytes32 baseTokenAssetId = keccak256("base_token_asset_id");
        uint256 amount = 300;
        uint256 l1ChainId = 1;

        // Mock base token asset ID
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("BASE_TOKEN_ASSET_ID()").checked_write(uint256(baseTokenAssetId));

        // Mock L1 chain ID
        stdstore.target(L2_ASSET_TRACKER_ADDR).sig("L1_CHAIN_ID()").checked_write(l1ChainId);

        // Set initial chain balance (should be 0 for incoming tokens)
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("chainBalance(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(baseTokenAssetId)
            .checked_write(uint256(0));

        // Mock origin chain ID for base token (L1)
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(baseTokenAssetId)
            .checked_write(l1ChainId);

        // Mock totalSupply on L2_BASE_TOKEN_SYSTEM_CONTRACT (needed for foreign token total supply calculation)
        vm.mockCall(
            address(L2_BASE_TOKEN_SYSTEM_CONTRACT),
            abi.encodeWithSelector(IERC20.totalSupply.selector),
            abi.encode(1000)
        );

        // Call as L2 Base Token System Contract
        vm.prank(address(L2_BASE_TOKEN_SYSTEM_CONTRACT));
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(amount);

        // Verify chain balance did NOT increase (foreign token, not native)
        uint256 finalBalance = L2AssetTracker(L2_ASSET_TRACKER_ADDR).chainBalance(block.chainid, baseTokenAssetId);
        assertEq(finalBalance, 0, "Chain balance should remain 0 for foreign tokens");
    }

    function test_initiateL1ToGatewayMigrationOnL2() public {
        // Test initiating L1 to Gateway migration on L2
        bytes32 assetId = keccak256("migration_asset_id");
        uint256 originChainId = 1;
        address tokenAddress = address(0x5678);
        address originalToken = address(0x9ABC);
        uint256 totalSupply = 10000;

        // Mock settlement layer chain ID (not L1)
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(bytes4(keccak256("currentSettlementLayerChainId()"))),
            abi.encode(270) // Gateway chain ID
        );

        // Mock token address
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("tokenAddress(bytes32)")
            .with_key(assetId)
            .checked_write(uint256(uint160(tokenAddress)));

        // Mock origin chain ID
        stdstore
            .target(address(L2_NATIVE_TOKEN_VAULT_ADDR))
            .sig("originChainId(bytes32)")
            .with_key(assetId)
            .checked_write(originChainId);

        // Mock origin token (using mockCall since originToken is a function with logic)
        vm.mockCall(
            address(L2_NATIVE_TOKEN_VAULT_ADDR),
            abi.encodeWithSignature("originToken(bytes32)", assetId),
            abi.encode(originalToken)
        );

        // Mock chain migration number
        stdstore
            .target(address(L2_CHAIN_ASSET_HANDLER))
            .sig("migrationNumber(uint256)")
            .with_key(block.chainid)
            .checked_write(uint256(2));

        // Set asset migration number to 0 (not yet migrated)
        stdstore
            .target(L2_ASSET_TRACKER_ADDR)
            .sig("assetMigrationNumber(uint256,bytes32)")
            .with_key(block.chainid)
            .with_key(assetId)
            .checked_write(uint256(0));

        // Mock total supply
        vm.mockCall(tokenAddress, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(totalSupply));

        // Mock sendMessageToL1 to avoid revert
        vm.mockCall(address(L2_BRIDGEHUB), abi.encodeWithSignature("sendMessageToL1(bytes)"), abi.encode(bytes32(0)));

        // Get asset migration number before migration
        uint256 assetMigrationNumBefore = L2AssetTracker(L2_ASSET_TRACKER_ADDR).assetMigrationNumber(
            block.chainid,
            assetId
        );

        // Verify initial state
        assertEq(assetMigrationNumBefore, 0, "Asset migration number should be 0 before migration");

        // Record logs to capture the event
        vm.recordLogs();

        // Call the migration function
        L2_ASSET_TRACKER.initiateL1ToGatewayMigrationOnL2(assetId);

        // Verify the L1ToGatewayMigrationInitiated event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(logs.length > 0, "Should emit L1ToGatewayMigrationInitiated event");

        // Find the L1ToGatewayMigrationInitiated event
        bool foundEvent = false;
        bytes32 eventSignature = IL2AssetTracker.L1ToGatewayMigrationInitiated.selector;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == eventSignature) {
                foundEvent = true;
                // Verify the indexed assetId matches
                assertEq(logs[i].topics[1], assetId, "Event assetId should match");
                break;
            }
        }
        assertTrue(foundEvent, "L1ToGatewayMigrationInitiated event should be emitted");
    }
}
