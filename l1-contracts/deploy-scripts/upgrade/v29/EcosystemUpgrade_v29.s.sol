// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {Utils} from "../../utils/Utils.sol";
import {StateTransitionDeployedAddresses} from "../../utils/Types.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";

import {CTMDeploymentTracker} from "contracts/core/ctm-deployment/CTMDeploymentTracker.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {AddressHasNoCode} from "../../utils/ZkSyncScriptErrors.sol";
import {ICTMDeploymentTracker} from "contracts/core/ctm-deployment/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {ContractsBytecodesLib} from "../../utils/bytecode/ContractsBytecodesLib.sol";

import {Call} from "contracts/governance/Common.sol";

import {L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

import {DefaultCTMUpgrade} from "../default_upgrade/DefaultCTMUpgrade.s.sol";
import {UpgradeUtils} from "../default_upgrade/UpgradeUtils.sol";
import {DeployL1CoreUtils} from "../../ecosystem/DeployL1CoreUtils.s.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";

// Note that the `ProtocolUpgradeHandler` uses `OpenZeppeling v5`.
interface ProxyAdminV5 {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external;
}

/// @notice Script used for v29 upgrade flow
contract EcosystemUpgrade_v29 is Script, DefaultCTMUpgrade {
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

        prepareDefaultTestUpgradeCalls();
    }

    function deployNewEcosystemContractsL1() public virtual override {
        DeployL1CoreUtils l1CoreDeployer = new DeployL1CoreUtils();
        l1CoreDeployer.initializeConfig(vm.envString("V29_UPGRADE_ECOSYSTEM_INPUT"));
        l1CoreDeployer.deploySimpleContract("L1Bridgehub", false);
        deploySimpleContract("L1ChainTypeManager", false);
    }

    function initializeConfig(string memory permanentValuesInputPath, string memory newConfigPath) internal override {
        super.initializeConfig(newConfigPath);
        string memory toml = vm.readFile(newConfigPath);

        v28ProtocolVersion = newConfig.oldProtocolVersion;

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
    ) internal returns (address, bytes memory) {
        bytes32 ethAssetId = IL1AssetRouter(discoveredBridgehub.assetRouter).ETH_TOKEN_ASSET_ID();
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

        //        (
        //            bridgehubAddresses.proxies.implementations.chainAssetHandler,
        //            bridgehubAddresses.proxies.chainAssetHandlerProxy
        //        ) = deployTuppWithContract("L1ChainAssetHandler", false);

        (
            addresses.stateTransition.validatorTimelockImplementation,
            addresses.stateTransition.validatorTimelock
        ) = deployTuppWithContract("ValidatorTimelock", false);
    }

    //    function deployUpgradeSpecificContractsGW() internal override {
    //        super.deployUpgradeSpecificContractsGW();

    //        (
    //            gatewayConfig.gatewayStateTransition.validatorTimelockImplementation,
    //            gatewayConfig.gatewayStateTransition.validatorTimelock
    //        ) = deployGWTuppWithContract("ValidatorTimelock");
    //    }

    function encodePostUpgradeCalldata(
        StateTransitionDeployedAddresses memory stateTransitionAddresses
    ) internal override returns (bytes memory) {
        address[] memory oldValidatorTimelocks = oldValidatorTimelocks;
        return
            abi.encode(
                L1V29Upgrade.V29UpgradeParams({
                    oldValidatorTimelocks: oldValidatorTimelocks,
                    newValidatorTimelock: stateTransitionAddresses.validatorTimelock
                })
            );
    }

    function prepareVersionSpecificStage1GovernanceCallsL1() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](3);
        allCalls[0] = prepareSetValidatorTimelockPostV29L1();
        // allCalls[1] = prepareSetChainAssetHandlerOnBridgehubCall();
        allCalls[1] = prepareSetCtmAssetHandlerAddressOnL1Call();
        allCalls[2] = prepareSetUpgradeDiamondCutOnL1Call();
        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareVersionSpecificStage2GovernanceCallsL1() public override returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](1);
        allCalls[0] = prepareUpgradePUHImplementationOnL1Call();
        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareVersionSpecificStage1GovernanceCallsGW(
        uint256 priorityTxsL2GasLimit,
        uint256 maxExpectedL1GasPrice
    ) public returns (Call[] memory calls) {
        // The below does not contain the call to set the chain asset handler address on Bridgehub on GW, because
        // it is done for all ZK Chains as part of the `L2V29Upgrade` upgrade.

        // This is the calldata needed to set the chain asset handler as the asset handler for the CTM.
        Call[][] memory allCalls = new Call[][](3);
        allCalls[0] = prepareSetCtmAssetHandlerAddressOnGWCall(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[1] = prepareSetValidatorTimelockPostV29GW(priorityTxsL2GasLimit, maxExpectedL1GasPrice);
        allCalls[2] = prepareSetUpgradeDiamondCutOnGWCall(priorityTxsL2GasLimit, maxExpectedL1GasPrice);

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareSetValidatorTimelockPostV29L1() internal virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        calls[0] = Call({
            target: discoveredCTM.ctmProxy,
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
        return calls;
        //        bytes memory l2Calldata = abi.encodeCall(
        //            IChainTypeManager.setValidatorTimelockPostV29,
        //            (gatewayConfig.gatewayStateTransition.validatorTimelock)
        //        );
        //
        //        calls = _prepareL1ToGatewayCall(
        //            l2Calldata,
        //            l2GasLimit,
        //            l1GasPrice,
        //            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        //        );
    }

    function prepareSetUpgradeDiamondCutOnGWCall(
        uint256 l2GasLimit,
        uint256 l1GasPrice
    ) public virtual returns (Call[] memory calls) {
        return calls;
        //        uint256 oldProtocolVersion = v28ProtocolVersion;
        //        Diamond.DiamondCutData memory upgradeCut = abi.decode(gatewayConfig.upgradeCutData, (Diamond.DiamondCutData));
        //
        //        bytes memory l2Calldata = abi.encodeCall(
        //            IChainTypeManager.setUpgradeDiamondCut,
        //            (upgradeCut, oldProtocolVersion)
        //        );
        //
        //        calls = _prepareL1ToGatewayCall(
        //            l2Calldata,
        //            l2GasLimit,
        //            l1GasPrice,
        //            gatewayConfig.gatewayStateTransition.chainTypeManagerProxy
        //        );
    }

    function prepareSetChainAssetHandlerOnBridgehubCall() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);
        //        calls[0] = Call({
        //            target: discoveredBridgehub.proxies.bridgehub,
        //            data: abi.encodeCall(IBridgehubBase.setChainAssetHandler, (bridgehubAddresses.proxies.chainAssetHandlerProxy)),
        //            value: 0
        //        });
    }

    /// @notice Sets ctm asset handler address on L1. We need to update it because of ChainAssetHandler appearance.
    function prepareSetCtmAssetHandlerAddressOnL1Call() public virtual returns (Call[] memory calls) {
        calls = new Call[](1);

        //        calls[0] = Call({
        //            target: discoveredBridgehub.proxies.ctmDeploymentTracker,
        //            data: abi.encodeCall(CTMDeploymentTracker.setCtmAssetHandlerAddressOnL1, (discoveredCTM.ctmProxy)),
        //            value: 0
        //        });
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
            target: discoveredCTM.ctmProxy,
            data: abi.encodeCall(IChainTypeManager.setUpgradeDiamondCut, (upgradeCut, oldProtocolVersion)),
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
            bytes32(uint256(uint160(discoveredCTM.ctmProxy))),
            discoveredBridgehub.proxies.ctmDeploymentTracker
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
                discoveredBridgehub.proxies.bridgehub,
                discoveredBridgehub.assetRouter,
                discoveredBridgehub.assetRouter,
                0,
                secondBridgeData,
                msg.sender
            )
        );
    }

    function deployUsedUpgradeContract() internal returns (address) {
        return deploySimpleContract("L1V29Upgrade", false);
    }

    //    function deployUsedUpgradeContractGW() internal override returns (address) {
    //        return deployGWContract("L1V29Upgrade");
    //    }
}
