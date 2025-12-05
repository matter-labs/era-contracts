// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, Test, stdStorage, console} from "forge-std/Test.sol";

import {SharedL2ContractDeployer} from "./_SharedL2ContractDeployer.sol";
import {GW_ASSET_TRACKER, GW_ASSET_TRACKER_ADDR, L2_CHAIN_ASSET_HANDLER, L2_BOOTLOADER_ADDRESS, L2_BRIDGEHUB, L2_MESSAGE_ROOT, L2_MESSAGE_ROOT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";

import {L2AssetTrackerData} from "./L2AssetTrackerData.sol";

import {GatewayCTMDeployerConfig, GatewayCTMDeployer} from "contracts/state-transition/chain-deps/GatewayCTMDeployer.sol";

abstract contract GW_CTMDeployerTest is Test {
    using stdStorage for StdStorage;

    // function setUp() public override {
        // super.setUp();
    // }

    function test_GW_CTMDeployer() public {
        GatewayCTMDeployerConfig memory deployerConfig = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: makeAddr("aliasedGovernanceAddress"),
            salt: keccak256("test-salt"),
            eraChainId: 1,
            l1ChainId: 1,
            testnetVerifier: false,
            isZKsyncOS: false,
            adminSelectors: new bytes4[](0),
            executorSelectors: new bytes4[](0),
            mailboxSelectors: new bytes4[](0),
            gettersSelectors: new bytes4[](0),
            bootloaderHash: keccak256("bootloader-hash"),
            defaultAccountHash: keccak256("default-account-hash"),
            evmEmulatorHash: keccak256("evm-emulator-hash"),
            genesisRoot: keccak256("genesis-root"),
            genesisRollupLeafIndex: 1,
            genesisBatchCommitment: keccak256("genesis-batch-commitment"),
            forceDeploymentsData: bytes(""),
            protocolVersion: 0
        });
        new GatewayCTMDeployer(deployerConfig);
    }
}
