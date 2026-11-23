// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {Call} from "contracts/governance/Common.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IEraMultiProofVerifier} from "contracts/state-transition/chain-interfaces/IEraMultiProofVerifier.sol";
import {ChainCreationParams, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";

import {Utils} from "../../utils/Utils.sol";
import {DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";

/// @notice v34.1 Era: a verifier-only patch of an Era CTM on v0.34.0. The chains get a multi-proof verifier built
/// from the new prover keys in the genesis `prover` section; nothing else changes.
/// @dev Deploys, through CREATE2 with the input's salt, `EraVerifierFflonk`, `AirbenderVerifierPlonk`, the multi-proof
/// verifier over both and `DefaultUpgrade`, and broadcasts nothing else. Stage 1 registers the patch with
/// `createNewPatchUpgrade`, which builds the chain cut on chain (no facets, `DefaultUpgrade` with an empty
/// `ProposedUpgrade`) and carries the creation params forward. Each chain then gets its ServerNotifier timestamp and
/// `upgradeChainFromVersion` from `protocol_ops chain set-upgrade-timestamp` and `chain upgrade`, which read that cut
/// from the CTM; the output has no per-chain calls.
///
/// Only `DefaultCTMUpgrade`'s storage and deploy helpers are used; the base flow doesn't fit a patch (its cut, stage
/// calls, test calls and output are a minor upgrade's). The versions and the testnet flag are inputs, checked against
/// the CTM, so a run fails if live state moved since review. The creation params for the test chain come from a
/// committed output, checked against the CTM's hashes, rather than from the CTM's event logs, which pruning RPCs drop.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v34_1Era is Script, DefaultCTMUpgrade {
    using stdToml for string;

    /// @dev `createNewChain`'s `_salt` for the test chain, as in the other upgrade scripts.
    uint256 internal constant TEST_CREATE_CHAIN_SALT = 5;
    /// @dev `EraMultiProofVerifier.verificationKeyHash(uint256)`'s proof types: Boojum FFLONK and Airbender.
    uint256 internal constant BOOJUM_VK_TYPE = 0;
    uint256 internal constant AIRBENDER_VK_TYPE = 2;

    /// @notice Parsed input, see `upgrade-envs/v0.34.1-era/<env>.toml`.
    // solhint-disable-next-line gas-struct-packing
    struct PatchInput {
        address ctm;
        bool testnetVerifier;
        uint256 oldProtocolVersion;
        uint256 newProtocolVersion;
        bytes32 create2FactorySalt;
        uint256[] chainIds;
    }

    PatchInput internal patchInput;
    /// @dev The CTM's `ChainCreationParams`, ABI-encoded; checked against its stored hashes.
    bytes internal creationParams;
    address internal oldVerifier;
    bytes32 internal newBoojumVk;
    bytes32 internal newAirbenderVk;

    function prepare(string memory _permanentValuesPath, string memory _inputPath, string memory _outputPath) public {
        string memory root = vm.projectRoot();
        _loadInput(string.concat(root, _permanentValuesPath), string.concat(root, _inputPath));
        _checkLiveState();
        _initializePatchConfig();

        _deployPatchContracts();
        _checkDeployments();
        newlyGeneratedData.upgradeCutData = abi.encode(_buildUpgradeCut());

        string memory outputPath = string.concat(root, _outputPath);
        _savePatchOutput(outputPath);
        console.log("v34.1: output written to", outputPath);
    }

    // ======================== Input and live-state checks ========================

    function _loadInput(string memory _permanentValuesPath, string memory _inputPath) internal {
        string memory permanent = vm.readFile(_permanentValuesPath);
        require(!permanent.readBool("$.ctm_contracts.ctms[0].is_zk_sync_os"), "v34.1: first CTM is not Era");
        patchInput.ctm = permanent.readAddress("$.ctm_contracts.ctms[0].proxy");

        string memory toml = vm.readFile(_inputPath);
        patchInput.testnetVerifier = toml.readBool("$.testnet_verifier");
        patchInput.oldProtocolVersion = toml.readUint("$.old_protocol_version");
        patchInput.newProtocolVersion = toml.readUint("$.new_protocol_version");
        patchInput.create2FactorySalt = toml.readBytes32("$.create2_factory_salt");
        patchInput.chainIds = toml.readUintArray("$.chain_ids");

        string memory paramsToml = vm.readFile(
            string.concat(vm.projectRoot(), toml.readString("$.chain_creation_params_toml"))
        );
        creationParams = paramsToml.readBytes("$.contracts_config.new_chain_creation_params");

        // The keys the provers switch to. The genesis's version label is not checked: it depends on how mainnet
        // takes these keys.
        string memory genesis = vm.readFile(Utils.genesisConfigPath(false));
        newBoojumVk = vm.parseJsonBytes32(genesis, "$.prover.fflonk_snark_wrapper_vk_hash");
        newAirbenderVk = vm.parseJsonBytes32(genesis, "$.prover.airbender_snark_wrapper_vk_hash");
    }

    /// @dev Fail before deploying anything if the input does not describe the live CTM and chains.
    function _checkLiveState() internal {
        IChainTypeManager ctm = IChainTypeManager(patchInput.ctm);
        uint256 oldVersion = patchInput.oldProtocolVersion;
        uint256 newVersion = patchInput.newProtocolVersion;
        require(!ctm.isZKsyncOS(), "v34.1: not an Era CTM");
        require(ctm.protocolVersion() == oldVersion, "v34.1: CTM not on the old version");
        (uint32 oldMajor, uint32 oldMinor, uint32 oldPatch) = SemVer.unpackSemVer(SafeCast.toUint96(oldVersion));
        (uint32 newMajor, uint32 newMinor, uint32 newPatch) = SemVer.unpackSemVer(SafeCast.toUint96(newVersion));
        require(
            newMajor == oldMajor && newMinor == oldMinor && newPatch == oldPatch + 1,
            "v34.1: new version is not the next patch"
        );
        require(ctm.upgradeCutHash(oldVersion) == bytes32(0), "v34.1: old version already has an upgrade");
        require(patchInput.create2FactorySalt != bytes32(0), "v34.1: zero salt");

        oldVerifier = ctm.protocolVersionVerifier(oldVersion);
        require(oldVerifier != address(0), "v34.1: no verifier for the old version");
        require(
            IEraMultiProofVerifier(oldVerifier).IS_TESTNET_VERIFIER() == patchInput.testnetVerifier,
            "v34.1: testnet flag differs from the live verifier"
        );
        require(
            EraMultiProofVerifier(oldVerifier).verificationKeyHash(BOOJUM_VK_TYPE) != newBoojumVk,
            "v34.1: genesis FFLONK key is the live one"
        );
        require(
            EraMultiProofVerifier(oldVerifier).verificationKeyHash(AIRBENDER_VK_TYPE) != newAirbenderVk,
            "v34.1: genesis Airbender key is the live one"
        );

        uint256 chainCount = patchInput.chainIds.length;
        require(chainCount > 0, "v34.1: no chains");
        for (uint256 i = 0; i < chainCount; ++i) {
            address chain = ctm.getZKChain(patchInput.chainIds[i]);
            require(chain != address(0), "v34.1: chain not on the CTM");
            require(IGetters(chain).getProtocolVersion() == oldVersion, "v34.1: chain not on the old version");
            require(IGetters(chain).getVerifier() == oldVerifier, "v34.1: chain verifier is not the CTM's");
            // The patch is registered on this CTM only; a chain settling elsewhere would follow its gateway's.
            require(IGetters(chain).getSettlementLayer() == address(0), "v34.1: chain does not settle on L1");
        }

        // createNewPatchUpgrade carries these forward unchanged; the test chain is created with them.
        ChainCreationParams memory params = abi.decode(creationParams, (ChainCreationParams));
        ChainTypeManagerBase ctmBase = ChainTypeManagerBase(patchInput.ctm);
        require(
            keccak256(abi.encode(params.diamondCut)) == ctmBase.initialCutHash(),
            "v34.1: creation cut is not the CTM's"
        );
        require(
            keccak256(abi.encode(params.forceDeploymentsData)) == ctmBase.initialForceDeploymentHash(),
            "v34.1: force deployments are not the CTM's"
        );
    }

    /// @dev Sets every value the deployments and calls read.
    function _initializePatchConfig() internal {
        setCreate2Salt(patchInput.create2FactorySalt);
        config.l1ChainId = block.chainid;
        config.isZKsyncOS = false;
        config.testnetVerifier = patchInput.testnetVerifier;

        IChainTypeManager ctm = IChainTypeManager(patchInput.ctm);
        bridgehub = L1Bridgehub(ctm.BRIDGE_HUB());
        coreAddresses.bridgehub.proxies.bridgehub = address(bridgehub);
        coreAddresses.bridgehub.proxies.chainAssetHandler = bridgehub.chainAssetHandler();
        ctmAddresses.stateTransition.proxies.chainTypeManager = patchInput.ctm;
        ctmAddresses.stateTransition.proxies.serverNotifier = ctm.serverNotifierAddress();
        ctmAddresses.stateTransition.proxies.validatorTimelock = ctm.validatorTimelockPostV29();
    }

    // ======================== Deployments ========================

    /// @dev Listed here rather than through the base's `deployVerifiers()`, which for Era deploys the same three, so
    ///      the script's four broadcasts read in one place. The multi-proof verifier's constructor args are the two
    ///      verifiers deployed before it.
    function _deployPatchContracts() internal {
        ctmAddresses.stateTransition.verifiers.verifierFflonk = deploySimpleContract("EraVerifierFflonk", false);
        ctmAddresses.stateTransition.verifiers.airbenderVerifierPlonk = deploySimpleContract(
            "AirbenderVerifierPlonk",
            false
        );
        (, string memory verifierName) = DeployCTML1OrGateway.resolveChainVerifier(false, config.testnetVerifier);
        ctmAddresses.stateTransition.verifiers.verifier = deploySimpleContract(verifierName, false);
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
    }

    /// @dev `DefaultUpgrade`, not v34's `EraSettlementLayerV34Upgrade`: that one reverts unless every committed batch
    ///      is executed, while the server upgrades a chain with committed batches still waiting for new-key proofs.
    function deployUsedUpgradeContract() internal override returns (address) {
        return deploySimpleContract("DefaultUpgrade", false);
    }

    /// @dev The provers prove against the genesis keys.
    function _checkDeployments() internal view {
        address verifier = ctmAddresses.stateTransition.verifiers.verifier;
        require(
            address(IEraMultiProofVerifier(verifier).BOOJUM_VERIFIER()) ==
                ctmAddresses.stateTransition.verifiers.verifierFflonk,
            "v34.1: verifier Boojum slot"
        );
        require(
            address(IEraMultiProofVerifier(verifier).AIRBENDER_VERIFIER()) ==
                ctmAddresses.stateTransition.verifiers.airbenderVerifierPlonk,
            "v34.1: verifier Airbender slot"
        );
        require(
            IEraMultiProofVerifier(verifier).IS_TESTNET_VERIFIER() == patchInput.testnetVerifier,
            "v34.1: verifier testnet flag"
        );
        // The no-argument key is the one the node stores for the patch.
        require(EraMultiProofVerifier(verifier).verificationKeyHash() == newBoojumVk, "v34.1: verifier key");
        require(
            EraMultiProofVerifier(verifier).verificationKeyHash(BOOJUM_VK_TYPE) == newBoojumVk,
            "v34.1: Boojum key is not the genesis one"
        );
        require(
            EraMultiProofVerifier(verifier).verificationKeyHash(AIRBENDER_VK_TYPE) == newAirbenderVk,
            "v34.1: Airbender key is not the genesis one"
        );
    }

    // ======================== Upgrade data ========================

    /// @dev The cut `createNewPatchUpgrade` builds on chain; chains must pass it to `upgradeChainFromVersion`.
    function _buildUpgradeCut() internal view returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: ctmAddresses.stateTransition.defaultUpgrade,
                initCalldata: abi.encodeCall(
                    IDefaultUpgrade.upgrade,
                    (ProposedUpgradeLib.emptyProposedUpgrade(patchInput.newProtocolVersion))
                )
            });
    }

    function _upgradeCut() internal view returns (Diamond.DiamondCutData memory) {
        return abi.decode(newlyGeneratedData.upgradeCutData, (Diamond.DiamondCutData));
    }

    // ======================== Calls ========================

    function prepareStage0GovernanceCalls() public view override returns (Call[] memory calls) {
        calls = preparePauseGatewayMigrationsCall();
    }

    /// @dev Re-pauses first: every PUH unfreeze unpauses migrations (an emergency execution's included, and anyone can
    ///      call `PUH.reinforceUnfreeze()` between proposals), and `createNewPatchUpgrade` reverts unless paused.
    function prepareStage1GovernanceCalls() public view override returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = preparePauseGatewayMigrationsCall()[0];
        calls[1] = Call({
            target: patchInput.ctm,
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.createNewPatchUpgrade,
                (
                    patchInput.oldProtocolVersion,
                    // Chains still on the old version keep committing.
                    UpgradeHelperLib.getOldProtocolDeadline(),
                    patchInput.newProtocolVersion,
                    ctmAddresses.stateTransition.verifiers.verifier,
                    ctmAddresses.stateTransition.defaultUpgrade
                )
            )
        });
    }

    function prepareStage2GovernanceCalls() public view override returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: coreAddresses.bridgehub.proxies.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandlerBase.unpauseMigration, ())
        });
    }

    /// @notice The call that moves a chain from the old to the new version, sent to its diamond.
    function _upgradeChainCall(uint256 _chainId) internal view returns (Call memory) {
        address chain = IChainTypeManager(patchInput.ctm).getZKChain(_chainId);
        return
            Call({
                target: chain,
                value: 0,
                data: abi.encodeCall(
                    IAdmin.upgradeChainFromVersion,
                    (chain, patchInput.oldProtocolVersion, _upgradeCut())
                )
            });
    }

    /// @notice Test-only: `createNewChain` of a fresh Era chain on the patched CTM, from the bridgehub admin, with the
    ///         CTM's unchanged creation params.
    function _testCreateChainCall() internal view returns (Call[] memory calls) {
        ChainCreationParams memory params = abi.decode(creationParams, (ChainCreationParams));
        calls = new Call[](1);
        calls[0] = Call({
            target: address(bridgehub),
            value: 0,
            data: abi.encodeCall(
                IL1Bridgehub.createNewChain,
                (
                    ERA_TEST_CREATE_CHAIN_ID,
                    patchInput.ctm,
                    bridgehub.baseTokenAssetId(patchInput.chainIds[0]),
                    TEST_CREATE_CHAIN_SALT,
                    bridgehub.admin(),
                    abi.encode(abi.encode(params.diamondCut), params.forceDeploymentsData),
                    new bytes[](0)
                )
            )
        });
    }

    // ======================== Output ========================

    function _savePatchOutput(string memory _outputPath) internal {
        vm.serializeString("root", "contracts_config", _serializeContractsConfig());
        vm.serializeString("root", "state_transition", _serializeStateTransition());
        vm.serializeString("root", "deployed_addresses", _serializeDeployedAddresses());
        vm.serializeString("root", "contracts", _serializeCreate2());
        vm.serializeString("root", "governance_calls", _serializeGovernanceCalls());
        vm.writeToml(vm.serializeString("root", "test_upgrade_calls", _serializeTestCalls()), _outputPath);
    }

    function _serializeContractsConfig() internal returns (string memory) {
        string memory k = "contracts_config";
        address verifier = ctmAddresses.stateTransition.verifiers.verifier;
        bytes memory upgradeCutData = newlyGeneratedData.upgradeCutData;
        vm.serializeUint(k, "old_protocol_version", patchInput.oldProtocolVersion);
        vm.serializeUint(k, "new_protocol_version", patchInput.newProtocolVersion);
        // A string: 2^256 - 1 doesn't fit a TOML integer.
        vm.serializeString(k, "old_protocol_version_deadline", vm.toString(UpgradeHelperLib.getOldProtocolDeadline()));
        vm.serializeAddress(k, "chain_type_manager", patchInput.ctm);
        vm.serializeAddress(k, "old_verifier", oldVerifier);
        vm.serializeBytes32(k, "old_verifier_vk_hash", EraMultiProofVerifier(oldVerifier).verificationKeyHash());
        vm.serializeBytes32(
            k,
            "old_boojum_vk_hash",
            EraMultiProofVerifier(oldVerifier).verificationKeyHash(BOOJUM_VK_TYPE)
        );
        vm.serializeBytes32(
            k,
            "old_airbender_vk_hash",
            EraMultiProofVerifier(oldVerifier).verificationKeyHash(AIRBENDER_VK_TYPE)
        );
        vm.serializeAddress(k, "verifier", verifier);
        // The node stores the no-argument key as the patch's snark wrapper key.
        vm.serializeBytes32(k, "verifier_vk_hash", EraMultiProofVerifier(verifier).verificationKeyHash());
        vm.serializeBytes32(k, "boojum_vk_hash", EraMultiProofVerifier(verifier).verificationKeyHash(BOOJUM_VK_TYPE));
        vm.serializeBytes32(
            k,
            "airbender_vk_hash",
            EraMultiProofVerifier(verifier).verificationKeyHash(AIRBENDER_VK_TYPE)
        );
        vm.serializeBytes(k, "upgrade_cut_data", upgradeCutData);
        return vm.serializeBytes32(k, "upgrade_cut_hash", keccak256(upgradeCutData));
    }

    function _serializeStateTransition() internal returns (string memory) {
        string memory k = "state_transition";
        vm.serializeAddress(k, "chain_type_manager_proxy", patchInput.ctm);
        vm.serializeAddress(k, "verifier_addr", ctmAddresses.stateTransition.verifiers.verifier);
        vm.serializeAddress(k, "verifier_fflonk_addr", ctmAddresses.stateTransition.verifiers.verifierFflonk);
        vm.serializeAddress(
            k,
            "airbender_verifier_addr",
            ctmAddresses.stateTransition.verifiers.airbenderVerifierPlonk
        );
        return vm.serializeAddress(k, "default_upgrade_addr", ctmAddresses.stateTransition.defaultUpgrade);
    }

    function _serializeDeployedAddresses() internal returns (string memory) {
        string memory k = "deployed_addresses";
        vm.serializeAddress(k, "chain_asset_handler_addr", coreAddresses.bridgehub.proxies.chainAssetHandler);
        vm.serializeAddress(k, "server_notifier_proxy_addr", ctmAddresses.stateTransition.proxies.serverNotifier);
        return
            vm.serializeAddress(k, "validator_timelock_addr", ctmAddresses.stateTransition.proxies.validatorTimelock);
    }

    /// @dev The CREATE2 factory and the salt every deployment used.
    function _serializeCreate2() internal returns (string memory) {
        (address factory, bytes32 salt) = getCreate2FactoryParams();
        vm.serializeAddress("contracts", "create2_factory_addr", factory);
        return vm.serializeBytes32("contracts", "create2_factory_salt", salt);
    }

    function _serializeGovernanceCalls() internal returns (string memory) {
        string memory k = "governance_calls";
        vm.serializeBytes(k, "stage0_calls", abi.encode(prepareStage0GovernanceCalls()));
        vm.serializeBytes(k, "stage1_calls", abi.encode(prepareStage1GovernanceCalls()));
        return vm.serializeBytes(k, "stage2_calls", abi.encode(prepareStage2GovernanceCalls()));
    }

    /// @dev Test-only calls in the `[test_upgrade_calls]` layout the transaction simulator reads: each value is an
    ///      ABI-encoded `Call[]` sent by the matching `*_caller`.
    function _serializeTestCalls() internal returns (string memory) {
        string memory k = "test_upgrade_calls";
        Call[] memory upgradeChain = new Call[](1);
        upgradeChain[0] = _upgradeChainCall(patchInput.chainIds[0]);
        vm.serializeBytes(k, "test_create_chain_era", abi.encode(_testCreateChainCall()));
        vm.serializeAddress(k, "test_create_chain_era_caller", bridgehub.admin());
        vm.serializeBytes(k, "test_upgrade_chain_era", abi.encode(upgradeChain));
        return
            vm.serializeAddress(
                k,
                "test_upgrade_chain_era_caller",
                IChainTypeManager(patchInput.ctm).getChainAdmin(patchInput.chainIds[0])
            );
    }
}
