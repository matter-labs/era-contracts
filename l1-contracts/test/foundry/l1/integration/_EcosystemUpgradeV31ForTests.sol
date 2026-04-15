// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EcosystemUpgrade_v31} from "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultCoreUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {CoreUpgrade_v31} from "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
import {EcosystemUpgradeParams} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";
import {stdToml} from "forge-std/StdToml.sol";

contract CTMUpgradeV31ForTests is CTMUpgrade_v31 {
    function prepareCTMUpgrade() public override {
        setSkipFactoryDepsCheck_TestOnly(true);
        super.prepareCTMUpgrade();
    }

    /// @dev Skip loading zkout bytecodes to avoid MemoryOOG in anvil tests.
    /// Factory deps are not needed since we skip the check and bytecodes are
    /// already available on L2 via anvil_setCode.
    function publishBytecodes() public override {
        // no-op: avoids loading large zkout files into EVM memory
    }

    /// @dev Skip serializing deployed_addresses/state_transition/etc. to TOML.
    /// The accumulated JSON strings from vm.serializeAddress/vm.serializeString blow
    /// forge's default 128MB EVM memory. The test only needs chain_upgrade_diamond_cut.
    /// We still need to create the file so that later `vm.writeToml(section)` calls from
    /// `prepareDefaultGovernanceCalls()` (e.g. for `.governance_calls`) succeed — the
    /// sectioned form requires the target file to already exist.
    function saveOutput(string memory outputPath) internal override {
        // Write a minimal placeholder TOML so the sectioned writes in
        // `prepareDefaultGovernanceCalls` find an existing file.
        vm.writeToml(vm.serializeString("ctm_output_placeholder", "kind", "test"), outputPath);
    }
}

/// @dev CoreUpgrade that skips updateContractConnections() on re-run.
/// Used in step2() where we only need to re-populate deployed addresses
/// (create2 deploys are idempotent) without re-running side effects
/// like setAddresses() and transferOwnership() that already happened in step1().
contract CoreUpgradeV31Idempotent is CoreUpgrade_v31 {
    function deployNewEcosystemContractsL1() public virtual override {
        super.deployNewEcosystemContractsL1NoConnections();
    }
}

contract EcosystemUpgradeV31ForTests is EcosystemUpgrade_v31 {
    using stdToml for string;
    bool private _useIdempotentCore;

    /// @dev Skip state_transition/upgrade_addresses TOML serialization to avoid OOM.
    /// These optional sections accumulate huge JSON strings that blow the default 128MB limit.
    /// Only the chain_upgrade_diamond_cut and state_transition.default_upgrade_addr are needed
    /// by the test harness (the latter is read by the runner to relay L2 upgrade txs).
    function saveCombinedOutput() internal override {
        bytes memory upgradeCutData = ctmUpgrade.getChainUpgradeDiamondCutData();
        address defaultUpgradeAddr = ctmUpgrade.getAddresses().stateTransition.defaultUpgrade;

        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            defaultUpgradeAddr
        );

        vm.serializeBytes("root", "chain_upgrade_diamond_cut", upgradeCutData);
        string memory toml = vm.serializeString("root", "state_transition", stateTransition);
        vm.writeToml(toml, ecosystemOutputPath);
    }

    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgradeV31ForTests();
    }

    function createCoreUpgrade() internal override returns (DefaultCoreUpgrade) {
        if (_useIdempotentCore) {
            return new CoreUpgradeV31Idempotent();
        }
        return new CoreUpgrade_v31();
    }

    /// @notice Build EcosystemUpgradeParams from env vars and TOML config files.
    function _buildParams() private returns (EcosystemUpgradeParams memory) {
        string memory permanentValuesPath = vm.envString("PERMANENT_VALUES_INPUT_OVERRIDE");
        string memory upgradeInputPath = vm.envString("UPGRADE_INPUT_OVERRIDE");
        string memory ecosystemOutputPath = vm.envString("UPGRADE_ECOSYSTEM_OUTPUT_OVERRIDE");

        string memory root = vm.projectRoot();
        string memory pvToml = vm.readFile(string.concat(root, permanentValuesPath));

        address bridgehubProxy = pvToml.readAddress("$.core_contracts.bridgehub_proxy_addr");
        address ctmProxy = pvToml.readAddress("$.ctm_contracts.ctm_proxy_addr");
        address bytecodesSupplier = pvToml.readAddress("$.ctm_contracts.l1_bytecodes_supplier_addr");
        address rollupDAManager = pvToml.keyExists("$.ctm_contracts.rollup_da_manager")
            ? pvToml.readAddress("$.ctm_contracts.rollup_da_manager")
            : address(0);
        bool isZKsyncOS = pvToml.readBool("$.is_zk_sync_os");
        bytes32 create2FactorySalt = pvToml.readBytes32("$.permanent_contracts.create2_factory_salt");
        // The ZK token asset ID is passed to `InteropCenter.initL2`. It is optional — chains
        // upgrading from a pre-v31 version that don't have a ZK token on L1 yet can omit it.
        bytes32 zkTokenAssetId = pvToml.keyExists("$.zk_token_asset_id")
            ? pvToml.readBytes32("$.zk_token_asset_id")
            : bytes32(0);

        // Read the upgrade input TOML to get the owner/governance address
        string memory upgradeToml = vm.readFile(string.concat(root, upgradeInputPath));
        address governance = upgradeToml.readAddress("$.owner_address");

        return
            EcosystemUpgradeParams({
                bridgehubProxyAddress: bridgehubProxy,
                ctmProxy: ctmProxy,
                bytecodesSupplier: bytecodesSupplier,
                rollupDAManager: rollupDAManager,
                isZKsyncOS: isZKsyncOS,
                create2FactorySalt: create2FactorySalt,
                upgradeInputPath: upgradeInputPath,
                ecosystemOutputPath: ecosystemOutputPath,
                governance: governance,
                zkTokenAssetId: zkTokenAssetId
            });
    }

    /// @notice Step 1: Deploy core L1 ecosystem contracts + configure connections.
    /// @dev Produces ~12 transactions. Call step2() afterward.
    function step1() public {
        initializeWithArgs(_buildParams());
        coreUpgrade.prepareEcosystemUpgrade();
    }

    /// @notice Step 2: Re-populate core addresses (idempotent), deploy CTM, generate diamond
    /// cut, and prepare all governance calls — everything after step1 in a single forge
    /// invocation.
    /// @dev Uses CoreUpgradeV31Idempotent to skip setAddresses/transferOwnership side effects
    /// that already ran in step1. Must run in the same forge process as the diamond-cut
    /// generation because several pieces of state (e.g. state-transition facet addresses,
    /// fixed force deployments data, asset tracker proxy, diamond-cut data) are held only
    /// in-memory and cannot be round-tripped through TOML reliably — in particular, MailboxFacet's
    /// constructor depends on `chainAssetHandler`, which is populated by the core upgrade, so a
    /// fresh forge process cannot recompute its create2 address without redoing the core flow.
    function step2() public {
        _useIdempotentCore = true;
        initializeWithArgs(_buildParams());
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    /// @notice Stage 3: Post-governance token migration. Reads bridgehub from env.
    function stage3() public {
        EcosystemUpgradeParams memory params = _buildParams();
        stage3(params.bridgehubProxyAddress);
    }
}
