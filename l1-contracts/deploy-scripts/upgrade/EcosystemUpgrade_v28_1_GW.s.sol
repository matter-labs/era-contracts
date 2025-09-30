// // SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy, TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {PrepareL1L2TransactionParams, StateTransitionDeployedAddresses, Utils} from "../Utils.sol";
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
// import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {PermanentRestriction} from "contracts/governance/PermanentRestriction.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
// import {ContractsBytecodesLib} from "../ContractsBytecodesLib.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {Call} from "contracts/governance/Common.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {ProposedUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";

import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, L2_FORCE_DEPLOYER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR, L2_CREATE2_FACTORY_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
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
// import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

// import {DeployL1Script} from "../DeployL1.s.sol";

// import {EcosystemUpgradeConfig, Gateway} from "./UpgradeUtils.sol";

import {SemVer} from "../../contracts/common/libraries/SemVer.sol";
import {DeployUtils} from "../DeployUtils.s.sol";
import {FacetCut} from "../Utils.sol";

/// @notice Script used for v29 upgrade flow
contract EcosystemUpgrade_v28_1_GW is Script, DeployUtils {
    using stdToml for string;

    // EcosystemUpgradeConfig internal upgradeConfig;
    // Gateway internal gatewayConfig;

    struct PreviousUpgradeData {
        // Diamond.DiamondCutData upgradeCut;
        bytes upgradeCutData;
        uint256 previousProtocolVersion;
    }

    PreviousUpgradeData previousUpgradeData;

    /// @notice E2e upgrade generation
    function run() public virtual {
        // initialize(
        //     vm.envString("V28_1_UPGRADE_ECOSYSTEM_INPUT"),
        //     vm.envString("V28_1_UPGRADE_ECOSYSTEM_OUTPUT")
        // );
        // initializePreviousUpgradeFile();
        // prepareEcosystemUpgrade();
        // prepareDefaultGovernanceCalls();
    }

    function deployGWContracts() public virtual {
        // initialize(
        //     vm.envString("V28_1_UPGRADE_ECOSYSTEM_INPUT"),
        //     vm.envString("V28_1_UPGRADE_ECOSYSTEM_OUTPUT")
        // );
        config.testnetVerifier = false;

        deployNewEcosystemContractsGWManual();
    }

    function deployNewEcosystemContractsGWManual() public virtual {
        // require(upgradeConfig.initialized, "Not initialized");

        addresses.stateTransition.verifierFflonk = deployGWContractDirect("VerifierFflonk");
        addresses.stateTransition.verifierPlonk = deployGWContractDirect("VerifierPlonk");
        addresses.stateTransition.verifier = deployGWContractDirect("Verifier");
        // addresses.defaultUpgrade =
        // deployGWContractDirect("DefaultUopgrade");
    }

    error HashIsNonZero(bytes32);

    function deployGWContractDirect(string memory contractName) internal returns (address contractAddress) {
        bytes memory creationCalldata = getCreationCalldata(contractName, true);
        bytes memory creationCode = getCreationCode(contractName, true);
        bytes32 create2salt = bytes32(0);
        (bytes32 bytecodeHash, bytes memory deployData) = Utils.getDeploymentCalldata(
            create2salt,
            creationCode,
            creationCalldata
        );

        address contractAddress = Utils.getL2AddressViaCreate2Factory(create2salt, bytecodeHash, creationCalldata);

        uint256 codeSize = contractAddress.code.length;
        if (codeSize == 0) {
            vm.broadcast();
            (bool success, bytes memory result) = L2_CREATE2_FACTORY_ADDR.call(deployData);
            if (!success) {
                // if (!compareStrings(string(result), string(abi.encodeWithSelector(HashIsNonZero.selector, bytecodeHash)))) {
                //     revert(string.concat("Failed to deploy contract ", contractName));
                // }
                console.logBytes(result);
            }
        }

        notifyAboutDeployment(contractAddress, contractName, creationCalldata, contractName, true);
        return contractAddress;
    }

    function deployTuppWithContract(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (address implementation, address proxy) {
        revert("Not implemented tupp");
    }

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory) {
        revert("Not implemented initialize calldata");
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "Verifier")) {
            if (config.testnetVerifier) {
                return Utils.readZKFoundryBytecodeL1("TestnetVerifier.sol", "TestnetVerifier");
            } else {
                return Utils.readZKFoundryBytecodeL1("DualVerifier.sol", "DualVerifier");
            }
        } else if (compareStrings(contractName, "VerifierFflonk")) {
            return Utils.readZKFoundryBytecodeL1("L1VerifierFflonk.sol", "L1VerifierFflonk");
        } else if (compareStrings(contractName, "VerifierPlonk")) {
            return Utils.readZKFoundryBytecodeL1("L1VerifierPlonk.sol", "L1VerifierPlonk");
        }
    }

    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (FacetCut[] memory facetCuts) {
        revert("Not implemented facet cuts");
    }

    function compareStrings(string memory a, string memory b) internal pure override returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
}
