// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {EcosystemUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {CoreUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {Test} from "forge-std/Test.sol";
import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultCoreUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE} from "contracts/core/message-root/IMessageRoot.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

/// @notice Test-only CTM upgrade that mocks large bytecode reads to avoid MemoryOOG
contract CTMUpgrade_v31_Test is CTMUpgrade_v31 {
    /// @notice Override to return dummy bytecode hashes instead of reading huge JSON files
    function getL2BytecodeHash(string memory /* contractName */) public view override returns (bytes32) {
        // Return a valid dummy bytecode hash (must have version byte 0x01 and odd length marker)
        return bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001));
    }

    /// @notice Override to skip bytecode publishing which reads large JSON files.
    function publishBytecodes() public override {
        console.log("Test mode: Skipping bytecode publishing to avoid MemoryOOG");

        factoryDepsResult.factoryDepsHashes = new uint256[](45);

        factoryDepsResult.factoryDepsHashes[0] = uint256(config.contracts.chainCreationParams.bootloaderHash);
        factoryDepsResult.factoryDepsHashes[1] = uint256(config.contracts.chainCreationParams.defaultAAHash);
        factoryDepsResult.factoryDepsHashes[2] = uint256(config.contracts.chainCreationParams.evmEmulatorHash);

        bytes32 dummyHash = bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001));
        for (uint256 i = 3; i < 45; i++) {
            factoryDepsResult.factoryDepsHashes[i] = uint256(dummyHash);
        }

        upgradeConfig.factoryDepsPublished = true;
    }

    /// @notice Override to skip reading all system contract bytecodes which causes MemoryOOG.
    function buildUpgradeForceDeployments(
        uint256,
        address
    ) internal override returns (IL2ContractDeployer.ForceDeployment[] memory) {
        return new IL2ContractDeployer.ForceDeployment[](0);
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
        bytes32 totalBatchesExecutedSlot = bytes32(uint256(11)); // STORAGE SLOT: 11
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
        vm.store(messageRoot, v31MappingSlot, bytes32(V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE));
    }

    function setUp() public {
        console.log("setUp: Starting");
        _deployL1Contracts();
        console.log("setUp: L1 contracts deployed");

        // Reset L1MessageRoot's initializer version to 1 so that initializeL1V31Upgrade() (reinitializer(2)) works
        // Fresh deployments call initialize() which uses reinitializer(2), but we need to test the upgrade path
        // Initializable storage slot 0 contains the version (uint8) packed with _initializing (bool)
        address messageRootProxy = address(addresses.bridgehub.messageRoot());
        vm.store(messageRootProxy, bytes32(uint256(0)), bytes32(uint256(1)));
        console.log("setUp: Reset L1MessageRoot initializer version to 1");
        _deployTokens();
        console.log("setUp: Tokens deployed");
        _registerNewTokens(tokens);
        console.log("setUp: Tokens registered");

        _deployEra();
        console.log("setUp: Era deployed");
        chainId = eraZKChainId;
        acceptPendingAdmin();
        console.log("setUp: Pending admin accepted");
        ECOSYSTEM_UPGRADE_INPUT = "/upgrade-envs/v0.31.0-interopB/foundry-upgrade.toml";
        ECOSYSTEM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml";
        ECOSYSTEM_OUTPUT = "/script-out/foundry-upgrade/local-core.toml";
        CTM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm.toml";
        CTM_OUTPUT = "/script-out/foundry-upgrade/local-ctm.toml";
        CHAIN_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml";
        CHAIN_OUTPUT = "/script-out/foundry-upgrade/local-gateway.toml";
        console.log("setUp: Paths configured");
        setupUpgrade(true);
        console.log("setUp: Upgrade setup complete");
        address bridgehub = ecosystemUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        console.log("setUp: Got bridgehub address", bridgehub);
        bytes32 eraBaseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(eraZKChainId);
        _expectedBaseTokenAssetId = eraBaseTokenAssetId;
        console.log("setUp: Got era base token asset ID");

        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(eraBaseTokenAssetId));
        console.log("setUp: Mock call setup");
        internalTest();
        console.log("setUp: Internal test complete");
    }

    function test_DefaultUpgrade_Local() public {
        // Heavy execution and event assertions live in setUp -> internalTest()
        // (RAM constraint). This body validates persisted state outcomes.
        address ctm = ctmUpgrade.getCTMAddress();
        address bridgehub = ecosystemUpgrade.getDiscoveredBridgehub().proxies.bridgehub;

        // Protocol version bumps
        assertEq(IChainTypeManager(ctm).protocolVersion(), _expectedNewVersion, "CTM protocolVersion not bumped");
        assertEq(IGetters(_eraDiamond).getProtocolVersion(), _expectedNewVersion, "Era chain not upgraded");

        // Era chain identity preserved across upgrade
        assertEq(IGetters(_eraDiamond).getChainId(), eraZKChainId, "Era diamond points at wrong chainId");

        // New chain registered, bound to the upgraded CTM, and exposes the right chainId/admin
        assertTrue(_newChainDiamond != address(0), "New chain ID not registered");
        assertEq(IGetters(_newChainDiamond).getChainId(), NEW_CHAIN_ID, "New diamond points at wrong chainId");
        assertEq(IGetters(_newChainDiamond).getProtocolVersion(), _expectedNewVersion, "New chain wrong version");
        assertEq(IBridgehubBase(bridgehub).chainTypeManager(NEW_CHAIN_ID), ctm, "New chain not linked to CTM");
        assertEq(IChainTypeManager(ctm).getChainAdmin(NEW_CHAIN_ID), _expectedNewChainAdmin, "New chain admin mismatch");

        // Base-token asset id matches the era one (the mock at chainId=0 in setUp propagates it on creation)
        assertEq(
            IBridgehubBase(bridgehub).baseTokenAssetId(NEW_CHAIN_ID),
            _expectedBaseTokenAssetId,
            "New chain wrong baseTokenAssetId"
        );

        // CTM-side upgrade storage
        assertEq(
            IChainTypeManager(ctm).upgradeCutHash(ctmUpgrade.getOldProtocolVersion()),
            _expectedUpgradeCutHash,
            "Stored upgradeCutHash mismatch"
        );
        assertTrue(
            IChainTypeManager(ctm).protocolVersionVerifier(_expectedNewVersion) != address(0),
            "Missing verifier for new version"
        );
        assertGt(
            IChainTypeManager(ctm).protocolVersionDeadline(_expectedNewVersion),
            block.timestamp,
            "Degenerate version deadline"
        );

        // Bridgehub-side registrations
        assertTrue(IBridgehubBase(bridgehub).chainTypeManagerIsRegistered(ctm), "CTM not registered with bridgehub");
        assertTrue(
            IBridgehubBase(bridgehub).assetIdIsRegistered(_expectedBaseTokenAssetId),
            "Base token assetId not registered"
        );
    }    
}
