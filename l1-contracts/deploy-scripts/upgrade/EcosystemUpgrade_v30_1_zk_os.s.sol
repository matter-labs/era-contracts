// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {StateTransitionDeployedAddresses, Utils} from "../Utils.sol";
import {IL1Bridgehub} from "contracts/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {GatewayUpgrade, GatewayUpgradeEncodedInput} from "contracts/upgrades/GatewayUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {L1MessageRoot} from "contracts/bridgehub/L1MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1ChainAssetHandler} from "contracts/bridgehub/L1ChainAssetHandler.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {AddressHasNoCode} from "../ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {ContractsBytecodesLib} from "../ContractsBytecodesLib.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {Call} from "contracts/governance/Common.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {TransitionaryOwner} from "contracts/governance/TransitionaryOwner.sol";
import {SystemContractsProcessing} from "./SystemContractsProcessing.s.sol";
import {BytecodePublisher} from "./BytecodePublisher.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {L2WrappedBaseTokenStore} from "contracts/bridge/L2WrappedBaseTokenStore.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {Create2AndTransfer} from "../Create2AndTransfer.sol";

import {ContractsConfig, DeployedAddresses, TokensConfig} from "../DeployUtils.s.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {DefaultEcosystemUpgrade} from "../upgrade/DefaultEcosystemUpgrade.s.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1ZKsyncOSV30_1Upgrade} from "contracts/upgrades/L1ZKsyncOSV30_1Upgrade.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {L2V30TestnetSystemProxiesUpgrade} from "contracts/l2-upgrades/L2V30TestnetSystemProxiesUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

import {IComplexUpgraderZKsyncOSV29} from "contracts/state-transition/l2-deps/IComplexUpgraderZKsyncOSV29.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";

