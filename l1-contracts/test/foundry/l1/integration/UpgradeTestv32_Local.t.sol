// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {CTMUpgrade_v32} from "../../../../deploy-scripts/upgrade/v32/CTMUpgrade_v32.s.sol";
import {CoreUpgrade_v32} from "../../../../deploy-scripts/upgrade/v32/CoreUpgrade_v32.s.sol";
import {ChainUpgrade_v32} from "../../../../deploy-scripts/upgrade/v32/ChainUpgrade_v32.s.sol";
import {DefaultCoreUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultChainUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "../../../../deploy-scripts/utils/Types.sol";
import {PublishFactoryDepsResult} from "../../../../deploy-scripts/utils/bytecode/BytecodePublisher.s.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {
    L2UpgradePlan,
    PinnedContract,
    TransitionManifest,
    ProxyUpgradeRow
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {UpgradeHelperLib} from "../../../../deploy-scripts/upgrade/default-upgrade/UpgradeHelperLib.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Utils} from "../../../../deploy-scripts/utils/Utils.sol";

/// @notice Test-only CTM upgrade that mocks large bytecode reads to avoid MemoryOOG. Same shape
///         as the v31 mock — the heavy JSON/zkout reads live on the shared base both versions
///         extend, so the overrides carry over.
contract CTMUpgrade_v32_Test is CTMUpgrade_v32 {
    /// @notice Commit the local edge as a transition instead of the cut-taking setter. The local
    ///         baseline chain already runs the v32 (no-cut) Admin facet, which reads its cut from
    ///         `upgradeCutForVersion` — derived from the committed transition. The cut-taking
    ///         setter (used on the real bootstrap edge, whose chains still run v31 facets)
    ///         registers no transition, so the chain leg could never execute.
    function provideSetNewVersionUpgradeCall() public override returns (Call[] memory calls) {
        calls = super.provideSetNewVersionUpgradeCall();

        address ctmProxy = ctmAddresses.stateTransition.proxies.chainTypeManager;
        address engine = ctmAddresses.stateTransition.defaultUpgrade;
        // The same wrapped payload the legacy cut carried: `SettlementLayerV32Upgrade` requires
        // the `forceDeployAndUpgradeUniversal(…, genesisUpgrade(...))` shape to rewrite the
        // per-chain placeholders, so the plan mirrors `getV32L2UpgradeCalldata`.
        CTMTransition transition = new CTMTransition(
            TransitionManifest({
                oldProtocolVersion: getOldProtocolVersion(),
                newProtocolVersion: getNewProtocolVersion(),
                fromRelease: IChainTypeManager(ctmProxy).currentRelease(),
                newRelease: ctmAddresses.stateTransition.currentRelease,
                upgradeEngine: PinnedContract({addr: engine, codehash: engine.codehash}),
                ctmProxyRows: new ProxyUpgradeRow[](0),
                oldProtocolVersionDeadline: UpgradeHelperLib.getOldProtocolDeadline(),
                upgradeTimestamp: 0,
                l2Plan: L2UpgradePlan({
                    deployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                    delegateTo: L2_GENESIS_UPGRADE_ADDR,
                    delegateCalldata: getV32L2UpgradeCalldata(),
                    factoryDepHashes: factoryDepsResult.factoryDepsHashes
                })
            })
        );
        // Keep the base's release-anchor calls; only the commit itself changes shape.
        calls[0] = Call({
            target: ctmProxy,
            data: abi.encodeCall(
                IChainTypeManager.setNewVersionUpgradeFromTransition,
                (ICTMTransition(address(transition)))
            ),
            value: 0
        });
    }

    /// @notice v32 deploys its genesis registry inside `deployNewCTMContracts` (before
    ///         `publishBytecodes`), and that requires a non-empty force-deployments blob. This
    ///         mocked flow never generates one, so seed a dummy before the base deploy runs.
    function deployNewCTMContracts() public override {
        if (generatedData.forceDeploymentsData.length == 0) {
            generatedData.forceDeploymentsData = hex"01";
        }
        super.deployNewCTMContracts();
    }

    /// @notice Return a dummy bytecode hash instead of reading huge JSON files.
    function getL2BytecodeHash(string memory /* contractName */) public view override returns (bytes32) {
        return bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001));
    }

    /// @notice Skip bytecode publishing (reads large JSON files). Also seed a non-empty
    ///         force-deployments blob: the v32 genesis registry deployed in `deployNewCTMContracts`
    ///         requires one, and this mocked flow never generates it.
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

        if (generatedData.forceDeploymentsData.length == 0) {
            generatedData.forceDeploymentsData = hex"01";
        }
    }

    /// @notice Skip bytecode-heavy force-deployment generation in `getProposedUpgrade` (the base
    ///         reads all zkout bytecodes, causing MemoryOOG). Return an empty L2 upgrade instead.
    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition,
        ChainCreationParamsConfig memory chainCreationParams,
        uint256,
        address,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 protocolUpgradeNonce
    ) public override returns (ProposedUpgrade memory proposedUpgrade) {
        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(
                new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                _factoryDepsResult,
                protocolUpgradeNonce
            ),
            bootloaderHash: chainCreationParams.bootloaderHash,
            defaultAccountHash: chainCreationParams.defaultAAHash,
            evmEmulatorHash: chainCreationParams.evmEmulatorHash,
            verifier: address(0),
            verifierParams: ProposedUpgradeLib.emptyVerifierParams(),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: encodePostUpgradeCalldata(stateTransition),
            upgradeTimestamp: 0,
            newProtocolVersion: chainCreationParams.latestProtocolVersion
        });
    }
}

