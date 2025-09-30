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
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
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

import {DeployL1Script} from "../DeployL1.s.sol";

import {DefaultEcosystemUpgrade} from "../upgrade/DefaultEcosystemUpgrade.s.sol";

import {SemVer} from "../../contracts/common/libraries/SemVer.sol";
struct InitializeDataNewChainLegacy {
    IVerifier verifier;
    VerifierParams verifierParams;
    bytes32 l2BootloaderBytecodeHash;
    bytes32 l2DefaultAccountBytecodeHash;
    bytes32 l2EvmEmulatorBytecodeHash;
    uint256 priorityTxMaxGasLimit;
    FeeParams feeParams;
    address blobVersionedHashRetriever;
}

/// @notice Script used for v29 upgrade flow
contract EcosystemUpgrade_v28_2 is Script, DefaultEcosystemUpgrade {
    using stdToml for string;
    string ecosystem;

    struct PreviousUpgradeData {
        // Diamond.DiamondCutData upgradeCut;
        bytes upgradeCutDataL1;
        bytes upgradeCutDataGW;
        uint256 previousProtocolVersion;
        bytes chainCreationParamsL1;
        bytes chainCreationParamsGW;
    }

    PreviousUpgradeData previousUpgradeData;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(vm.envString("V28_2_UPGRADE_ECOSYSTEM_INPUT"), vm.envString("V28_2_UPGRADE_ECOSYSTEM_OUTPUT"));
        ecosystem = vm.envString("V28_2_PATCH_UPGRADE_ECOSYSTEM");
        initializeOther(vm.envString("V28_2_UPGRADE_ECOSYSTEM_INPUT"), vm.envString("V28_2_UPGRADE_ECOSYSTEM_OUTPUT"));
        deployNewEcosystemContractsL1();
        initializePreviousUpgradeFile();
        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
    }

    function deployGWContracts() public virtual {
        // initialize(
        //     vm.envString("V28_2_UPGRADE_ECOSYSTEM_INPUT"),
        //     vm.envString("V28_2_UPGRADE_ECOSYSTEM_OUTPUT")
        // );
        //  we need to run GW contract deployment from another script directly against the GW due to the tx filterer.
    }

    function publishBytecodes() public virtual override {
        upgradeConfig.factoryDepsPublished = true;
        /// GW contract deployment and publishing is done manually.
    }

    /// only needed for v27 to v28.2 jump upgrade
    function initializePreviousUpgradeFile() public virtual {
        string memory root = vm.projectRoot();
        console.log("ecosystem: %s", ecosystem);
        string memory path = string.concat(
            root,
            string.concat("/upgrade-envs/v0.28.2-patch/output_v28_patched/", ecosystem, "/v28-ecosystem.toml")
        );
        string memory toml = vm.readFile(path);
        bytes memory unpatchedDiamondCutL1 = toml.readBytes("$.diamond_cut_data_l1");
        bytes memory unpatchedDiamondCutGW = toml.readBytes("$.diamond_cut_data_gw");

        Diamond.DiamondCutData memory upgradeCutL1 = abi.decode(unpatchedDiamondCutL1, (Diamond.DiamondCutData));

        Diamond.DiamondCutData memory upgradeCutGW = abi.decode(unpatchedDiamondCutGW, (Diamond.DiamondCutData));

        upgradeCutL1 = patchUpgradeDiamondCut(upgradeCutL1, addresses.stateTransition.verifier);

        upgradeCutGW = patchUpgradeDiamondCut(upgradeCutGW, gatewayConfig.gatewayStateTransition.verifier);

        previousUpgradeData.upgradeCutDataL1 = abi.encode(upgradeCutL1);
        previousUpgradeData.upgradeCutDataGW = abi.encode(upgradeCutGW);

        bytes memory chainCreationParamsL1 = toml.readBytes("$.set_chain_creation_params_l1");
        bytes memory chainCreationParamsGW = toml.readBytes("$.set_chain_creation_params_gw");

        ChainCreationParams memory chainCreationParamsL1Data = abi.decode(chainCreationParamsL1, (ChainCreationParams));

        ChainCreationParams memory chainCreationParamsGWData = abi.decode(chainCreationParamsGW, (ChainCreationParams));

        // console.log("Before patch chainCreationParamsL1Data.diamondCut:");
        // console.logBytes(abi.encode(chainCreationParamsL1Data.diamondCut));
        chainCreationParamsL1Data.diamondCut = patchChainCreationDiamondCut(
            chainCreationParamsL1Data.diamondCut,
            addresses.stateTransition.verifier
        );
        // console.log("After patch chainCreationParamsL1Data.diamondCut");
        // console.logBytes(abi.encode(chainCreationParamsL1Data.diamondCut));

        chainCreationParamsGWData.diamondCut = patchChainCreationDiamondCut(
            chainCreationParamsGWData.diamondCut,
            gatewayConfig.gatewayStateTransition.verifier
        );

        previousUpgradeData.chainCreationParamsL1 = abi.encode(chainCreationParamsL1Data);
        previousUpgradeData.chainCreationParamsGW = abi.encode(chainCreationParamsGWData);

        /// kl todo load properly from file.
        uint256 v27 = SemVer.packSemVer(0, 27, 0);
        previousUpgradeData.previousProtocolVersion = v27;
    }

    function patchChainCreationDiamondCut(
        Diamond.DiamondCutData memory upgradeCut,
        address _verifier
    ) public virtual returns (Diamond.DiamondCutData memory patchedUpgradeCut) {
        patchedUpgradeCut = upgradeCut;

        // NewParser parser = new NewParser();
        // parser.parse(upgradeCut.initCalldata);
        bytes memory upgradeCalldata = upgradeCut.initCalldata;
        // console.logBytes(upgradeCalldata);
        InitializeDataNewChainLegacy memory initializeData = abi.decode(
            upgradeCalldata,
            (InitializeDataNewChainLegacy)
        );
        initializeData.verifier = IVerifier(_verifier);
        patchedUpgradeCut.initCalldata = abi.encode(initializeData);
        return patchedUpgradeCut;
    }

    function patchUpgradeDiamondCut(
        Diamond.DiamondCutData memory upgradeCut,
        address _verifier
    ) public virtual returns (Diamond.DiamondCutData memory patchedUpgradeCut) {
        patchedUpgradeCut = upgradeCut;
        NewParser parser = new NewParser();
        bytes memory upgradeCalldata = parser.parse(upgradeCut.initCalldata);

        // bytes memory upgradeCalldata = upgradeCut.initCalldata[4:];
        // console.logBytes(upgradeCut.initCalldata);
        // console.logBytes(upgradeCalldata);

        ProposedUpgrade memory proposedUpgrade = abi.decode(upgradeCalldata, (ProposedUpgrade));
        proposedUpgrade.verifier = _verifier;
        patchedUpgradeCut.initCalldata = abi.encodeCall(DefaultUpgrade.upgrade, (proposedUpgrade));
        return patchedUpgradeCut;
    }

    function getChainCreationParams(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (ChainCreationParams memory) {
        Diamond.DiamondCutData memory diamondCut = getDiamondCutData(stateTransition);
        // console.logBytes(previousUpgradeData.chainCreationParamsGW);
        // console.logBytes(previousUpgradeData.chainCreationParamsL1);
        if (stateTransition.isOnGateway) {
            return abi.decode(previousUpgradeData.chainCreationParamsGW, (ChainCreationParams));
        } else {
            return abi.decode(previousUpgradeData.chainCreationParamsL1, (ChainCreationParams));
        }
    }
    /// just for v28.2 special params, GW verifier and other contracts.
    function initializeOther(string memory newConfigPath, string memory _outputPath) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);

        string memory toml = vm.readFile(newConfigPath);
        gatewayConfig.gatewayStateTransition.verifier = toml.readAddress("$.gateway.gateway_state_transition.verifier");
        gatewayConfig.gatewayStateTransition.defaultUpgrade = toml.readAddress(
            "$.gateway.gateway_state_transition.default_upgrade"
        );
        addresses.stateTransition.defaultUpgrade = toml.readAddress("$.contracts.default_upgrade");
        console.log("gatewayConfig.gatewayStateTransition.verifier: %s", gatewayConfig.gatewayStateTransition.verifier);
    }

    function deployNewEcosystemContractsL1() public override {
        require(upgradeConfig.initialized, "Not initialized");

        instantiateCreate2Factory();

        deployVerifiers();
        // upgradeAddresses.upgradeStageValidator = 0xe28ad831d216fCD71BF3944867f3834dB55eD382;
        deployUpgradeStageValidator();

        upgradeConfig.ecosystemContractsDeployed = true;
    }

    // function deployVerifiers() override internal {
    //     if (compareStrings(ecosystem, "mainnet")) {
    //         (addresses.stateTransition.verifierFflonk) = (0x1AC4F629Fdc77A7700B68d03bF8D1A53f2210911);
    //         (addresses.stateTransition.verifierPlonk) = 0x2db2ffdecb7446aaab01FAc3f4D55863db3C5bd6;
    //         (addresses.stateTransition.verifier) = 0xD71DDC9956781bf07DbFb9fCa891f971dbE9868A;
    //     } else {
    //         (addresses.stateTransition.verifierFflonk) = deploySimpleContract("L1VerifierFflonk", false);
    //         (addresses.stateTransition.verifierPlonk) = deploySimpleContract("L1VerifierPlonk", false);
    //         (addresses.stateTransition.verifier) = deploySimpleContract("TestnetVerifier", false);
    //     }
    // }

    /// all GW contracts are manually deployed before.
    function deployNewEcosystemContractsGW() public virtual override {
        require(upgradeConfig.initialized, "Not initialized");
    }

    ///// V27 -> v28.2 upgrade ignore for now

    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            previousUpgradeData.upgradeCutDataL1,
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
    ) public virtual override returns (Call[] memory calls) {
        /// note check that v27 points to v28 and there is no v27.1 intermediate.
        uint256 v27 = SemVer.packSemVer(0, 27, 0);

        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            previousUpgradeData.upgradeCutDataGW,
            (Diamond.DiamondCutData)
        );

        bytes memory l2Calldata = abi.encodeCall(ChainTypeManager.setUpgradeDiamondCut, (upgradeCut, v27));

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            priorityTxsL2GasLimit,
            maxExpectedL1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
        // kl todo should we set the deadline on GW? In practice,
        // we should not have migrated chains there.
    }

    /// @notice Update implementations in proxies
    function prepareUpgradeProxiesCalls() public virtual override returns (Call[] memory calls) {
        /// we don't do any proxy upgrades.
        calls = new Call[](0);
        return calls;
    }

    function prepareDAValidatorCall() public virtual override returns (Call[] memory calls) {
        calls = new Call[](0);
        return calls;
    }

    function prepareDAValidatorCallGW(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual override returns (Call[] memory calls) {
        calls = new Call[](0);
        return calls;
    }

    ////////////////// skip other things

    function prepareGovernanceUpgradeTimerCheckCall() public virtual override returns (Call[] memory calls) {
        calls = new Call[](0);
        return calls;
    }

    function prepareGovernanceUpgradeTimerStartCall() public virtual override returns (Call[] memory calls) {
        calls = new Call[](0);
        return calls;
    }

    function prepareCTMImplementationUpgrade(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual override returns (Call[] memory calls) {
        calls = new Call[](0);
        return calls;
    }

    ////////////////// skip gateway for stage start

    // function prepareGatewaySpecificStage0GovernanceCalls() public virtual override returns (Call[] memory calls) {
    //     calls = new Call[](0);
    // }

    // function prepareGatewaySpecificStage1GovernanceCalls() public virtual override returns (Call[] memory calls) {
    //     calls = new Call[](0);
    // }

    // function prepareGatewaySpecificStage2GovernanceCalls() public override virtual returns (Call[] memory calls) {
    //     calls = new Call[](0);
    //     return calls;
    // }

    // function provideSetNewVersionUpgradeCallForGateway(
    //     uint256 l2GasLimit,
    //     uint256 l1GasPrice
    // ) public virtual override returns (Call[] memory calls) {
    //     calls = new Call[](0);
    //     return calls;
    // }

    // function prepareNewChainCreationParamsCallForGateway(        uint256 l2GasLimit,
    //     uint256 l1GasPrice) public virtual override returns (Call[] memory calls) {
    //     calls = new Call[](0);
    //     return calls;
    // }

    ////////////////// skip gateway for stage end

    ////////////////// skip L1 for stage start

    // function prepareCheckMigrationsPausedCalls() public virtual override returns (Call[] memory calls) {
    //     calls = new Call[](0);
    //     return calls;
    // }

    // function prepareNewChainCreationParamsCall() public virtual override returns (Call[] memory calls) {
    //     calls = new Call[](0);
    //     return calls;
    // }

    // function provideSetNewVersionUpgradeCall() public virtual override returns (Call[] memory calls) {
    //     calls = new Call[](0);
    //     return calls;
    // }

    // function prepareStage2GovernanceCalls() public virtual override returns (Call[] memory calls) {
    //     Call[][] memory allCalls = new Call[][](5);

    //     allCalls[0] = prepareCheckUpgradeIsPresent();
    //     allCalls[1] = prepareUnpauseGatewayMigrationsCall();
    //     allCalls[2] = prepareVersionSpecificStage2GovernanceCallsL1();
    //     allCalls[2] = prepareGatewaySpecificStage2GovernanceCalls();
    //     allCalls[4] = prepareCheckMigrationsUnpausedCalls();

    //     calls = mergeCallsArray(allCalls);
    // }

    ////////////////// skip L1 for stage end

    function emptyDiamondCut() public virtual returns (Diamond.DiamondCutData memory cutData) {
        Diamond.FacetCut[] memory emptyArray;
        cutData = Diamond.DiamondCutData({facetCuts: emptyArray, initAddress: address(0), initCalldata: new bytes(0)});
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

contract NewParser {
    function parse(bytes calldata data) public pure returns (bytes memory) {
        return data[4:];
    }
}
