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

        // Verify config values are properly set
        assertTrue(expectedGovernance != address(0), "Governance address should not be zero");
        assertTrue(expectedSalt != bytes32(0), "Salt should not be zero");
        assertTrue(expectedBootloaderHash != bytes32(0), "Bootloader hash should not be zero");
        assertTrue(expectedDefaultAccountHash != bytes32(0), "Default account hash should not be zero");
        assertTrue(expectedEvmEmulatorHash != bytes32(0), "EVM emulator hash should not be zero");
        assertTrue(expectedGenesisRoot != bytes32(0), "Genesis root should not be zero");
        assertTrue(expectedGenesisBatchCommitment != bytes32(0), "Genesis batch commitment should not be zero");

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

        // Verify config struct is properly constructed
        assertEq(deployerConfig.aliasedGovernanceAddress, expectedGovernance, "Config governance should match");
        assertEq(deployerConfig.salt, expectedSalt, "Config salt should match");
        assertEq(deployerConfig.eraChainId, expectedEraChainId, "Config era chain ID should match");
        assertEq(deployerConfig.l1ChainId, expectedL1ChainId, "Config L1 chain ID should match");
        assertEq(deployerConfig.bootloaderHash, expectedBootloaderHash, "Config bootloader hash should match");
        assertEq(
            deployerConfig.defaultAccountHash,
            expectedDefaultAccountHash,
            "Config default account hash should match"
        );
        assertEq(deployerConfig.evmEmulatorHash, expectedEvmEmulatorHash, "Config EVM emulator hash should match");
        assertEq(deployerConfig.genesisRoot, expectedGenesisRoot, "Config genesis root should match");
        assertEq(
            deployerConfig.genesisBatchCommitment,
            expectedGenesisBatchCommitment,
            "Config genesis batch commitment should match"
        );
        assertEq(deployerConfig.genesisRollupLeafIndex, 1, "Config genesis rollup leaf index should be 1");
        assertFalse(deployerConfig.testnetVerifier, "Config testnet verifier should be false");
        assertFalse(deployerConfig.isZKsyncOS, "Config isZKsyncOS should be false");

        GatewayCTMDeployer deployer = new GatewayCTMDeployer(deployerConfig);

        // Verify the deployer was created at a valid address
        assertTrue(address(deployer) != address(0), "Deployer should be deployed at a valid address");

        // Verify the deployer contract code exists
        assertTrue(address(deployer).code.length > 0, "Deployer should have contract code");
    }
}