/// @notice Test-only Core upgrade that skips governance calls needing real ownership in the fixture.
contract CoreUpgrade_v32_Test is CoreUpgrade_v32 {
    function prepareVersionSpecificStage1GovernanceCallsL1() public override returns (Call[] memory calls) {
        console.log("Test mode: Skipping version-specific stage-1 governance calls");
        calls = new Call[](0);
    }
}

/// @notice Local (non-fork) v31 -> v32 upgrade test. Deploys a fresh ecosystem + Era chain at the
///         baseline version, then drives the v32 upgrade through the same Default*Upgrade harness
///         production uses. Unlike v31, the v32 SettlementLayer upgrade performs NO L1 storage
///         migration, so the v31 MessageRoot reinit / per-chain placeholder machinery is gone and
///         no per-chain batch fixture is needed — the fresh chain upgrades from zero batches.
/// @dev Heavy execution + event assertions run in `setUp -> internalTest()` (RAM constraint); the
///      body checks persisted state, including that the CTM is pinned to a genesis registry (the
///      defining property of the registry-driven v32 upgrade).
contract UpgradeIntegrationTest_v32_Local is
    UpgradeIntegrationTestBase,
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer
{
    using stdToml for string;

    address private _serverNotifierProxy;

    function createCoreUpgrade() internal override returns (DefaultCoreUpgrade) {
        return new CoreUpgrade_v32_Test();
    }

    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgrade_v32_Test();
    }

    function createChainUpgrade() internal override returns (DefaultChainUpgrade) {
        return new ChainUpgrade_v32();
    }

    /// @notice Bump the CTM's new protocol version from the upgrade input TOML so the local
    ///         baseline fixture exercises a real version transition.
    function afterInitHook() internal override {
        string memory root = vm.projectRoot();
        string memory upgradeToml = vm.readFile(string.concat(root, ECOSYSTEM_UPGRADE_INPUT));
        uint256 newProtocolVersion = upgradeToml.readUint("$.contracts.new_protocol_version");
        ctmUpgrade.setNewProtocolVersion(newProtocolVersion);
    }

    // NOTE: v32 needs no `beforeChainUpgrade` fixture. v32 does no L1 storage migration and its
    // chain upgrade (`upgradeChainFromVersion` with the committed cut) imposes no
    // executed-batch precondition, so the freshly-deployed chain (0 committed/executed batches)
    // upgrades cleanly. The base's no-op override is used — no storage-slot writes.

    function setUp() public {
        console.log("setUp: Starting");
        _deployL1Contracts();
        console.log("setUp: L1 contracts deployed");
        _deployTokens();
        _registerNewTokens(tokens);
        console.log("setUp: Tokens deployed + registered");

        _deployEra();
        console.log("setUp: Era deployed");
        chainId = eraZKChainId;
        acceptPendingAdmin();

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

        _serverNotifierProxy = ctmUpgrade.getAddresses().stateTransition.proxies.serverNotifier;

        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        bytes32 eraBaseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(eraZKChainId);
        _expectedBaseTokenAssetId = eraBaseTokenAssetId;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(eraBaseTokenAssetId));
        console.log("setUp: Running internalTest");
        internalTest();
        console.log("setUp: Internal test complete");
    }

    function test_v32Upgrade_Local() public {
        address ctm = ctmUpgrade.getCTMAddress();
        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;

        // Protocol version bumps.
        assertEq(IChainTypeManager(ctm).protocolVersion(), _expectedNewVersion, "CTM protocolVersion not bumped");
        assertEq(IGetters(_eraDiamond).getProtocolVersion(), _expectedNewVersion, "Era chain not upgraded");
        assertEq(IGetters(_eraDiamond).getChainId(), eraZKChainId, "Era diamond points at wrong chainId");

        // v32 is registry-driven: the CTM must be pinned to a genesis registry that new chains
        // read all their genesis data from.
        assertTrue(IChainTypeManager(ctm).currentRelease() != address(0), "CTM release not pinned");

        // New chain created from the registry, bound to the upgraded CTM.
        assertTrue(_newChainDiamond != address(0), "New chain ID not registered");
        assertEq(IGetters(_newChainDiamond).getChainId(), NEW_CHAIN_ID, "New diamond points at wrong chainId");
        assertEq(IGetters(_newChainDiamond).getProtocolVersion(), _expectedNewVersion, "New chain wrong version");
        assertEq(IBridgehubBase(bridgehub).chainTypeManager(NEW_CHAIN_ID), ctm, "New chain not linked to CTM");
        assertEq(
            IChainTypeManager(ctm).getChainAdmin(NEW_CHAIN_ID),
            _expectedNewChainAdmin,
            "New chain admin mismatch"
        );

        // CTM-side upgrade storage.
        assertEq(
            IChainTypeManager(ctm).upgradeCutHash(ctmUpgrade.getOldProtocolVersion()),
            _expectedUpgradeCutHash,
            "Stored upgradeCutHash mismatch"
        );
        // The verifier now lives on the release the CTM pins, not in a version-keyed map.
        assertTrue(
            ICTMRelease(IChainTypeManager(ctm).currentRelease()).verifier() != address(0),
            "Missing verifier on the pinned release"
        );

        // Bridgehub-side registrations.
        assertTrue(IBridgehubBase(bridgehub).chainTypeManagerIsRegistered(ctm), "CTM not registered with bridgehub");
        assertTrue(
            IBridgehubBase(bridgehub).assetIdIsRegistered(_expectedBaseTokenAssetId),
            "Base token assetId not registered"
        );
    }
}
