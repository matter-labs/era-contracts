// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {GW_ASSET_TRACKER_ADDR, GW_ASSET_TRACKER, L2_ASSET_ROUTER_ADDR, L2_ASSET_TRACKER, L2_ASSET_TRACKER_ADDR, L2_BRIDGEHUB, L2_BRIDGEHUB_ADDR, L2_MESSAGE_ROOT, L2_MESSAGE_ROOT_ADDR, L2_NATIVE_TOKEN_VAULT_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BASE_TOKEN_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

abstract contract L2AssetTrackerTest is Test, SharedL2ContractDeployer {
    using stdStorage for StdStorage;

    function test_processLogsAndMessages() public {
        finalizeDepositWithChainId(271);

        vm.chainId(GATEWAY_CHAIN_ID);

        bytes
            memory data = hex"000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000260000000000000000000000000000000000000000000000000000000000000010f00000000000000000000000000000000000000000000000000000000000000058dc46fce58c8c5d591a65a5fb49d07b550c89f587fa8cdb2ed1ca5b93ea005262b33d3f358a78acae95eeffe9ca9cc7275db856392d415a8b4014e8a052d2b9e000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080014ff67f088fab2d6fa3cc1ccf7f175312e9cbd59f879f4cb84c2798bc70a6b62600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000008001157970c7e20d7126486cca9ccbcac08a254fc66ab477ad06e125d72fde1f3ae300000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000";
        // ProcessLogsInput memory input = abi.decode(data,(ProcessLogsInput));
        // Note: get this from real local txs

        // Initialize v30UpgradeChainBatchNumber for chain 271 with the correct placeholder value
        uint256 placeholderValue = uint256(
            keccak256(abi.encodePacked("V30_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_GATEWAY"))
        );
        stdstore
            .target(address(L2_MESSAGE_ROOT_ADDR))
            .sig("v30UpgradeChainBatchNumber(uint256)")
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

        vm.prank(L2_BRIDGEHUB.getZKChain(271));
        (bool success, ) = GW_ASSET_TRACKER_ADDR.call(bytes.concat(hex"e7ca8589", data));

        require(success, "Failed to call L2AssetTracker");
    }
}
