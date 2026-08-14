// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {CTMUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {CoreUpgrade_v31} from "../../../../deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {ChainCreationParamsConfig, StateTransitionDeployedAddresses} from "../../../../deploy-scripts/utils/Types.sol";
import {PublishFactoryDepsResult} from "../../../../deploy-scripts/utils/bytecode/BytecodePublisher.s.sol";
import {Test} from "forge-std/Test.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE} from "contracts/core/message-root/IMessageRoot.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Utils} from "../../../../deploy-scripts/utils/Utils.sol";
import {IPriorityOpLowerBound} from "contracts/upgrades/IPriorityOpLowerBound.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgradeZKsyncOS} from "contracts/upgrades/DefaultUpgradeZKsyncOS.sol";
import {Bytes} from "contracts/vendor/Bytes.sol";

/// @notice Test-only CTM upgrade that mocks large bytecode reads to avoid MemoryOOG
contract CTMUpgrade_v31_Test is CTMUpgrade_v31 {
    /// @notice Exposes the deployed PriorityOpLowerBound registry for the test's chain-upgrade precondition.
    function exposedPriorityOpLowerBound() external view returns (address) {
        return priorityOpLowerBound;
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

    /// @notice Override to skip bytecode-heavy force deployment generation in getProposedUpgrade.
    /// The base implementation reads all zkout bytecodes, causing MemoryOOG.
    /// We return an empty upgrade instead.
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

/// @notice Test-only Core upgrade that skips governance calls the local fixture cannot satisfy.
contract CoreUpgrade_v31_Test is CoreUpgrade_v31 {
    /// @notice Override to skip the ownership-acceptance and `setAddresses` calls, which need ownership
    ///         hand-offs the fixture does not perform.
    /// @dev The interop-handler wiring is kept: it is what makes a v31 ecosystem match a from-scratch v32
    ///      one. In this fixture it collapses to nothing — the ecosystem already has a wired handler — so
    ///      the calls themselves are covered by `PreV32ParityCalls.t.sol`, not here.
    function prepareVersionSpecificStage1GovernanceCallsL1() public override returns (Call[] memory calls) {
        console.log("Test mode: keeping only the L1InteropHandler wiring in stage 1");
        return _buildL1InteropHandlerWiringCalls();
    }
}

// Note: there is no longer a separate `EcosystemUpgrade_v31_Test` orchestrator subclass.
// The local-fork integration test injects mocked Core and CTM upgrades by overriding
// `createCoreUpgrade` / `createCTMUpgrade` on `UpgradeIntegrationTest_Local` directly,
// and bumps the protocol version in `setUp` after `setupUpgrade()`.

// AGENTS.md mandates "NEVER override storage slots in tests" with no exceptions,
// but this local-fork harness is the one place we can't avoid it: the upgrade flow
// depends on chain state (batches executed/committed > 0, MessageRoot's per-chain
// placeholder) that production reaches via real batch commits and the v31 upgrade
// this ecosystem is assumed to have been through. In a freshly-deployed local
// fixture neither has happened yet, and there is no public API to drive them —
// v32 has no writer for the placeholder at all. The overrides below substitute
// for that history; they are scoped to this `setUp`/`beforeChainUpgrade` and
// never run against a real chain.
//
// Slot indices below are taken from `forge inspect <Contract> storageLayout` on
// the v31 contracts; if any of these contracts ever shift their storage layout
// these constants need to move with it.

// Slot of `ZKChainBase.totalBatchesExecuted` (absolute, not relative to DIAMOND_STORAGE_POSITION).
// See `contracts/state-transition/chain-deps/ZKChainStorage.sol`.
uint256 constant ZK_CHAIN_TOTAL_BATCHES_EXECUTED_SLOT = 11;
// Slot of `ZKChainBase.totalBatchesCommitted` (absolute).
uint256 constant ZK_CHAIN_TOTAL_BATCHES_COMMITTED_SLOT = 13;
// Slot of `L1MessageRoot.v31UpgradeChainBatchNumber` (mapping). Layout:
// `Initializable(0)`, `MessageRootBase(1-12)`, `__gap[37](13-49)`, this(50).
uint256 constant L1_MESSAGE_ROOT_V31_UPGRADE_BATCH_NUMBER_SLOT = 50;
contract UpgradeIntegrationTest_Local is
    UpgradeIntegrationTestBase,
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer
{
    using stdToml for string;
    using Bytes for bytes;

    address private _serverNotifierProxy;
    address private _serverNotifierProxyAdmin;
    address private _expectedServerNotifierProxyAdminOwner;
    bytes32 private _expectedRewrittenUpgradeTxHash;

    /// @notice Override to inject the mocked Core upgrade (keeps only the interop-handler wiring in stage 1).
    function createCoreUpgrade() internal override returns (CoreUpgrade_v31) {
        return new CoreUpgrade_v31_Test();
    }

    /// @notice Override to inject the mocked CTM upgrade (skips bytecode-heavy reads).
    function createCTMUpgrade() internal override returns (CTMUpgrade_v31) {
        return new CTMUpgrade_v31_Test();
    }

    /// @notice Bump the CTM's protocol version from the upgrade input TOML so the local fixture
    ///         exercises an upgrade to one minor above the genesis version (currently v32 → v33).
    ///         See `foundry-upgrade.toml`.
    /// @dev    Replaces the former `overrideProtocolVersionForLocalTesting` hook on the
    ///         deleted `DefaultEcosystemUpgrade` orchestrator.
    function afterInitHook() internal override {
        string memory root = vm.projectRoot();
        string memory upgradeToml = vm.readFile(string.concat(root, ECOSYSTEM_UPGRADE_INPUT));
        uint256 newProtocolVersion = upgradeToml.readUint("$.contracts.new_protocol_version");
        ctmUpgrade.setNewProtocolVersion(newProtocolVersion);
    }

    /// Substitute the batch history a live chain would have: a committed and executed batch (both at 1),
    /// plus the L1MessageRoot per-chain placeholder that v31 set for this chain. Equal committed and executed
    /// counts are required by `DefaultUpgradeZKsyncOS`.
    /// Committing and executing a real batch needs a prover and a sequencer, so there is no public API to
    /// reach this state in a foundry fixture. See the fork-only-violation note at the top of this file.
    function beforeChainUpgrade() internal override {
        address sourceChainDiamond = addresses.bridgehub.getZKChain(eraZKChainId);
        vm.store(sourceChainDiamond, bytes32(ZK_CHAIN_TOTAL_BATCHES_EXECUTED_SLOT), bytes32(uint256(1)));
        vm.store(sourceChainDiamond, bytes32(ZK_CHAIN_TOTAL_BATCHES_COMMITTED_SLOT), bytes32(uint256(1)));

        address messageRoot = address(addresses.bridgehub.messageRoot());
        bytes32 v31MappingSlot = keccak256(abi.encode(eraZKChainId, L1_MESSAGE_ROOT_V31_UPGRADE_BATCH_NUMBER_SLOT));
        vm.store(messageRoot, v31MappingSlot, bytes32(V31_UPGRADE_CHAIN_BATCH_NUMBER_PLACEHOLDER_VALUE));

        // v32 upgrade precondition: the chain's priority-op lower bound must be recorded before the
        // upgrade executes (permissionless; production runs RecordPriorityOpLowerBound.s.sol).
        IPriorityOpLowerBound(CTMUpgrade_v31_Test(address(ctmUpgrade)).exposedPriorityOpLowerBound())
            .lowerBoundPriorityOp(sourceChainDiamond);
    }

    function _snapshotExpectedZKsyncOSUpgradeTxHash() private {
        Diamond.DiamondCutData memory cut = abi.decode(
            ctmUpgrade.getChainUpgradeDiamondCutData(),
            (Diamond.DiamondCutData)
        );
        address defaultUpgrade = ctmUpgrade.getAddresses().stateTransition.defaultUpgrade;
        assertEq(cut.initAddress, defaultUpgrade, "Wrong per-chain upgrade implementation");

        ProposedUpgrade memory proposedUpgrade = abi.decode(cut.initCalldata.slice(4), (ProposedUpgrade));
        bytes32 placeholderHash = keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx));
        proposedUpgrade.l2ProtocolUpgradeTx.data = DefaultUpgradeZKsyncOS(cut.initAddress).getL2UpgradeTxData(
            address(addresses.bridgehub),
            eraZKChainId,
            true,
            proposedUpgrade.l2ProtocolUpgradeTx.data
        );
        _expectedRewrittenUpgradeTxHash = keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx));
        assertNotEq(_expectedRewrittenUpgradeTxHash, placeholderHash, "OS rewrite was a no-op");
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
        console.log("setUp: Existing ZKsync OS chain deployed");
        chainId = eraZKChainId;
        acceptPendingAdmin();
        assertTrue(addresses.chainTypeManager.isZKsyncOS(), "Fixture CTM is not ZKsync OS");
        assertTrue(
            IGetters(addresses.bridgehub.getZKChain(eraZKChainId)).getZKsyncOS(),
            "Existing chain fixture is not ZKsync OS"
        );
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
        _snapshotExpectedZKsyncOSUpgradeTxHash();

        _serverNotifierProxy = ctmUpgrade.getAddresses().stateTransition.proxies.serverNotifier;
        if (_serverNotifierProxy != address(0)) {
            _serverNotifierProxyAdmin = address(uint160(uint256(vm.load(_serverNotifierProxy, Utils.ADMIN_SLOT))));
            _expectedServerNotifierProxyAdminOwner = getOwnableOwner(_serverNotifierProxyAdmin);
        }
        console.log("setUp: Snapshotted ServerNotifier ProxyAdmin ownership");

        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        console.log("setUp: Got bridgehub address", bridgehub);
        bytes32 sourceBaseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(eraZKChainId);
        _expectedBaseTokenAssetId = sourceBaseTokenAssetId;
        console.log("setUp: Got existing chain base token asset ID");

        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(sourceBaseTokenAssetId));
        console.log("setUp: Mock call setup");
        internalTest();
        console.log("setUp: Internal test complete");
    }

    function test_DefaultUpgradeZKsyncOS_Local() public {
        // Heavy execution and event assertions live in setUp -> internalTest()
        // (RAM constraint). This body validates persisted state outcomes.
        address ctm = ctmUpgrade.getCTMAddress();
        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;

        // Protocol version bumps
        assertEq(IChainTypeManager(ctm).protocolVersion(), _expectedNewVersion, "CTM protocolVersion not bumped");
        assertEq(IGetters(_eraDiamond).getProtocolVersion(), _expectedNewVersion, "Existing chain not upgraded");
        assertTrue(IGetters(_eraDiamond).getZKsyncOS(), "Existing chain is not ZKsync OS after upgrade");
        assertEq(
            IGetters(_eraDiamond).getL2SystemContractsUpgradeTxHash(),
            _expectedRewrittenUpgradeTxHash,
            "Diamond did not record the rewritten OS transaction"
        );

        // Existing chain identity preserved across upgrade
        assertEq(IGetters(_eraDiamond).getChainId(), eraZKChainId, "Existing diamond points at wrong chainId");

        // New chain registered, bound to the upgraded CTM, and exposes the right chainId/admin
        assertTrue(_newChainDiamond != address(0), "New chain ID not registered");
        assertEq(IGetters(_newChainDiamond).getChainId(), NEW_CHAIN_ID, "New diamond points at wrong chainId");
        assertEq(IGetters(_newChainDiamond).getProtocolVersion(), _expectedNewVersion, "New chain wrong version");
        assertTrue(IGetters(_newChainDiamond).getZKsyncOS(), "New chain is not ZKsync OS");
        assertEq(IBridgehubBase(bridgehub).chainTypeManager(NEW_CHAIN_ID), ctm, "New chain not linked to CTM");
        assertEq(
            IChainTypeManager(ctm).getChainAdmin(NEW_CHAIN_ID),
            _expectedNewChainAdmin,
            "New chain admin mismatch"
        );

        // Base-token asset id matches the existing chain (the chainId=0 mock in setUp propagates it on creation)
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

        // The wiring a v32 ecosystem has to end up with. This fixture starts from current contracts, so it
        // is already wired and the upgrade emits no wiring calls: these assertions pin the invariant, while
        // the calls that establish it on a real v31 ecosystem are covered by `PreV32ParityCalls.t.sol`
        // (`test_wiresTheNewInteropHandler`).
        address l1InteropHandler = coreUpgrade.getCoreAddresses().bridges.proxies.l1InteropHandler;
        assertTrue(l1InteropHandler != address(0), "No L1InteropHandler after the upgrade");
        assertEq(
            L1Nullifier(payable(coreUpgrade.getCoreAddresses().bridges.proxies.l1Nullifier)).l1InteropHandler(),
            l1InteropHandler,
            "Nullifier not wired to the interop handler"
        );
        assertEq(
            L1AssetRouter(payable(coreUpgrade.getCoreAddresses().bridges.proxies.l1AssetRouter)).l1InteropHandler(),
            l1InteropHandler,
            "Asset router not wired to the interop handler"
        );
        assertEq(
            IBridgehubBase(bridgehub).chainRegistrationSender(),
            coreUpgrade.getDiscoveredBridgehub().proxies.chainRegistrationSender,
            "Bridgehub does not know the ChainRegistrationSender"
        );

        if (_serverNotifierProxy != address(0)) {
            assertEq(
                getOwnableOwner(_serverNotifierProxyAdmin),
                _expectedServerNotifierProxyAdminOwner,
                "ServerNotifier ProxyAdmin owner changed"
            );
            assertEq(
                address(uint160(uint256(vm.load(_serverNotifierProxy, Utils.IMPLEMENTATION_SLOT)))),
                ctmUpgrade.getAddresses().stateTransition.implementations.serverNotifier,
                "ServerNotifier implementation not upgraded"
            );
        }
    }
}