/// @notice Script used for v30 zksync os upgrade flow.
/// A few notes:
/// - This upgrade is done for zksync os only and so only CTM is upgraded.
/// - No gateway related parts are present, as zksync os does not use the gateway.
/// - Stage0 and stage2 governance calls are skipped, as zksync os governance does not control the ecosystem.
contract EcosystemUpgrade_v30_1_zk_os is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    uint256 internal sampleChainId;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        config.isZKsyncOS = true;
        initialize(vm.envString("UPGRADE_ECOSYSTEM_INPUT"), vm.envString("UPGRADE_ECOSYSTEM_OUTPUT"));

        instantiateCreate2Factory();

        // Deploy verifiers
        deployVerifiers();
        // Deploy the Upgrade contract
        (addresses.stateTransition.defaultUpgrade) = deployUsedUpgradeContract();
        console.log("Verifiers are deployed!");

        upgradeConfig.factoryDepsPublished = true;
        generateUpgradeData();
        console.log("Ecosystem upgrade prepared!");

        prepareDefaultGovernanceCalls();
        console.log("Default governance calls prepared!");
        prepareDefaultEcosystemAdminCalls();
        console.log("Default ecosystem admin calls prepared!");

        prepareDefaultTestUpgradeCalls();
        console.log("Default test upgrade calls prepared!");

        require(
            Ownable2StepUpgradeable(addresses.stateTransition.verifier).pendingOwner() == config.ownerAddress,
            "Incorrect owner of the verifier manager before transfer"
        );
    }

    function getSampleChainId() public view override returns (uint256) {
        return sampleChainId;
    }

    function initialize(string memory newConfigPath, string memory _outputPath) public override {
        string memory root = vm.projectRoot();
        string memory fullPath = string.concat(root, newConfigPath);

        string memory toml = vm.readFile(fullPath);

        sampleChainId = toml.readUint("$.zksync_os.sample_chain_id");
        
        // We want to save old facets to reuse it for setting chain params as this upgrade only changes
        // the verifier contract.
        addresses.stateTransition.adminFacet = toml.readAddress("$.state_transition.admin_facet_addr");
        addresses.stateTransition.executorFacet = toml.readAddress("$.state_transition.executor_facet_addr");
        addresses.stateTransition.mailboxFacet = toml.readAddress("$.state_transition.mailbox_facet_addr");
        addresses.stateTransition.gettersFacet = toml.readAddress("$.state_transition.getters_facet_addr");
        addresses.stateTransition.diamondInit = toml.readAddress("$.state_transition.diamond_init_addr");
        generatedData.forceDeploymentsData = toml.readBytes("$.state_transition.force_deployments_data");

        super.initialize(newConfigPath, _outputPath);
    }

    // Unlike the original one, we do not fetch the L1 da validator address
    function setAddressesBasedOnBridgehub() internal override {
        address ctm = IL1Bridgehub(addresses.bridgehub.bridgehubProxy).chainTypeManager(getSampleChainId());
        config.ownerAddress = Ownable2StepUpgradeable(ctm).owner();

        addresses.stateTransition.chainTypeManagerProxy = ctm;
        // We have to set the diamondProxy address here - as it is used by multiple constructors (for example L1Nullifier etc)
        addresses.stateTransition.diamondProxy = IL1Bridgehub(addresses.bridgehub.bridgehubProxy).getZKChain(
            getSampleChainId()
        );
        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );
        addresses.bridges.l1AssetRouterProxy = L1Bridgehub(addresses.bridgehub.bridgehubProxy).assetRouter();
        addresses.stateTransition.genesisUpgrade = address(IChainTypeManager(ctm).l1GenesisUpgrade());

        addresses.vaults.l1NativeTokenVaultProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).nativeTokenVault()
        );
        addresses.bridges.l1NullifierProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).L1_NULLIFIER()
        );
        addresses.bridges.erc20BridgeProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).legacyBridge()
        );

        addresses.bridgehub.ctmDeploymentTrackerProxy = address(
            L1Bridgehub(addresses.bridgehub.bridgehubProxy).l1CtmDeployer()
        );

        addresses.bridgehub.messageRootProxy = address(L1Bridgehub(addresses.bridgehub.bridgehubProxy).messageRoot());

        addresses.bridgehub.chainAssetHandlerProxy = address(
            L1Bridgehub(addresses.bridgehub.bridgehubProxy).chainAssetHandler()
        );

        addresses.bridges.erc20BridgeProxy = address(
            L1AssetRouter(addresses.bridges.l1AssetRouterProxy).legacyBridge()
        );
        addresses.stateTransition.serverNotifierProxy = IChainTypeManager(
            addresses.stateTransition.chainTypeManagerProxy
        ).serverNotifierAddress();

        newConfig.ecosystemAdminAddress = ChainTypeManagerBase(ctm).admin();

        addresses.stateTransition.validatorTimelock = ChainTypeManagerBase(ctm).validatorTimelockPostV29();
        require(Ownable2StepUpgradeable(ctm).owner() == config.ownerAddress, "Incorrect owner");
    }

    // Factory deps are not supported yet, so we just mark those as published.
    function publishBytecodes() public override {
        upgradeConfig.factoryDepsPublished = true;
    }

    // Unlike the original one, we skip the GW-related parts.
    function generateUpgradeData() public virtual override {
        console.log("Generated fixed force deployments data");
        newlyGeneratedData.diamondCutData = abi.encode(getChainCreationDiamondCutData(addresses.stateTransition));
        generateUpgradeCutData(addresses.stateTransition);
        upgradeConfig.upgradeCutPrepared = true;
        console.log("UpgradeCutGenerated");
        saveOutput(upgradeConfig.outputPath);
    }

    // We don't add facets as it is noop upgrade for L1 contracts
    function getUpgradeAddedFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        facetCuts = new Diamond.FacetCut[](0);
    }

    // We don't remove facets as it is noop upgrade for L1 contracts
    function getFacetCutsForDeletion() internal virtual override returns (Diamond.FacetCut[] memory facetCuts) {
        facetCuts = new Diamond.FacetCut[](0);
    }

    // Unlike the original one, we skip stage 0 and stage 2 calls.
    function prepareStage0GovernanceCalls() public override returns (Call[] memory calls) {
        // No stage 1 calls, since the zksync os governor does not control the ecosystem.
    }

    // Unlike the original one, since we do not control the main ecosystem governance,
    // we skip upgrading lots of contracts, as well as anything related to ZK Gateway.
    function prepareStage1GovernanceCalls() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](3);

        console.log("prepareStage1GovernanceCalls: prepareNewChainCreationParamsCall");
        allCalls[0] = prepareNewChainCreationParamsCall();
        console.log("prepareStage1GovernanceCalls: provideSetNewVersionUpgradeCall");
        allCalls[1] = provideSetNewVersionUpgradeCall();
        console.log("prepareStage1GovernanceCalls: acceptZKSyncOSVerifierOwnershipCalls");
        allCalls[2] = acceptZKSyncOSVerifierOwnershipCalls();

        calls = mergeCallsArray(allCalls);
    }

    // Unlike the original one, we skip stage 0 and stage 2 calls.
    function prepareStage2GovernanceCalls() public override returns (Call[] memory calls) {
        // No stage 2 calls, since the zksync os governor does not control the ecosystem.
    }

    /// Empty upgrade, just set the new protocol version
    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition
    ) public override returns (ProposedUpgrade memory proposedUpgrade) {
        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _emptyUpgradeTx(),
            // Unused in zksync os context
            bootloaderHash: bytes32(0),
            // Unused in zksync os context
            defaultAccountHash: bytes32(0),
            // Unused in zksync os context
            evmEmulatorHash: bytes32(0),
            verifier: stateTransition.verifier,
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: hex"",
            upgradeTimestamp: 0,
            newProtocolVersion: getNewProtocolVersion()
        });
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view override returns (bytes memory) {
        if (compareStrings(contractName, "L1ZKsyncOSV30_1Upgrade")) {
            if (!isZKBytecode) {
                return type(L1ZKsyncOSV30_1Upgrade).creationCode;
            } else {
                return ContractsBytecodesLib.getCreationCode("L1ZKsyncOSV30_1Upgrade", true);
            }
        }
        return super.getCreationCode(contractName, isZKBytecode);
    }

    function deployUsedUpgradeContract() internal virtual override returns (address) {
        return deploySimpleContract("L1ZKsyncOSV30_1Upgrade", false);
    }
}
