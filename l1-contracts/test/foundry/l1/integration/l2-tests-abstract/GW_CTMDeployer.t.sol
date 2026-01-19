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
        address expectedGovernance = makeAddr("aliasedGovernanceAddress");
        bytes32 expectedSalt = keccak256("test-salt");
        uint256 expectedEraChainId = 1;
        uint256 expectedL1ChainId = 1;
        bytes32 expectedBootloaderHash = keccak256("bootloader-hash");
        bytes32 expectedDefaultAccountHash = keccak256("default-account-hash");
        bytes32 expectedEvmEmulatorHash = keccak256("evm-emulator-hash");
        bytes32 expectedGenesisRoot = keccak256("genesis-root");
        bytes32 expectedGenesisBatchCommitment = keccak256("genesis-batch-commitment");

        GatewayCTMDeployerConfig memory deployerConfig = GatewayCTMDeployerConfig({
            aliasedGovernanceAddress: expectedGovernance,
            salt: expectedSalt,
            eraChainId: expectedEraChainId,
            l1ChainId: expectedL1ChainId,
            testnetVerifier: false,
            isZKsyncOS: false,
            adminSelectors: new bytes4[](0),
            executorSelectors: new bytes4[](0),
            mailboxSelectors: new bytes4[](0),
            gettersSelectors: new bytes4[](0),
            bootloaderHash: expectedBootloaderHash,
            defaultAccountHash: expectedDefaultAccountHash,
            evmEmulatorHash: expectedEvmEmulatorHash,
            genesisRoot: expectedGenesisRoot,
            genesisRollupLeafIndex: 1,
            genesisBatchCommitment: expectedGenesisBatchCommitment,
            forceDeploymentsData: bytes(""),
            protocolVersion: 0
        });
        GatewayCTMDeployer deployer = new GatewayCTMDeployer(deployerConfig);

        // Verify the deployer was created at a valid address
        assertTrue(address(deployer) != address(0), "Deployer should be deployed at a valid address");

        // Verify the deployer contract code exists
        assertTrue(address(deployer).code.length > 0, "Deployer should have contract code");
    }
}
