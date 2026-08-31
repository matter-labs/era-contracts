// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {CTMUpgrade_v34} from "../../../../deploy-scripts/upgrade/v34/CTMUpgrade_v34.s.sol";
import {CoreUpgrade_v34} from "../../../../deploy-scripts/upgrade/v34/CoreUpgrade_v34.s.sol";
import {DefaultCoreUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultChainUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
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
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {LegacyTestAdminFacet} from "contracts/dev-contracts/test/LegacyTestAdminFacet.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IAdminV31} from "../../../../deploy-scripts/utils/UpgradeChainCall.sol";
import {Utils as DeployScriptUtils} from "../../../../deploy-scripts/utils/Utils.sol";

/// @notice Test-only v34 CTM upgrade with the same MemoryOOG mocks as the v32 local harness
///         (the heavy JSON/zkout reads live on the shared base). The bootstrap flow itself —
///         the migration deploy, the four-call stage-1 leg, the legacy cut-taking commit — runs
///         UNMOCKED: that is what this file exists to test.
contract CTMUpgrade_v34_Test is CTMUpgrade_v34 {
    /// @dev The shared local fixture is Era-flavored, but the release's real engine
    ///      (`DefaultUpgradeZKsyncOS` + the `L2V34Upgrade` L2 leg) is ZKsyncOS-only. This
    ///      fixture asserts the L1 side only and never relays an L2 leg, so it runs the plain
    ///      `DefaultUpgrade`; the real engine is exercised by the anvil bootstrap pipeline.
    function deployUsedUpgradeContract() internal override returns (address) {
        return deploySimpleContract("DefaultUpgrade", false);
    }

    /// @notice Return a dummy bytecode hash instead of reading huge JSON files.
    function getL2BytecodeHash(string memory /* contractName */) public view override returns (bytes32) {
        return bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001));
    }

    /// @notice Skip bytecode publishing (reads large JSON files).
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
contract CoreUpgrade_v34_Test is CoreUpgrade_v34 {
    function prepareVersionSpecificStage1GovernanceCallsL1() public override returns (Call[] memory calls) {
        console.log("Test mode: Skipping version-specific stage-1 governance calls");
        calls = new Call[](0);
    }
}

/// @notice Chain leg of the bootstrap edge: the local baseline chain runs the CURRENT
///         (cut-READING) Admin facet, but the bootstrap commits the legacy cut-taking edge —
///         `upgradeTransition` stays zero for the departing version. The harness pre-installs
///         `LegacyTestAdminFacet` (the same dance the anvil bootstrap stage does), so the chain
///         crosses by HANDING the committed cut through the legacy 3-arg entrypoint, exactly
///         like production pre-v34 chains will.
contract ChainUpgrade_v34_Test is DefaultChainUpgrade {
    function upgradeChain(Diamond.DiamondCutData memory diamondCutData) public override {
        bytes memory callData = abi.encodeCall(
            IAdminV31.upgradeChainFromVersion,
            (config.chainDiamondProxyAddress, config.oldProtocolVersion, diamondCutData)
        );
        DeployScriptUtils.adminExecute(
            IZKChain(config.chainDiamondProxyAddress).getAdmin(),
            address(0),
            config.chainDiamondProxyAddress,
            callData,
            0
        );
    }
}

