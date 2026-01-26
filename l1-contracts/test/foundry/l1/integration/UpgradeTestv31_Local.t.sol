// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {EcosystemUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {CoreUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {Test} from "forge-std/Test.sol";
import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default_upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultCoreUpgrade} from "../../../../deploy-scripts/upgrade/default_upgrade/DefaultCoreUpgrade.s.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1} from "contracts/core/message-root/IMessageRoot.sol";

/// @notice Test-only CTM upgrade that mocks large bytecode reads to avoid MemoryOOG
contract CTMUpgrade_v31_Test is CTMUpgrade_v31 {
    /// @notice Override to return dummy bytecode hashes instead of reading huge JSON files
    function getL2BytecodeHash(string memory /* contractName */) public view override returns (bytes32) {
        // Return a valid dummy bytecode hash (must have version byte 0x01 and odd length marker)
        return bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001));
    }

    /// @notice Override to skip bytecode publishing which reads large JSON files
    function publishBytecodes() public override {
        console.log("Test mode: Skipping bytecode publishing to avoid MemoryOOG");

        // Initialize factoryDepsHashes with dummy values
        // The upgrade process expects at least 3 hashes: bootloader, defaultAA, evmEmulator
        factoryDepsHashes = new uint256[](45); // Same size as real deployment

        // Use the configured chain creation params hashes
        factoryDepsHashes[0] = uint256(config.contracts.chainCreationParams.bootloaderHash);
        factoryDepsHashes[1] = uint256(config.contracts.chainCreationParams.defaultAAHash);
        factoryDepsHashes[2] = uint256(config.contracts.chainCreationParams.evmEmulatorHash);

        // Fill rest with dummy valid bytecode hashes and mark them as in factory deps
        bytes32 dummyHash = bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001));
        for (uint256 i = 3; i < 45; i++) {
            factoryDepsHashes[i] = uint256(dummyHash);
        }

        // Mark all hashes as being in factory deps to pass validation
        isHashInFactoryDeps[config.contracts.chainCreationParams.bootloaderHash] = true;
        isHashInFactoryDeps[config.contracts.chainCreationParams.defaultAAHash] = true;
        isHashInFactoryDeps[config.contracts.chainCreationParams.evmEmulatorHash] = true;
        isHashInFactoryDeps[dummyHash] = true;

        // Set the flag to indicate bytecodes are "published" for test purposes
        upgradeConfig.factoryDepsPublished = true;
    }

    /// @notice Override to skip validation of bytecode hashes in factory deps
    function isHashInFactoryDepsCheck(bytes32 _hash) internal view override returns (bool) {
        // In test mode, always return true to skip validation
        return true;
    }
}

/// @notice Test-only Core upgrade that skips problematic governance calls
contract CoreUpgrade_v31_Test is CoreUpgrade_v31 {
    /// @notice Override to skip setAssetTracker call (requires NTV ownership in test)
    function prepareVersionSpecificStage1GovernanceCallsL1() public override returns (Call[] memory calls) {
        console.log("Test mode: Skipping setAssetTracker governance call (requires proper NTV ownership)");
        // Return empty array - setAssetTracker will be called via stage3 with proper owner
        calls = new Call[](0);
    }
}

/// @notice Test-only ecosystem upgrade that uses the mocked CTM and Core upgrades
contract EcosystemUpgrade_v31_Test is EcosystemUpgrade_v31 {
    using stdToml for string;

    /// @notice Override to return mocked CTM upgrade
    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgrade_v31_Test();
    }

    /// @notice Override to return mocked Core upgrade
    function createCoreUpgrade() internal override returns (DefaultCoreUpgrade) {
        return new CoreUpgrade_v31_Test();
    }

    /// @notice Override to set protocol version from config for local testing
    /// @dev In local tests, genesis deploys at v31 but we want to test upgrade to v32
    function overrideProtocolVersionForLocalTesting(string memory upgradeInputPath) internal override {
        string memory root = vm.projectRoot();
        string memory upgradeToml = vm.readFile(string.concat(root, upgradeInputPath));
        uint256 newProtocolVersion = upgradeToml.readUint("$.contracts.new_protocol_version");
        getCTMUpgrade().setNewProtocolVersion(newProtocolVersion);
    }
}

