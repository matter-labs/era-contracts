// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2 as console} from "forge-std/Script.sol";

import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IZKsyncOSVerifier} from "contracts/state-transition/chain-interfaces/IZKsyncOSVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ZKsyncOSVerifier} from "contracts/state-transition/verifiers/ZKsyncOSVerifier.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {ChainCreationParamsConfig} from "../../../../deploy-scripts/utils/Types.sol";
import {ChainCreationParamsLib} from "../../../../deploy-scripts/ctm/ChainCreationParamsLib.sol";
import {PublishFactoryDepsResult} from "../../../../deploy-scripts/utils/bytecode/BytecodePublisher.s.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {Utils} from "../../../../deploy-scripts/utils/Utils.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DefaultUpgradeZKsyncOS} from "contracts/upgrades/DefaultUpgradeZKsyncOS.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {Bytes} from "contracts/vendor/Bytes.sol";

/// @notice Test-only variant of the CTM script protocol-ops prepares with by default, skipping the
///         bytecode-heavy steps to avoid MemoryOOG.
/// @dev Only the two memory-trimming overrides below differ from {DefaultCTMUpgrade}; everything else (deploys,
///      governance calls, per-chain cut and its initializer) is the production script. protocol-ops'
///      `prepare_defaults_match_the_foundry_full_flow_test` fails if this stops extending the default
///      `--ctm-script-path` script.
contract CTMUpgradeForLocalTest is DefaultCTMUpgrade {
    /// @notice Override to skip bytecode publishing which reads large JSON files.
    function publishBytecodes() public override {
        console.log("Test mode: Skipping bytecode publishing to avoid MemoryOOG");

        factoryDepsResult.factoryDepsHashes = new uint256[](45);

        // Slots 0-2 are the bootloader / default-account / EVM-emulator hashes, which ZKsync OS
        // leaves at zero.
        bytes32 dummyHash = bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001));
        for (uint256 i = 3; i < 45; i++) {
            factoryDepsResult.factoryDepsHashes[i] = uint256(dummyHash);
        }

        upgradeConfig.factoryDepsPublished = true;
    }

    /// @notice Override to skip bytecode-heavy force deployment generation in getProposedUpgrade.
    /// The base implementation reads every force-deployment bytecode, causing MemoryOOG.
    /// We return an upgrade without force deployments instead.
    function getProposedUpgrade(
        ChainCreationParamsConfig memory _chainCreationParams,
        PublishFactoryDepsResult memory _factoryDepsResult,
        uint256 _protocolUpgradeNonce
    ) public override returns (ProposedUpgrade memory proposedUpgrade) {
        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: composeUpgradeTx(
                new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                _factoryDepsResult,
                _protocolUpgradeNonce
            ),
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            evmEmulatorHash: bytes32(0),
            verifier: address(0),
            verifierParams: ProposedUpgradeLib.emptyVerifierParams(),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: encodePostUpgradeCalldata(),
            upgradeTimestamp: 0,
            newProtocolVersion: _chainCreationParams.latestProtocolVersion
        });
    }
}

