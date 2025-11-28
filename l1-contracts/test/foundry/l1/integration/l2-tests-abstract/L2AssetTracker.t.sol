// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage, console} from "forge-std/Test.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {GW_ASSET_TRACKER, GW_ASSET_TRACKER_ADDR, L2_CHAIN_ASSET_HANDLER, L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB, L2_MESSAGE_ROOT, L2_MESSAGE_ROOT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";

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

        // Initialize v31UpgradeChainBatchNumber for chain 271 with the correct placeholder value
        uint256 placeholderValue = uint256(
            keccak256(abi.encodePacked("V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY"))
        );
        stdstore
            .target(address(L2_MESSAGE_ROOT_ADDR))
            .sig("v31UpgradeChainBatchNumber(uint256)")
            .with_key(271)
            .checked_write(placeholderValue);

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

        for (uint256 i = 0; i < testData.length; i++) {
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
                .checked_write(1);

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

            (bool success, ) = GW_ASSET_TRACKER_ADDR.call(
                abi.encodeCall(GW_ASSET_TRACKER.processLogsAndMessages, testData[i])
            );

            require(success, string.concat("Failed to call GWAssetTracker ", vm.toString(i)));
            console.log("success", i);
        }
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
}