contract UpgradeIntegrationTest_Local is
    UpgradeIntegrationTestBase,
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer
{
    /// @notice Override to use mocked ecosystem upgrade that uses mocked CTM upgrade
    function createEcosystemUpgrade() internal override returns (EcosystemUpgrade_v31) {
        return new EcosystemUpgrade_v31_Test();
    }

    /// @notice Set totalBatchesExecuted and totalBatchesCommitted before chain upgrade
    /// @dev Required because saveV31UpgradeChainBatchNumber checks that totalBatchesExecuted > 0
    function beforeChainUpgrade() internal override {
        // Set totalBatchesExecuted and totalBatchesCommitted to 1
        // Both need to be set to satisfy: require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());
        // Note: These are absolute storage slots, not relative to DIAMOND_STORAGE_POSITION
        // See: contracts/state-transition/chain-deps/ZKChainStorage.sol
        bytes32 totalBatchesExecutedSlot = bytes32(uint256(11));  // STORAGE SLOT: 11
        bytes32 totalBatchesCommittedSlot = bytes32(uint256(13)); // STORAGE SLOT: 13
        address eraChainDiamond = addresses.bridgehub.getZKChain(eraZKChainId);

        vm.store(eraChainDiamond, totalBatchesExecutedSlot, bytes32(uint256(1)));
        vm.store(eraChainDiamond, totalBatchesCommittedSlot, bytes32(uint256(1)));

        // Set v31UpgradeChainBatchNumber[eraZKChainId] to placeholder value
        // In local tests, the era chain is deployed AFTER MessageRoot, so v31UpgradeChainBatchNumber[9]
        // was never initialized to the placeholder value. In a real V31 upgrade, initializeL1V31Upgrade()
        // would be called first to set all existing chains to the placeholder.
        address messageRoot = address(addresses.bridgehub.messageRoot());

        // v31UpgradeChainBatchNumber is at slot 50 in L1MessageRoot
        // Storage layout: Initializable(0), MessageRootBase vars(1-12), __gap[37](13-49), v31UpgradeChainBatchNumber(50)
        bytes32 v31MappingSlot = keccak256(abi.encode(eraZKChainId, uint256(50)));
        vm.store(messageRoot, v31MappingSlot, bytes32(V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE_FOR_L1));
    }

    function setUp() public {
        console.log("setUp: Starting");
        _deployL1Contracts();
        console.log("setUp: L1 contracts deployed");
        _deployTokens();
        console.log("setUp: Tokens deployed");
        _registerNewTokens(tokens);
        console.log("setUp: Tokens registered");

        _deployEra();
        console.log("setUp: Era deployed");
        chainId = eraZKChainId;
        acceptPendingAdmin();
        console.log("setUp: Pending admin accepted");
        PERMANENT_VALUES_INPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/permanent-ctm.toml";

        ECOSYSTEM_UPGRADE_INPUT = "/upgrade-envs/v0.31.0-interopB/foundry-upgrade.toml";
        ECOSYSTEM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml";
        ECOSYSTEM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/local-core.toml";
        CTM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm.toml";
        CTM_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/local-ctm.toml";
        CHAIN_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml";
        CHAIN_OUTPUT = "/test/foundry/l1/integration/upgrade-envs/script-out/local-gateway.toml";
        console.log("setUp: Paths configured");
        preparePermanentValues();
        console.log("setUp: Permanent values prepared");
        setupUpgrade(true);
        console.log("setUp: Upgrade setup complete");
        address bridgehub = ecosystemUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        console.log("setUp: Got bridgehub address", bridgehub);
        bytes32 eraBaseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(eraZKChainId);
        console.log("setUp: Got era base token asset ID");

        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(eraBaseTokenAssetId));
        console.log("setUp: Mock call setup");
        internalTest();
        console.log("setUp: Internal test complete");
    }

    function test_DefaultUpgrade_Local() public {
        /// we do the whole test in the setup, since it is very ram heavy.
        require(true, "test passed");
    }
}
