// SPDX-License-Identifier: MIT
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

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";

/// @notice Script used for v29 upgrade flow
contract EcosystemUpgrade_v29 is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    address[] internal oldValidatorTimelocks;
    address[] internal oldGatewayValidatorTimelocks;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(vm.envString("V29_UPGRADE_ECOSYSTEM_INPUT"), vm.envString("V29_UPGRADE_ECOSYSTEM_OUTPUT"));

        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
    }

    function initializeConfig(string memory newConfigPath) internal override {
        super.initializeConfig(newConfigPath);
        string memory toml = vm.readFile(newConfigPath);

        bytes memory encodedOldValidatorTimelocks = toml.readBytes("$.encoded_old_validator_timelocks");
        oldValidatorTimelocks = abi.decode(encodedOldValidatorTimelocks, (address[]));

        bytes memory encodedOldGatewayValidatorTimelocks = toml.readBytes("$.encoded_old_gateway_validator_timelocks");
        oldGatewayValidatorTimelocks = abi.decode(encodedOldGatewayValidatorTimelocks, (address[]));
    }

    function _getL2UpgradeTargetAndData(
        IL2ContractDeployer.ForceDeployment[] memory _forceDeployments
    ) internal override returns (address, bytes memory) {
        bytes32 ethAssetId = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy).ETH_TOKEN_ASSET_ID();
        bytes memory v29UpgradeCalldata = abi.encodeCall(
            IL2V29Upgrade.upgrade,
            (AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress), ethAssetId)
        );
        return (
            address(L2_COMPLEX_UPGRADER_ADDR),
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (_forceDeployments, L2_VERSION_SPECIFIC_UPGRADER_ADDR, v29UpgradeCalldata)
            )
        );
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view override returns (bytes memory) {
        if (!isZKBytecode && compareStrings(contractName, "L1V29Upgrade")) {
            return type(L1V29Upgrade).creationCode;
        }
        return super.getCreationCode(contractName, isZKBytecode);
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view override returns (bytes memory) {
        if (compareStrings(contractName, "L1V29Upgrade")) {
            return abi.encode();
        }
        return super.getCreationCalldata(contractName, isZKBytecode);
    }

    function deployValidatorTimelock() internal override returns (address) {
        return deploySimpleContract("ValidatorTimelock", false);
    }

    function encodePostUpgradeCalldata(StateTransitionDeployedAddresses memory stateTransitionAddresses) internal override returns (bytes memory) {
        address[] memory oldValidatorTimelocks = stateTransitionAddresses.isOnGateway ? oldGatewayValidatorTimelocks : oldValidatorTimelocks;
        return abi.encode(L1V29Upgrade.V29UpgradeParams({
            oldValidatorTimelocks: oldValidatorTimelocks,
            newValidatorTimelock: stateTransitionAddresses.validatorTimelock
        }));
    }

    /// @notice Additional calls to newConfigure contracts
    function prepareSetPostV29UpgradeableValidatorTimelockCall() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = Call({
            target: addresses.stateTransition.chainTypeManagerProxy,
            data: abi.encodeCall(
                IChainTypeManager.setPostV29UpgradeableValidatorTimelock,
                (addresses.stateTransition.validatorTimelock)
            ),
            value: 0
        });
    }

    function prepareSetPostV29UpgradeableValidatorTimelockCallGW(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes memory l2Calldata = abi.encodeCall(
            IChainTypeManager.setPostV29UpgradeableValidatorTimelock,
            (
                gatewayConfig.gatewayStateTransition.validatorTimelock
            )
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
    }

    function prepareGatewaySpecificStage1GovernanceCalls() public override returns (Call[] memory calls) {
        Call[] memory baseCalls = super.prepareGatewaySpecificStage1GovernanceCalls(); 
        if (gatewayConfig.chainId == 0) return baseCalls; // Gateway is unknown

        // Note: gas price can fluctuate, so we need to be sure that upgrade won't be broken because of that
        uint256 priorityTxsL2GasLimit = newConfig.priorityTxsL2GasLimit;
        uint256 maxExpectedL1GasPrice = newConfig.maxExpectedL1GasPrice;

        Call[][] memory allCalls = new Call[][](2);
        allCalls[0] = baseCalls;
        allCalls[1] = prepareSetPostV29UpgradeableValidatorTimelockCallGW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        return mergeCallsArray(allCalls);
    }

    function prepareStage1GovernanceCalls() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](7);
        allCalls[0] = prepareGovernanceUpgradeTimerCheckCall();
        allCalls[1] = prepareCheckMigrationsPausedCalls();
        allCalls[2] = prepareUpgradeProxiesCalls();
        allCalls[3] = prepareNewChainCreationParamsCall();
        allCalls[4] = provideSetNewVersionUpgradeCall();
        allCalls[5] = prepareDAValidatorCall();
        allCalls[6] = prepareSetPostV29UpgradeableValidatorTimelockCall();
        allCalls[7] = prepareGatewaySpecificStage1GovernanceCalls();
        calls = mergeCallsArray(allCalls);
    }

    function deployUsedUpgradeContract() internal override returns (address) {
        return deploySimpleContract("L1V29Upgrade", false);
    }
}