/// @notice Local (non-fork) test of the v34 BOOTSTRAP edge through the real prepare pipeline:
///         a fresh ecosystem + Era chain at the baseline version, `CTMUpgrade_v34` deploying
///         the executor + `RegistryBootstrapMigration`, and the collapsed four-call stage-1 leg
///         (nominate the CTM, hand over its ProxyAdmin, `migrate()`, `acceptCTMOwnership()`)
///         performing the whole edge. Complements the anvil two-stage test: same flow, but
///         driven end to end by the production prepare script.
/// @dev Heavy execution + event assertions run in `setUp -> internalTest()` (RAM constraint);
///      the body checks persisted state — the version bump, the authority handover to the
///      bound executor, and the legacy commit shape.
contract UpgradeIntegrationTest_v34_Local is
    UpgradeIntegrationTestBase,
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer
{
    using stdToml for string;

    function createCoreUpgrade() internal override returns (DefaultCoreUpgrade) {
        return new CoreUpgrade_v34_Test();
    }

    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgrade_v34_Test();
    }

    function createChainUpgrade() internal override returns (DefaultChainUpgrade) {
        return new ChainUpgrade_v34_Test();
    }

    /// @notice Bump the CTM's new protocol version from the upgrade input TOML so the local
    ///         baseline fixture exercises a real version transition.
    function afterInitHook() internal override {
        string memory root = vm.projectRoot();
        string memory upgradeToml = vm.readFile(string.concat(root, ECOSYSTEM_UPGRADE_INPUT));
        uint256 newProtocolVersion = upgradeToml.readUint("$.contracts.new_protocol_version");
        ctmUpgrade.setNewProtocolVersion(newProtocolVersion);
    }

    /// @dev Installs the pre-v34 cut-taking entrypoint on the baseline chain through the CTM
    ///      owner's `executeUpgrade` — the production path for owner-forced cuts — BEFORE the
    ///      CTM is handed to the migration. See {ChainUpgrade_v34_Test}.
    function _installLegacyCutTakingFacet() private {
        LegacyTestAdminFacet legacyFacet = new LegacyTestAdminFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = LegacyTestAdminFacet.upgradeChainFromVersion.selector;
        Diamond.FacetCut[] memory cuts = new Diamond.FacetCut[](1);
        cuts[0] = Diamond.FacetCut({
            facet: address(legacyFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });
        Diamond.DiamondCutData memory addCut = Diamond.DiamondCutData({
            facetCuts: cuts,
            initAddress: address(0),
            initCalldata: hex""
        });

        address ctm = ctmUpgrade.getCTMAddress();
        vm.prank(Ownable(ctm).owner());
        IChainTypeManager(ctm).executeUpgrade(chainId, addCut);
    }

    function setUp() public {
        console.log("setUp: Starting");
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        chainId = eraZKChainId;
        acceptPendingAdmin();

        ECOSYSTEM_UPGRADE_INPUT = "/upgrade-envs/foundry-upgrade.toml";
        ECOSYSTEM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml";
        ECOSYSTEM_OUTPUT = "/script-out/foundry-upgrade/local-v34-core-out.toml";
        CTM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm.toml";
        CTM_OUTPUT = "/script-out/foundry-upgrade/local-v34-ctm.toml";
        CORE_OUTPUT = "/script-out/foundry-upgrade/local-v34-core.toml";
        console.log("setUp: Paths configured");
        setupUpgrade(true);
        console.log("setUp: Upgrade setup complete");

        _installLegacyCutTakingFacet();
        console.log("setUp: Legacy cut-taking facet installed");

        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        bytes32 eraBaseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(eraZKChainId);
        _expectedBaseTokenAssetId = eraBaseTokenAssetId;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(eraBaseTokenAssetId));

        internalTest();
        console.log("setUp: Internal test complete");
    }

    function test_v34BootstrapUpgrade_Local() public {
        CTMUpgrade_v34_Test v34 = CTMUpgrade_v34_Test(address(ctmUpgrade));
        address ctm = ctmUpgrade.getCTMAddress();

        // Protocol version bumps, on the CTM and on the chain that crossed via the legacy leg.
        assertEq(IChainTypeManager(ctm).protocolVersion(), _expectedNewVersion, "CTM protocolVersion not bumped");
        assertEq(IGetters(_eraDiamond).getProtocolVersion(), _expectedNewVersion, "Era chain not upgraded");

        // The edge is one-shot and spent.
        assertTrue(v34.bootstrapMigration().executed(), "migration must be spent");

        // The WHOLE CTM domain landed under the bound executor: CTM ownership (completed by
        // acceptCTMOwnership in the same stage) and the CTM-domain ProxyAdmin.
        address executor = address(v34.ctmUpgradeExecutor());
        assertEq(Ownable(ctm).owner(), executor, "CTM must be owned by the executor");
        assertEq(
            Ownable(DeployScriptUtils.getProxyAdminAddress(ctm)).owner(),
            executor,
            "CTM ProxyAdmin must be owned by the executor"
        );

        // The bootstrap commits the LEGACY cut-taking edge: the deprecated hash is written for
        // the departing version and no transition is registered (internalTest asserted the
        // matching event shape).
        assertTrue(_expectedUpgradeCutHash != bytes32(0), "bootstrap must commit a legacy cut hash");
        assertEq(
            IChainTypeManager(ctm).upgradeTransition(ctmUpgrade.getOldProtocolVersion()),
            address(0),
            "the bootstrap edge must not register a transition"
        );

        // The genesis release is pinned as `currentRelease` (re-pointed to the release this
        // prepare run deployed) with the codehash anchor intact.
        address release = IChainTypeManager(ctm).currentRelease();
        assertEq(release, v34.getAddresses().stateTransition.currentRelease, "release must be the pipeline's");
        assertEq(IChainTypeManager(ctm).releaseCodehash(), release.codehash, "anchor must cover the pinned release");

        // New chain created AFTER the edge geneses from the pinned release at the new version.
        assertTrue(_newChainDiamond != address(0), "new chain not registered");
        assertEq(IGetters(_newChainDiamond).getProtocolVersion(), _expectedNewVersion, "new chain wrong version");
    }
}
