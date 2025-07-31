// // SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {PrepareL1L2TransactionParams, StateTransitionDeployedAddresses, Utils, FacetCut} from "../Utils.sol";
import {IBridgehub, L2TransactionRequestDirect} from "contracts/bridgehub/IBridgehub.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {L1VerifierFflonk} from "contracts/state-transition/verifiers/L1VerifierFflonk.sol";
import {L1VerifierPlonk} from "contracts/state-transition/verifiers/L1VerifierPlonk.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {GatewayUpgrade, GatewayUpgradeEncodedInput} from "contracts/upgrades/GatewayUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {AddressHasNoCode} from "../ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
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
import {L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
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

import {DeployL1Script} from "../DeployL1.s.sol";

import {DefaultEcosystemUpgrade} from "../upgrade/DefaultEcosystemUpgrade.s.sol";

import {SemVer} from "../../contracts/common/libraries/SemVer.sol";

/// @notice Script used for v29 upgrade flow
contract EcosystemUpgrade_v28_1 is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    struct PreviousUpgradeData {
        // Diamond.DiamondCutData upgradeCut;
        bytes upgradeCutData;
        uint256 previousProtocolVersion;
    }

    PreviousUpgradeData previousUpgradeData;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(
            vm.envString("V28_1_UPGRADE_ECOSYSTEM_INPUT"),
            vm.envString("V28_1_UPGRADE_ECOSYSTEM_OUTPUT")
        );
        initializePreviousUpgradeFile();
        initializeOther( 
            vm.envString("V28_1_UPGRADE_ECOSYSTEM_INPUT"),
            vm.envString("V28_1_UPGRADE_ECOSYSTEM_OUTPUT")
        );
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
    }

    function deployGWContracts() public virtual {
        // initialize(
        //     vm.envString("V28_1_UPGRADE_ECOSYSTEM_INPUT"),
        //     vm.envString("V28_1_UPGRADE_ECOSYSTEM_OUTPUT")
        // );

        //  we need to run GW contract deployment from another script directly against the GW due to the tx filterer.
    }


    function publishBytecodes() public virtual override {
        upgradeConfig.factoryDepsPublished = true;
        /// GW contract deployment and publishing is done manually.
    }

    function initializePreviousUpgradeFile() public virtual {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/upgrade-envs/v0.28.1-patch/output_v28_patched/stage/v28-ecosystem.toml");
        string memory toml = vm.readFile(path);
        bytes memory patchedDiamondCut =  toml.readBytes("$.chain_upgrade_diamond_cut");
        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            patchedDiamondCut,
            (Diamond.DiamondCutData)
        );
        previousUpgradeData.upgradeCutData = abi.encode(upgradeCut);

        /// kl todo load properly from file.
        uint256 v27 = SemVer.packSemVer(0, 27, 0);
        previousUpgradeData.previousProtocolVersion = v27;
    }

    function initializeOther(string memory newConfigPath, string memory _outputPath) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);

        string memory toml = vm.readFile(newConfigPath);
        gatewayConfig.gatewayStateTransition.verifier = toml.readAddress("$.gateway.gateway_state_transition.verifier");
    }

    function deployNewEcosystemContractsL1() public override {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();

        deployVerifiers();
        deployUpgradeStageValidator();

        (addresses.stateTransition.defaultUpgrade) = deployUsedUpgradeContract();
        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer", false);
        upgradeConfig.ecosystemContractsDeployed = true;
    }


    function deployNewEcosystemContractsGW() public virtual override {
        require(upgradeConfig.initialized, "Not initialized");

    }

    
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            previousUpgradeData.upgradeCutData,
            (Diamond.DiamondCutData)
        );

        Call memory ctmCall = Call({
            target: addresses.stateTransition.chainTypeManagerProxy,
            data: abi.encodeCall(
                ChainTypeManager.setUpgradeDiamondCut,
                (upgradeCut, previousUpgradeData.previousProtocolVersion)
            ),
            value: 0
        });

        calls = new Call[](1);
        calls[0] = ctmCall;
        return calls;
    }

    function prepareVersionSpecificStage1GovernanceCallsGW(
        uint256 priorityTxsL2GasLimit,
        uint256 maxExpectedL1GasPrice
    ) public virtual override  returns (Call[] memory calls) {
        /// note check that v27 points to v28 and there is no v27.1 intermediate.
        uint256 v27 = SemVer.packSemVer(0, 27, 0);

        bytes memory l2Calldata = abi.encodeCall(
            ChainTypeManager.setUpgradeDiamondCut,
            (emptyDiamondCut(), v27)
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            priorityTxsL2GasLimit,
            maxExpectedL1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
        // kl todo should we set the deadline on GW? In practice,
        // we should not migrated chains there. 
    }

    function emptyDiamondCut() public virtual returns (Diamond.DiamondCutData memory cutData) {
        Diamond.FacetCut[] memory emptyArray;
        cutData = Diamond.DiamondCutData({
            facetCuts: emptyArray,
            initAddress: address(0),
            initCalldata: new bytes(0)
        });
    }

    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (FacetCut[] memory facetCuts) {
        facetCuts = new FacetCut[](0);
        return facetCuts;
    }

    function getProposedUpgrade(
        StateTransitionDeployedAddresses memory stateTransition
    ) public override returns (ProposedUpgrade memory proposedUpgrade) {
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        IZKChain diamondProxy = IZKChain(bridgehub.getZKChain(config.eraChainId));

        console.log("Diamond proxy address: %s", address(diamondProxy));
        (uint32 major, uint32 minor, uint32 patch) = diamondProxy.getSemverProtocolVersion();
        console.log("Current protocol version: %s.%s.%s", major, minor, patch);
        uint256 oldVersion = SemVer.packSemVer(major, minor, patch);
        uint256 newVersion = SemVer.packSemVer(major, minor, patch + 1);

        proposedUpgrade = ProposedUpgrade({
            l2ProtocolUpgradeTx: _composeEmptyUpgradeTx(),
            bootloaderHash: bytes32(0),
            defaultAccountHash: bytes32(0),
            evmEmulatorHash: bytes32(0),
            verifier: stateTransition.verifier,
            verifierParams: VerifierParams({
                recursionNodeLevelVkHash: bytes32(0),
                recursionLeafLevelVkHash: bytes32(0),
                recursionCircuitsSetVksHash: bytes32(0)
            }),
            l1ContractsUpgradeCalldata: new bytes(0),
            postUpgradeCalldata: new bytes(0),
            upgradeTimestamp: 0,
            newProtocolVersion: newVersion
        });
    }

    /// @notice Build empty L1 -> L2 upgrade tx
    function _composeEmptyUpgradeTx() internal virtual returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransaction({
            txType: 0,
            from: uint256(0),
            to: uint256(0),
            gasLimit: 0,
            gasPerPubdataByteLimit: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymaster: uint256(uint160(address(0))),
            nonce: 0,
            value: 0,
            reserved: [uint256(0), uint256(0), uint256(0), uint256(0)],
            data: new bytes(0),
            signature: new bytes(0),
            factoryDeps: new uint256[](0),
            paymasterInput: new bytes(0),
            // Reserved dynamic type for the future use-case. Using it should be avoided,
            // But it is still here, just in case we want to enable some additional functionality
            reservedDynamic: new bytes(0)
        });
    }
}
