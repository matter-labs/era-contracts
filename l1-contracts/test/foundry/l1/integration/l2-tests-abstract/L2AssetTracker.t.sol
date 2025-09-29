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
            memory data = hex"000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001a0000000000000000000000000000000000000000000000000000000000000010f0000000000000000000000000000000000000000000000000000000000000007cc02c444ed97a398f98ce0846b2caeb14e9645874c530fc4443be56e97ac8ebee4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf7594400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008008000000000000000000000000000000000000000000000000000000000001000ddfdf66b94c8f7281bac1dacc6204e33587e468aa0c680028c352df613ce9a26700000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010439efa3f00100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000026e45cb3eb3303a363310dba9552e16500027f51000000000000000000000000000000000000000000000000000000000000010feaf44f2baeaf1396b40964237242564e6742f685bdef518ddbcd34039ae3d29f00000000000000000000000000000000000000000000000000000000000000090000000000000000000000000000000000000000000000000000000000000064000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000";
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

        // Set the current batch number to 4 so that batch 5 can be added next
        stdstore
            .target(address(L2_MESSAGE_ROOT_ADDR))
            .sig("currentChainBatchNumber(uint256)")
            .with_key(271)
            .checked_write(4);

        vm.prank(L2_BRIDGEHUB.getZKChain(271));

        // TODO fix data

        // (bool success, ) = GW_ASSET_TRACKER_ADDR.call(bytes.concat(hex"e7ca8589", data));

        // require(success, "Failed to call GWAssetTracker");
    }
}
