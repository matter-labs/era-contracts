// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IChainAdmin} from "contracts/governance/IChainAdmin.sol";
import {IChainAdminOwnable} from "contracts/governance/IChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IEraMultiProofVerifier} from "contracts/state-transition/chain-interfaces/IEraMultiProofVerifier.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {Bytes} from "contracts/vendor/Bytes.sol";

import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {CTMContract, DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {EraForceDeploymentsLib} from "../default-upgrade/EraForceDeploymentsLib.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";
import {UpgradeUtils} from "../default-upgrade/UpgradeUtils.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";

/// @notice v34 Era: moves an Era CTM from v0.33.0 to v0.34.0. From then on every batch needs a Boojum and an
/// Airbender proof; the release also ships the force-fail bootloader, the 15M user L1->L2 gas cap and an EVM
/// emulator fix.
/// @dev Initialized by `initializeWithArgs` from the env's permanent values; the rest is introspected from the CTM
/// or read from the v34 genesis. Deploys, through CREATE2 with the input's salt: the six facets, a fresh
/// `EraVerifierFflonk`, `AirbenderVerifierPlonk`, the multi-proof verifier over both, `EraSettlementLayerV34Upgrade`,
/// new `EraChainTypeManager` and `ServerNotifier` implementations, a `GovernanceUpgradeTimer` and an
/// `UpgradeStageValidator`. The CTM's `DiamondInit` and the facets' EIP-7702 checker are reused: neither has a
/// getter, so the input names them.
///
/// The L2 upgrade transaction is v33's: `ContractDeployer.forceDeployOnAddresses` of the 31 system contracts, the
/// same for every chain.
///
/// `prepare` broadcasts only the deployments and the factory-dep publication, both permissionless, and writes
/// everything else to the output TOML.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v34Era is Script, DefaultCTMUpgrade {
    using stdToml for string;

    /// @dev Inputs that only feed `[chain_upgrades]` and the test calls.
    uint256 internal upgradeTimestamp;
    uint256[] internal chainIds;
    /// @dev abi-encoded ChainCreationParams (structs with nested dynamic arrays cannot be copied to storage by
    ///      the legacy pipeline).
    bytes internal v34NewChainCreationParams;
    address internal v33Verifier;

    function prepare(string memory _permanentValuesPath, string memory _inputPath, string memory _outputPath) public {
        string memory root = vm.projectRoot();
        string memory permanent = vm.readFile(string.concat(root, _permanentValuesPath));
        string memory input = vm.readFile(string.concat(root, _inputPath));
        require(!permanent.readBool("$.ctm_contracts.ctms[0].is_zk_sync_os"), "v34: first CTM is not Era");
        initializeWithArgs({
            ctmProxy: permanent.readAddress("$.ctm_contracts.ctms[0].proxy"),
            bytecodesSupplier: permanent.readAddress("$.ctm_contracts.ctms[0].bytecodes_supplier"),
            isZKsyncOS: false,
            // Introspection leaves it zero; set below from the chains' AdminFacet.
            rollupDAManager: address(0),
            create2FactorySalt: input.readBytes32("$.create2_factory_salt"),
            newConfigPath: _inputPath,
            _outputPath: _outputPath,
            governance: address(0),
            zkTokenAssetId: permanent.readBytes32("$.zk_token_asset_id")
        });
        ctmAddresses.daAddresses.daContracts.rollupDAManager = IAdmin(upToDateZkChain.zkChainProxy)
            .getRollupDAManager();
        ctmAddresses.stateTransition.facets.diamondInit = input.readAddress("$.diamond_init");
        ctmAddresses.admin.eip7702Checker = input.readAddress("$.eip7702_checker");
        upgradeTimestamp = input.readUint("$.upgrade_timestamp");
        chainIds = input.readUintArray("$.chain_ids");
        v33Verifier = IChainTypeManager(newConfig.ctm).protocolVersionVerifier(getOldProtocolVersion());
        _checkLiveState(input.readBytes("$.current_chain_creation_params_event_data"));

        _deployV34Contracts();
        // Era invariant checked inside: factory deps [0..2] == genesis bootloader / AA / EVM emulator.
        publishBytecodes();
        console.log("v34: factory dependencies published");

        newlyGeneratedData.upgradeCutData = abi.encode(_buildUpgradeCut());
        getFixedForceDeploymentsData();
        v34NewChainCreationParams = abi.encode(getChainCreationParams(ctmAddresses.stateTransition));

        _saveV34Output();
        console.log("v34: output written to", upgradeConfig.outputPath);
    }

    // ======================== Live-state checks ========================

    /// @dev Fail before deploying anything if the CTM is not an Era CTM one minor below the genesis, or the inputs
    ///      the chain can't confirm by a getter don't match it.
    function _checkLiveState(bytes memory _currentChainCreationParamsEvent) internal view {
        IChainTypeManager ctm = IChainTypeManager(newConfig.ctm);
        require(!ctm.isZKsyncOS(), "v34: not an Era CTM");
        require(!UpgradeHelperLib.isPatchUpgrade(getNewProtocolVersion()), "v34: must be a minor upgrade");
        require(
            UpgradeHelperLib.getProtocolUpgradeNonce(getNewProtocolVersion()) ==
                UpgradeHelperLib.getProtocolUpgradeNonce(getOldProtocolVersion()) + 1,
            "v34: CTM not on the previous minor"
        );
        require(getGovernanceUpgradeTimerInitialDelay() != 0, "v34: no governance_upgrade_timer_initial_delay");
        // A testnet verifier accepts empty proofs: never on a chain whose verifier isn't one. v0.33.0's testnet
        // verifier has this getter; its production one doesn't, so the call reverts there.
        if (config.testnetVerifier) {
            require(
                IEraMultiProofVerifier(v33Verifier).IS_TESTNET_VERIFIER(),
                "v34: old verifier is not a testnet one"
            );
        }
        require(upgradeTimestamp != 0, "v34: zero upgrade timestamp");
        // No "immediately" (1) outside testnets: a production chain gets a real date.
        require(
            config.testnetVerifier || upgradeTimestamp > block.timestamp,
            "v34: upgrade timestamp not in the future"
        );

        // The CTM's last NewChainCreationParams event: the reused DiamondInit is its cut's.
        (, , , , Diamond.DiamondCutData memory initialCut, , , ) = abi.decode(
            _currentChainCreationParamsEvent,
            (address, bytes32, uint64, bytes32, Diamond.DiamondCutData, bytes32, bytes, bytes32)
        );
        require(keccak256(abi.encode(initialCut)) == ctm.initialCutHash(), "v34: stale creation cut");
        require(
            initialCut.initAddress == ctmAddresses.stateTransition.facets.diamondInit,
            "v34: diamond_init is not the CTM's"
        );
    }

    // ======================== Deployments ========================

    function _deployV34Contracts() internal {
        ctmAddresses.stateTransition.facets.adminFacet = deploySimpleContract("AdminFacet", false);
        ctmAddresses.stateTransition.facets.gettersFacet = deploySimpleContract("GettersFacet", false);
        ctmAddresses.stateTransition.facets.mailboxFacet = deploySimpleContract("MailboxFacet", false);
        ctmAddresses.stateTransition.facets.executorFacet = deploySimpleContract("ExecutorFacet", false);
        ctmAddresses.stateTransition.facets.migratorFacet = deploySimpleContract("MigratorFacet", false);
        ctmAddresses.stateTransition.facets.committerFacet = deploySimpleContract("CommitterFacet", false);

        ctmAddresses.stateTransition.verifiers.airbenderVerifierPlonk = deploySimpleContract(
            "AirbenderVerifierPlonk",
            false
        );
        // Before the multi-proof verifier, whose constructor arguments are read at its deployment.
        ctmAddresses.stateTransition.verifiers.verifierFflonk = deploySimpleContract("EraVerifierFflonk", false);
        (, string memory verifierName) = DeployCTML1OrGateway.resolveChainVerifier(false, config.testnetVerifier);
        ctmAddresses.stateTransition.verifiers.verifier = deploySimpleContract(verifierName, false);
        _checkVerificationKeys();

        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();

        (, string memory ctmName) = DeployCTML1OrGateway.resolve(false, CTMContract.ChainTypeManager);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmName, false);
        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier", false);

        // The validator's constructor takes getNewProtocolVersion().
        deployGovernanceUpgradeTimer();
        deployUpgradeStageValidator();
    }

    function deployUsedUpgradeContract() internal virtual override returns (address) {
        return deploySimpleContract("EraSettlementLayerV34Upgrade", false);
    }

    /// @dev The prover proves against the genesis keys.
    function _checkVerificationKeys() internal {
        EraMultiProofVerifier verifier = EraMultiProofVerifier(ctmAddresses.stateTransition.verifiers.verifier);
        string memory genesis = vm.readFile(Utils.genesisConfigPath(false));
        require(
            verifier.verificationKeyHash(0) == vm.parseJsonBytes32(genesis, "$.prover.fflonk_snark_wrapper_vk_hash"),
            "v34: Boojum VK is not the genesis one"
        );
        require(
            verifier.verificationKeyHash(2) == vm.parseJsonBytes32(genesis, "$.prover.airbender_snark_wrapper_vk_hash"),
            "v34: Airbender VK is not the genesis one"
        );
    }

    // ======================== Upgrade data ========================

    /// @dev Remove every selector chain `chainIds[0]` routes, add the six new facets, and run
    ///      `EraSettlementLayerV34Upgrade.upgrade(ProposedUpgrade)`.
    function _buildUpgradeCut() internal returns (Diamond.DiamondCutData memory) {
        return
            generateUpgradeCutData({
                _stateTransition: ctmAddresses.stateTransition,
                _chainCreationParams: config.contracts.chainCreationParams,
                _l1ChainId: config.l1ChainId,
                _ownerAddress: address(0),
                _factoryDepsResult: factoryDepsResult,
                _registeredChainIdDiamondProxy: bridgehub.getZKChain(chainIds[0])
            });
    }

    /// @notice v34 force-deploys the system contracts only, as v33: the L2 core contracts hold live storage.
    function getBaseUniversalForceDeployments(
        uint256,
        address
    ) internal view override returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory) {
        return EraForceDeploymentsLib.wrap(SystemContractsProcessing.getSystemContractsForceDeployments());
    }

    // ======================== Calls ========================

    function prepareVersionSpecificStage0GovernanceCallsL1() public view override returns (Call[] memory) {
        return preparePauseGatewayMigrationsCall();
    }

    /// @dev Re-pause first: an emergency execution unfreezes, which unpauses migrations, before running the
    ///      proposal's calls. Idempotent otherwise.
    function prepareGovernanceUpgradeTimerCheckCall() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](2);
        allCalls[0] = preparePauseGatewayMigrationsCall();
        allCalls[1] = super.prepareGovernanceUpgradeTimerCheckCall();
        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareStage2GovernanceCalls() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](3);
        allCalls[0] = new Call[](1);
        allCalls[0][0] = Call({
            target: coreAddresses.bridgehub.proxies.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
        });
        allCalls[1] = prepareCheckUpgradeIsPresent();
        allCalls[2] = prepareCheckMigrationsUnpausedCalls();
        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice The call a chain admin makes on the chain's diamond to move it from the old to the new version.
    function _v34UpgradeChainCall(uint256 _chainId) internal view returns (Call memory) {
        address chain = bridgehub.getZKChain(_chainId);
        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            newlyGeneratedData.upgradeCutData,
            (Diamond.DiamondCutData)
        );
        return
            Call({
                target: chain,
                value: 0,
                data: abi.encodeCall(IAdmin.upgradeChainFromVersion, (chain, getOldProtocolVersion(), upgradeCut))
            });
    }

    /// @notice The ChainAdmin multicall that upgrades one chain once stage 1 has executed.
    function getV34ChainUpgradeCall(uint256 _chainId) public view returns (address admin, bytes memory data) {
        admin = IChainTypeManager(newConfig.ctm).getChainAdmin(_chainId);
        Call[] memory calls = new Call[](1);
        calls[0] = _v34UpgradeChainCall(_chainId);
        data = abi.encodeCall(IChainAdmin.multicall, (calls, true));
    }

    /// @notice The two transactions `protocol_ops chain set-upgrade-timestamp` writes for an Ownable ChainAdmin,
    ///         both sent by its owner to the ChainAdmin: `setUpgradeTimestamp` called directly (it is
    ///         `onlyOwner`; keyed by the new version, read only by pre-v31 nodes), then
    ///         `ServerNotifier.setUpgradeTimestamp` through `multicall` (keyed by the chain's current version,
    ///         read by the node; it reverts until stage 1 has registered the upgrade).
    function getV34ChainTimestampCalldata(
        uint256 _chainId
    ) public view returns (bytes memory setUpgradeTimestamp, bytes memory serverNotifierTimestamp) {
        setUpgradeTimestamp = abi.encodeCall(
            IChainAdminOwnable.setUpgradeTimestamp,
            (getNewProtocolVersion(), upgradeTimestamp)
        );
        Call[] memory notifierCall = new Call[](1);
        notifierCall[0] = Call({
            target: ctmAddresses.stateTransition.proxies.serverNotifier,
            value: 0,
            data: abi.encodeCall(ServerNotifier.setUpgradeTimestamp, (_chainId, upgradeTimestamp))
        });
        serverNotifierTimestamp = abi.encodeCall(IChainAdmin.multicall, (notifierCall, true));
    }

    /// @notice Test-only: `createNewChain` of a fresh Era chain on the upgraded CTM, from the bridgehub
    ///         admin, with the v34 creation params.
    function getV34TestCreateChainCall() public view returns (address caller, bytes memory data) {
        ChainCreationParams memory newParams = abi.decode(v34NewChainCreationParams, (ChainCreationParams));
        caller = bridgehub.admin();
        data = abi.encodeCall(
            IL1Bridgehub.createNewChain,
            (
                ERA_TEST_CREATE_CHAIN_ID,
                newConfig.ctm,
                bridgehub.baseTokenAssetId(chainIds[0]),
                5,
                caller,
                abi.encode(abi.encode(newParams.diamondCut), newParams.forceDeploymentsData),
                new bytes[](0)
            )
        );
    }

    // ======================== Output ========================

    function _saveV34Output() internal {
        vm.serializeString("root", "contracts_config", _serializeContractsConfig());
        vm.serializeString("root", "state_transition", _serializeStateTransition());
        vm.serializeString("root", "deployed_addresses", _serializeDeployedAddresses());
        vm.serializeString("root", "contracts", _serializeCreate2());
        vm.serializeString("root", "governance_calls", _serializeGovernanceCalls());
        vm.serializeString("root", "chain_upgrades", _serializeChainUpgrades());
        string memory toml = vm.serializeString("root", "test_upgrade_calls", _serializeV34TestCalls());
        vm.writeToml(toml, upgradeConfig.outputPath);
        // Adds [ctm_admin_calls] to the file just written.
        prepareDefaultCTMAdminCalls();
    }

    function _serializeContractsConfig() internal returns (string memory) {
        bytes memory upgradeCutData = newlyGeneratedData.upgradeCutData;
        Diamond.DiamondCutData memory upgradeCut = abi.decode(upgradeCutData, (Diamond.DiamondCutData));
        ChainCreationParams memory newParams = abi.decode(v34NewChainCreationParams, (ChainCreationParams));
        ProposedUpgrade memory proposedUpgrade = abi.decode(Bytes.slice(upgradeCut.initCalldata, 4), (ProposedUpgrade));
        address verifier = ctmAddresses.stateTransition.verifiers.verifier;

        vm.serializeUint("contracts_config", "old_protocol_version", getOldProtocolVersion());
        vm.serializeUint("contracts_config", "new_protocol_version", getNewProtocolVersion());
        vm.serializeAddress("contracts_config", "chain_type_manager", newConfig.ctm);
        vm.serializeAddress(
            "contracts_config",
            "bytecodes_supplier",
            ctmAddresses.stateTransition.proxies.bytecodesSupplier
        );
        vm.serializeAddress("contracts_config", "verifier", verifier);
        vm.serializeAddress("contracts_config", "old_verifier", v33Verifier);
        // The no-argument VK hash the node stores as the version's snark wrapper key (Boojum FFLONK here).
        vm.serializeBytes32(
            "contracts_config",
            "verifier_vk_hash",
            EraMultiProofVerifier(verifier).verificationKeyHash()
        );
        vm.serializeBytes32("contracts_config", "old_verifier_vk_hash", IVerifier(v33Verifier).verificationKeyHash());
        vm.serializeBytes32("contracts_config", "bootloader_hash", proposedUpgrade.bootloaderHash);
        vm.serializeBytes32("contracts_config", "default_aa_hash", proposedUpgrade.defaultAccountHash);
        vm.serializeBytes32("contracts_config", "evm_emulator_hash", proposedUpgrade.evmEmulatorHash);
        vm.serializeBytes32("contracts_config", "genesis_root", newParams.genesisBatchHash);
        vm.serializeUint("contracts_config", "genesis_rollup_leaf_index", newParams.genesisIndexRepeatedStorageChanges);
        vm.serializeBytes32("contracts_config", "genesis_batch_commitment", newParams.genesisBatchCommitment);
        vm.serializeBytes32(
            "contracts_config",
            "genesis_airbender_batch_commitment",
            newParams.genesisAirbenderBatchCommitment
        );
        vm.serializeBytes32(
            "contracts_config",
            "l2_upgrade_tx_hash",
            keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx))
        );
        vm.serializeBytes32(
            "contracts_config",
            "l2_upgrade_tx_factory_deps",
            UpgradeHelperLib.factoryDepHashes(proposedUpgrade.l2ProtocolUpgradeTx)
        );
        vm.serializeBytes32("contracts_config", "upgrade_cut_hash", keccak256(upgradeCutData));
        vm.serializeBytes32("contracts_config", "new_initial_cut_hash", keccak256(abi.encode(newParams.diamondCut)));
        vm.serializeBytes32(
            "contracts_config",
            "new_force_deployments_hash",
            keccak256(abi.encode(newParams.forceDeploymentsData))
        );
        vm.serializeBytes("contracts_config", "upgrade_cut_data", upgradeCutData);
        return vm.serializeBytes("contracts_config", "new_chain_creation_params", v34NewChainCreationParams);
    }

    /// @dev Every state-transition address the upgrade deploys or reuses, under `DefaultCTMUpgrade.saveOutput`'s
    ///      keys (v31's `[ctms.era.state_transition]`).
    function _serializeStateTransition() internal returns (string memory) {
        StateTransitionDeployedAddresses memory st = ctmAddresses.stateTransition;
        vm.serializeAddress("state_transition", "admin_facet_addr", st.facets.adminFacet);
        vm.serializeAddress("state_transition", "getters_facet_addr", st.facets.gettersFacet);
        vm.serializeAddress("state_transition", "mailbox_facet_addr", st.facets.mailboxFacet);
        vm.serializeAddress("state_transition", "executor_facet_addr", st.facets.executorFacet);
        vm.serializeAddress("state_transition", "migrator_facet_addr", st.facets.migratorFacet);
        vm.serializeAddress("state_transition", "committer_facet_addr", st.facets.committerFacet);
        vm.serializeAddress("state_transition", "diamond_init_addr", st.facets.diamondInit);
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", st.genesisUpgrade);
        vm.serializeAddress("state_transition", "default_upgrade_addr", st.defaultUpgrade);
        vm.serializeAddress("state_transition", "verifier_addr", st.verifiers.verifier);
        vm.serializeAddress("state_transition", "verifier_fflonk_addr", st.verifiers.verifierFflonk);
        vm.serializeAddress("state_transition", "airbender_verifier_addr", st.verifiers.airbenderVerifierPlonk);
        vm.serializeAddress("state_transition", "chain_type_manager_proxy", st.proxies.chainTypeManager);
        vm.serializeAddress(
            "state_transition",
            "chain_type_manager_implementation_addr",
            st.implementations.chainTypeManager
        );
        vm.serializeAddress(
            "state_transition",
            "server_notifier_implementation_addr",
            st.implementations.serverNotifier
        );
        vm.serializeAddress("state_transition", "bytecodes_supplier_addr", st.proxies.bytecodesSupplier);
        vm.serializeAddress("state_transition", "permissionless_validator_addr", st.proxies.permissionlessValidator);
        return vm.serializeAddress("state_transition", "eip7702_checker_addr", ctmAddresses.admin.eip7702Checker);
    }

    /// @dev Other addresses the calls and constructors use, under the keys of `DefaultCTMUpgrade.saveOutput`
    ///      and `DeployCTM.saveOutput`.
    function _serializeDeployedAddresses() internal returns (string memory) {
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin", ctmAddresses.admin.transparentProxyAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "server_notifier_proxy_addr",
            ctmAddresses.stateTransition.proxies.serverNotifier
        );
        vm.serializeAddress("deployed_addresses", "l1_governance_upgrade_timer", upgradeAddresses.upgradeTimer);
        vm.serializeAddress("deployed_addresses", "upgrade_stage_validator", upgradeAddresses.upgradeStageValidator);
        return
            vm.serializeAddress(
                "deployed_addresses",
                "l1_rollup_da_manager",
                ctmAddresses.daAddresses.daContracts.rollupDAManager
            );
    }

    /// @dev The CREATE2 factory and the salt every deployment used, under `DeployCTM.saveOutput`'s keys.
    function _serializeCreate2() internal returns (string memory) {
        (address factory, bytes32 salt) = getCreate2FactoryParams();
        vm.serializeAddress("contracts", "create2_factory_addr", factory);
        return vm.serializeBytes32("contracts", "create2_factory_salt", salt);
    }

    function _serializeGovernanceCalls() internal returns (string memory) {
        vm.serializeBytes("governance_calls", "stage0_calls", abi.encode(prepareStage0GovernanceCalls()));
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(prepareStage1GovernanceCalls()));
        return vm.serializeBytes("governance_calls", "stage2_calls", abi.encode(prepareStage2GovernanceCalls()));
    }

    function _serializeChainUpgrades() internal returns (string memory chainUpgrades) {
        uint256 chainCount = chainIds.length;
        for (uint256 i = 0; i < chainCount; ++i) {
            string memory key = vm.toString(chainIds[i]);
            chainUpgrades = vm.serializeString("chain_upgrades", key, _serializeChainUpgrade(chainIds[i]));
        }
    }

    /// @dev Raw calldata the chain's ChainAdmin owner sends to the ChainAdmin, in this order:
    ///      `set_upgrade_timestamp_calldata` and `server_notifier_timestamp_calldata` after stage 1, then
    ///      `chain_admin_calldata` (the upgrade) once the chain is drained.
    function _serializeChainUpgrade(uint256 _chainId) internal returns (string memory) {
        string memory key = vm.toString(_chainId);
        (address admin, bytes memory upgradeCalldata) = getV34ChainUpgradeCall(_chainId);
        (bytes memory setTimestamp, bytes memory notifierTimestamp) = getV34ChainTimestampCalldata(_chainId);
        vm.serializeAddress(key, "chain", bridgehub.getZKChain(_chainId));
        vm.serializeAddress(key, "chain_admin", admin);
        vm.serializeAddress(key, "chain_admin_owner", IOwnable(admin).owner());
        vm.serializeBytes(key, "set_upgrade_timestamp_calldata", setTimestamp);
        vm.serializeBytes(key, "server_notifier_timestamp_calldata", notifierTimestamp);
        return vm.serializeBytes(key, "chain_admin_calldata", upgradeCalldata);
    }

    /// @dev Test-only calls in the `[test_upgrade_calls]` layout the transaction simulator reads: each value
    /// is an ABI-encoded `Call[]` sent by the matching `*_caller`.
    function _serializeV34TestCalls() internal returns (string memory) {
        (address createChainCaller, bytes memory createChainData) = getV34TestCreateChainCall();
        Call[] memory createChain = new Call[](1);
        createChain[0] = Call({target: address(bridgehub), value: 0, data: createChainData});
        Call[] memory upgradeChain = new Call[](1);
        upgradeChain[0] = _v34UpgradeChainCall(chainIds[0]);

        vm.serializeBytes("test_upgrade_calls", "test_create_chain_era", abi.encode(createChain));
        vm.serializeAddress("test_upgrade_calls", "test_create_chain_era_caller", createChainCaller);
        vm.serializeBytes("test_upgrade_calls", "test_upgrade_chain_era", abi.encode(upgradeChain));
        return
            vm.serializeAddress(
                "test_upgrade_calls",
                "test_upgrade_chain_era_caller",
                IChainTypeManager(newConfig.ctm).getChainAdmin(chainIds[0])
            );
    }
}
