// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IEraMultiProofVerifier} from "contracts/state-transition/chain-interfaces/IEraMultiProofVerifier.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {EraMultiProofVerifier} from "contracts/state-transition/verifiers/EraMultiProofVerifier.sol";

import {Utils} from "../../utils/Utils.sol";
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
/// or read from the v34 genesis. `prepareCTMUpgrade` deploys, through CREATE2 with the input's salt, what
/// `deployNewCTMContracts` lists below plus the six facets and `DiamondInit`. Output and test calls are the base's.
///
/// The L2 upgrade transaction is v33's: `ContractDeployer.forceDeployOnAddresses` of the 31 system contracts, the
/// same for every chain.
///
/// `prepare` broadcasts only the deployments and the factory-dep publication, both permissionless, and writes
/// everything else to the output TOML.
// solhint-disable-next-line contract-name-capwords
contract CTMUpgrade_v34Era is Script, DefaultCTMUpgrade {
    using stdToml for string;

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
        // v34's verifier has no PLONK verifier; introspection found v0.33.0's.
        ctmAddresses.stateTransition.verifiers.verifierPlonk = address(0);
        _checkLiveState();

        // Deploys, publishes the factory deps and writes the output; the calls below add their tables to it.
        prepareCTMUpgrade();
        prepareDefaultGovernanceCalls();
        prepareDefaultCTMAdminCalls();
        prepareDefaultTestUpgradeCalls();
        console.log("v34: output written to", upgradeConfig.outputPath);
    }

    // ======================== Live-state checks ========================

    /// @dev Fail before deploying anything if the CTM is not an Era CTM one minor below the genesis.
    function _checkLiveState() internal view {
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
                IEraMultiProofVerifier(ctm.protocolVersionVerifier(getOldProtocolVersion())).IS_TESTNET_VERIFIER(),
                "v34: old verifier is not a testnet one"
            );
        }
    }

    // ======================== Deployments ========================

    /// @dev The timer and stage validator (base), then what v34 changes besides the facets and `DiamondInit`, which
    ///      `prepareCTMUpgrade` deploys after the factory deps.
    function deployNewCTMContracts() public override {
        super.deployNewCTMContracts();
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        // EraVerifierFflonk, AirbenderVerifierPlonk and the multi-proof verifier over both.
        config.airbenderVerifier = true;
        deployVerifiers();
        _checkVerificationKeys();
        deployEIP7702Checker();
        (, string memory ctmName) = DeployCTML1OrGateway.resolve(false, CTMContract.ChainTypeManager);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmName, false);
        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier", false);
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

    /// @dev Re-pause before the check: an emergency execution unfreezes, which unpauses migrations.
    function prepareCheckMigrationsPausedCalls() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](2);
        allCalls[0] = preparePauseGatewayMigrationsCall();
        allCalls[1] = super.prepareCheckMigrationsPausedCalls();
        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @dev Unpause first, as testnet3's stage-2 proposal does. Once that proposal no longer fixes the order, the
    ///      unpause moves into `prepareVersionSpecificStage2GovernanceCallsL1`.
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

    // ======================== Output ========================

    /// @dev What the base `saveOutput` leaves out: the Airbender verifier.
    function saveOutputVersionSpecific() internal override {
        vm.writeToml(
            vm.toString(ctmAddresses.stateTransition.verifiers.airbenderVerifierPlonk),
            upgradeConfig.outputPath,
            ".state_transition.airbender_verifier_addr"
        );
    }
}