/// @notice End-to-end run of the upgrade scripts protocol-ops prepares with by default (`DefaultCoreUpgrade`
///         + the default CTM script) against an ecosystem freshly deployed at the genesis version.
/// @dev The target version is derived from genesis (minor + 1). The only release-specific name is the CTM
///      script {CTMUpgradeForLocalTest} extends, which protocol-ops pins to its default.
///      The upgrade from the previous release's real chain states is covered by the anvil upgrade test.
contract UpgradeIntegrationTestLocal is UpgradeIntegrationTestBase, L1ContractDeployer, ZKChainDeployer, TokenDeployer {
    using Bytes for bytes;

    address private _serverNotifierProxy;
    address private _serverNotifierProxyAdmin;
    address private _expectedServerNotifierProxyAdminOwner;
    bytes32 private _expectedRewrittenUpgradeTxHash;

    /// @notice Override to inject the memory-trimmed default CTM script (skips bytecode-heavy reads).
    /// @dev The core side needs no test subclass: the plain {DefaultCoreUpgrade} from the base is used.
    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgradeForLocalTest();
    }

    /// @notice Target one minor above the genesis version the fixture was deployed at.
    /// @dev The default scripts take the target from genesis, which is also what the fixture deploys,
    ///      and `DefaultCTMUpgrade` refuses to upgrade a CTM to the version it already runs. Deriving
    ///      the target here (genesis minor + 1, patch 0) keeps the test valid across release bumps.
    function afterInitHook() internal override {
        ctmUpgrade.setNewProtocolVersion(_nextMinorAfterGenesis());
    }

    /// @notice Genesis protocol version with the minor bumped by one and the patch reset to zero.
    function _nextMinorAfterGenesis() internal view returns (uint256) {
        uint256 genesisVersion = ChainCreationParamsLib
            .getChainCreationParams(Utils.genesisConfigPath())
            .latestProtocolVersion;
        (uint32 major, uint32 minor, ) = SemVer.unpackSemVer(uint96(genesisVersion));
        return SemVer.packSemVer(major, minor + 1, 0);
    }

    function _snapshotExpectedZKsyncOSUpgradeTxHash() private {
        Diamond.DiamondCutData memory cut = abi.decode(
            ctmUpgrade.getChainUpgradeDiamondCutData(),
            (Diamond.DiamondCutData)
        );
        // The cut's initializer may be a release-specific subclass of the CTM default (`DefaultUpgradeZKsyncOS`),
        // so it is checked by what it does: it must be deployed and record the rewritten transaction below.
        assertGt(cut.initAddress.code.length, 0, "Per-chain upgrade initializer not deployed");

        ProposedUpgrade memory proposedUpgrade = abi.decode(cut.initCalldata.slice(4), (ProposedUpgrade));
        bytes32 placeholderHash = keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx));
        proposedUpgrade.l2ProtocolUpgradeTx.data = DefaultUpgradeZKsyncOS(cut.initAddress).getL2UpgradeTxData(
            address(addresses.bridgehub),
            eraZKChainId,
            proposedUpgrade.l2ProtocolUpgradeTx.data
        );
        _expectedRewrittenUpgradeTxHash = keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx));
        assertNotEq(_expectedRewrittenUpgradeTxHash, placeholderHash, "OS rewrite was a no-op");
    }

    /// @dev The genesis fixture deploys a testnet verifier; the production-verifier variant
    /// overrides this together with the ecosystem mutation in `setupUpgrade`.
    function _expectTestnetEcosystem() internal pure virtual returns (bool) {
        return true;
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
        console.log("setUp: Pending admin accepted");
        ECOSYSTEM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml";
        ECOSYSTEM_OUTPUT = "/script-out/foundry-upgrade/local-core.toml";
        CTM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm.toml";
        CTM_OUTPUT = "/script-out/foundry-upgrade/local-ctm.toml";
        CHAIN_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-zk-chain-era.toml";
        CHAIN_OUTPUT = "/script-out/foundry-upgrade/local-gateway.toml";
        console.log("setUp: Paths configured");
        setupUpgrade();
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

    function test_DefaultUpgradeZKsyncOS_RejectsEraCTM() public {
        address ctm = ctmUpgrade.getCTMAddress();
        uint256 protocolVersion = IChainTypeManager(ctm).protocolVersion();
        // Isolate the source-VM precondition; the fixture otherwise uses the real OS upgrade flow.
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.isZKsyncOS, ()), abi.encode(false));

        ChainCreationParamsConfig memory chainCreationParams;
        DefaultCTMUpgrade.PermanentCTMConfig memory permanentConfig;
        permanentConfig.ctmProxy = ctm;
        vm.expectRevert(bytes("CTM is not ZKsync OS"));
        ctmUpgrade.initializeConfig(chainCreationParams, permanentConfig, address(0));

        assertEq(IChainTypeManager(ctm).protocolVersion(), protocolVersion);
        assertEq(ctmUpgrade.getCTMAddress(), ctm);
    }

    function test_DefaultUpgradeZKsyncOS_Local() public view {
        // Heavy execution and event assertions live in setUp -> internalTest()
        // (RAM constraint). This body validates persisted state outcomes.
        address ctm = ctmUpgrade.getCTMAddress();
        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;

        // Protocol version bumps to the target set in `afterInitHook` (genesis minor + 1).
        assertEq(IChainTypeManager(ctm).protocolVersion(), _expectedNewVersion, "CTM protocolVersion not bumped");
        assertEq(IGetters(_eraDiamond).getProtocolVersion(), _expectedNewVersion, "Existing chain not upgraded");
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
        address newVerifier = IChainTypeManager(ctm).protocolVersionVerifier(_expectedNewVersion);
        assertEq(newVerifier, _expectedNewVerifier, "Stored verifier differs from the emitted one");
        assertEq(
            newVerifier,
            ctmUpgrade.getAddresses().stateTransition.verifiers.verifier,
            "Registered verifier differs from the one the script deployed"
        );
        // DefaultCTMUpgrade.initializeConfig must resolve the verifier kind from the ecosystem's
        // deployed verifier and install a matching one for the new version; the production-verifier
        // variant below flips the expectation.
        assertEq(ctmUpgrade.getTestnetVerifier(), _expectTestnetEcosystem(), "Script resolved the wrong verifier kind");
        assertEq(
            IZKsyncOSVerifier(newVerifier).isTestnetVerifier(),
            _expectTestnetEcosystem(),
            "New version registered with the wrong verifier kind"
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

        // The interop-handler wiring every upgraded ecosystem has to end up with. This fixture starts from
        // current contracts, so it is already wired and the default upgrade emits no wiring calls: these
        // assertions pin the invariant. Discovery of the wired handler is covered by
        // `AddressIntrospectorBridges.t.sol`.
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

/// @notice The same end-to-end upgrade against an ecosystem whose current verifier is a production
/// one: `DefaultCTMUpgrade.initializeConfig` must resolve testnetVerifier=false and the upgrade
/// must install a production verifier for the new version. Guards against the resolution being
/// hardcoded or ignored, which the testnet fixture alone cannot detect.
contract UpgradeIntegrationTestLocalProductionVerifier is UpgradeIntegrationTestLocal {
    function _expectTestnetEcosystem() internal pure override returns (bool) {
        return false;
    }

    function setupUpgrade() public override {
        // The genesis fixture registers a testnet verifier; swap in a production one via the CTM
        // owner before the upgrade scripts read it.
        ChainTypeManager ctm_ = ChainTypeManager(address(addresses.chainTypeManager));
        address productionVerifier = address(new ZKsyncOSVerifier(IVerifier(address(0))));
        uint256 currentVersion = ctm_.protocolVersion();
        address ctmOwner = ctm_.owner();
        vm.prank(ctmOwner);
        ctm_.setProtocolVersionVerifier(currentVersion, productionVerifier);
        super.setupUpgrade();
    }
}
