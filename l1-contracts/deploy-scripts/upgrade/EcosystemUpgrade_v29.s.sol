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
import {ChainAssetHandler} from "contracts/bridgehub/ChainAssetHandler.sol";
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

import {DeployL1Script} from "../DeployL1.s.sol";

import {DefaultEcosystemUpgrade} from "../upgrade/DefaultEcosystemUpgrade.s.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

// Note that the `ProtocolUpgradeHandler` uses `OpenZeppeling v5`.
interface ProxyAdminV5 {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external;
}

/// @notice Script used for v29 upgrade flow
contract EcosystemUpgrade_v29 is Script, DefaultEcosystemUpgrade {
    using stdToml for string;

    address[] internal oldValidatorTimelocks;
    address[] internal oldGatewayValidatorTimelocks;
    address protocolUpgradeHandlerImplementationAddress;
    uint256 v28ProtocolVersion;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(vm.envString("V29_UPGRADE_ECOSYSTEM_INPUT"), vm.envString("V29_UPGRADE_ECOSYSTEM_OUTPUT"));

        prepareEcosystemUpgrade();

        prepareDefaultGovernanceCalls();
        prepareDefaultEcosystemAdminCalls();
    }

    function initializeConfig(string memory newConfigPath) internal override {
        super.initializeConfig(newConfigPath);
        string memory toml = vm.readFile(newConfigPath);

        v28ProtocolVersion = toml.readUint("$.v28_protocol_version");

        bytes memory encodedOldValidatorTimelocks = toml.readBytes("$.V29.encoded_old_validator_timelocks");
        oldValidatorTimelocks = abi.decode(encodedOldValidatorTimelocks, (address[]));

        bytes memory encodedOldGatewayValidatorTimelocks = toml.readBytes(
            "$.V29.encoded_old_gateway_validator_timelocks"
        );
        oldGatewayValidatorTimelocks = abi.decode(encodedOldGatewayValidatorTimelocks, (address[]));

        protocolUpgradeHandlerImplementationAddress = toml.readAddress(
            "$.contracts.protocol_upgrade_handler_implementation_address"
        );
    }

    function saveOutputVersionSpecific() internal override {
        vm.serializeAddress(
            "deployed_addresses",
            "protocol_upgrade_handler_address_implementation",
            protocolUpgradeHandlerImplementationAddress
        );
        vm.serializeBytes("v29", "encoded_old_gateway_validator_timelocks", abi.encode(oldGatewayValidatorTimelocks));
        string memory oldValidatorTimelocksSerialized = vm.serializeBytes(
            "v29",
            "encoded_old_validator_timelocks",
            abi.encode(oldValidatorTimelocks)
        );

        vm.writeToml(oldValidatorTimelocksSerialized, upgradeConfig.outputPath, ".v29");
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

    function getProxyAdmin(address _proxyAddr) internal view returns (address proxyAdmin) {
        // the constant is the proxy admin storage slot
        proxyAdmin = address(
            uint160(
                uint256(
                    vm.load(_proxyAddr, bytes32(0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103))
                )
            )
        );
    }

    function getForceDeploymentNames() internal override returns (string[] memory) {
        string[] memory forceDeploymentNames = new string[](1);
        forceDeploymentNames[0] = "L2V29Upgrade";
        return forceDeploymentNames;
    }

    function getExpectedL2Address(string memory contractName) public override returns (address) {
        if (compareStrings(contractName, "L2V29Upgrade")) {
            return L2_VERSION_SPECIFIC_UPGRADER_ADDR;
        }
        return super.getExpectedL2Address(contractName);
    }

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view override returns (bytes memory) {
        if (compareStrings(contractName, "L1V29Upgrade")) {
            if (!isZKBytecode) {
                return type(L1V29Upgrade).creationCode;
            } else {
                return ContractsBytecodesLib.getCreationCode("L1V29Upgrade", true);
            }
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

    function deployUpgradeSpecificContractsL1() internal override {
        super.deployUpgradeSpecificContractsL1();

        (
            addresses.bridgehub.chainAssetHandlerImplementation,
            addresses.bridgehub.chainAssetHandlerProxy
        ) = deployTuppWithContract("ChainAssetHandler", false);

        (
            addresses.stateTransition.validatorTimelockImplementation,
            addresses.stateTransition.validatorTimelock
        ) = deployTuppWithContract("ValidatorTimelock", false);
    }

    function deployUpgradeSpecificContractsGW() internal override {
        super.deployUpgradeSpecificContractsGW();

        (
            gatewayConfig.gatewayStateTransition.validatorTimelockImplementation,
            gatewayConfig.gatewayStateTransition.validatorTimelock
        ) = deployGWTuppWithContract("ValidatorTimelock");
    }

    function encodePostUpgradeCalldata(
        StateTransitionDeployedAddresses memory stateTransitionAddresses
    ) internal override returns (bytes memory) {
        address[] memory oldValidatorTimelocks = stateTransitionAddresses.isOnGateway
            ? oldGatewayValidatorTimelocks
            : oldValidatorTimelocks;
        return
            abi.encode(
                L1V29Upgrade.V29UpgradeParams({
                    oldValidatorTimelocks: oldValidatorTimelocks,
                    newValidatorTimelock: stateTransitionAddresses.validatorTimelock
                })
            );
    }

    function prepareVersionSpecificStage1GovernanceCallsL1() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](4);
        allCalls[0] = prepareSetValidatorTimelockPostV29L1();
        allCalls[1] = prepareSetChainAssetHandlerOnBridgehubCall();
        allCalls[2] = prepareSetCtmAssetHandlerAddressOnL1Call();
        allCalls[3] = prepareSetUpgradeDiamondCutOnL1Call();
        calls = mergeCallsArray(allCalls);
    }

    function prepareVersionSpecificStage2GovernanceCallsL1() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](1);
        allCalls[0] = prepareUpgradePUHImplementationOnL1Call();
        calls = mergeCallsArray(allCalls);
    }

    function prepareVersionSpecificStage1GovernanceCallsGW(
        uint256 priorityTxsL2GasLimit,
        uint256 maxExpectedL1GasPrice
    ) public override returns (Call[] memory calls) {
        // The below does not contain the call to set the chain asset handler address on Bridgehub on GW, because
        // it is done for all ZK Chains as part of the `L2V29Upgrade` upgrade.

        // This is the calldata needed to set the chain asset handler as the asset handler for the CTM.
        Call[][] memory allCalls = new Call[][](3);
        allCalls[0] = prepareSetCtmAssetHandlerAddressOnGWCall(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareSetValidatorTimelockPostV29GW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[2] = prepareSetUpgradeDiamondCutOnGWCall(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = mergeCallsArray(allCalls);
    }

    function prepareSetValidatorTimelockPostV29L1() internal virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = Call({
            target: addresses.stateTransition.chainTypeManagerProxy,
            data: abi.encodeCall(
                IChainTypeManager.setValidatorTimelockPostV29,
                (addresses.stateTransition.validatorTimelock)
            ),
            value: 0
        });
    }

    function prepareSetValidatorTimelockPostV29GW(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes memory l2Calldata = abi.encodeCall(
            IChainTypeManager.setValidatorTimelockPostV29,
            (gatewayConfig.gatewayStateTransition.validatorTimelock)
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
    }

    function prepareSetUpgradeDiamondCutOnGWCall(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        uint256 oldProtocolVersion = v28ProtocolVersion;
        Diamond.DiamondCutData memory upgradeCut = abi.decode(gatewayConfig.upgradeCutData, (Diamond.DiamondCutData));

        bytes memory l2Calldata = abi.encodeCall(
            IChainTypeManager.setUpgradeDiamondCut,
            (upgradeCut, oldProtocolVersion)
        );

        calls = _prepareL1ToGatewayCall(
            l2Calldata,
            l2GasLimit,
            l1GasPrice,
            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        );
    }

    function prepareSetChainAssetHandlerOnBridgehubCall() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: addresses.bridgehub.bridgehubProxy,
            data: abi.encodeCall(Bridgehub.setChainAssetHandler, (addresses.bridgehub.chainAssetHandlerProxy)),
            value: 0
        });
    }

    /// @notice Sets ctm asset handler address on L1. We need to update it because of ChainAssetHandler appearance.
    function prepareSetCtmAssetHandlerAddressOnL1Call() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = Call({
            target: addresses.bridgehub.ctmDeploymentTrackerProxy,
            data: abi.encodeCall(
                CTMDeploymentTracker.setCtmAssetHandlerAddressOnL1,
                (addresses.stateTransition.chainTypeManagerProxy)
            ),
            value: 0
        });
    }

    /// @notice Sets upgrade diamond cut the same for v28 version, as it is for v29.
    function prepareSetUpgradeDiamondCutOnL1Call() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        uint256 oldProtocolVersion = v28ProtocolVersion;
        Diamond.DiamondCutData memory upgradeCut = abi.decode(
            newlyGeneratedData.upgradeCutData,
            (Diamond.DiamondCutData)
        );

        calls[0] = Call({
            target: addresses.stateTransition.chainTypeManagerProxy,
            data: abi.encodeCall(ChainTypeManager.setUpgradeDiamondCut, (upgradeCut, oldProtocolVersion)),
            value: 0
        });
    }

    /// @notice Upgrades the implementation of protocol upgrade handler.
    function prepareUpgradePUHImplementationOnL1Call() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        address transparentProxyAdmin = getProxyAdmin(config.ownerAddress);

        calls[0] = Call({
            target: transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdminV5.upgradeAndCall,
                (config.ownerAddress, protocolUpgradeHandlerImplementationAddress, hex"")
            ),
            value: 0
        });
    }

    function prepareSetCtmAssetHandlerAddressOnGWCall(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        bytes32 chainAssetId = DataEncoding.encodeAssetId(
            block.chainid,
            bytes32(uint256(uint160(addresses.stateTransition.chainTypeManagerProxy))),
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );

        bytes memory secondBridgeData = abi.encodePacked(
            SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION,
            abi.encode(chainAssetId, L2_CHAIN_ASSET_HANDLER_ADDR)
        );

        calls = Utils.mergeCalls(
            calls,
            Utils.prepareGovernanceL1L2TwoBridgesTransaction(
                l1GasPrice,
                l2GasLimit,
                gatewayConfig.chainId,
                addresses.bridgehub.bridgehubProxy,
                addresses.bridges.l1AssetRouterProxy,
                addresses.bridges.l1AssetRouterProxy,
                0,
                secondBridgeData,
                msg.sender
            )
        );
    }

    function deployUsedUpgradeContract() internal override returns (address) {
        return deploySimpleContract("L1V29Upgrade", false);
    }

    function deployUsedUpgradeContractGW() internal override returns (address) {
        return deployGWContract("L1V29Upgrade");
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "ValidatorTimelock")) {
            if (!isZKBytecode) {
                return
                    abi.encodeCall(
                        ValidatorTimelock.initialize,
                        (config.ownerAddress, uint32(config.contracts.validatorTimelockExecutionDelay))
                    );
            } else {
                // On Gateway, the delay is always 0.
                return
                    abi.encodeCall(
                        ValidatorTimelock.initialize,
                        (AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress), uint32(0))
                    );
            }
        } else if (compareStrings(contractName, "ChainAssetHandler")) {
            if (!isZKBytecode) {
                return abi.encodeCall(ChainAssetHandler.initialize, (config.ownerAddress));
            } else {
                return
                    abi.encodeCall(
                        ChainAssetHandler.initialize,
                        AddressAliasHelper.applyL1ToL2Alias(config.ownerAddress)
                    );
            }
        } else {
            return super.getInitializeCalldata(contractName, isZKBytecode);
        }
    }
}
