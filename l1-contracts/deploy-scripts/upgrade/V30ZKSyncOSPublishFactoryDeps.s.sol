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
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {SET_ASSET_HANDLER_COUNTERPART_ENCODING_VERSION} from "contracts/bridge/asset-router/IAssetRouterBase.sol";

import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {L2SystemProxiesUpgrade} from "contracts/l2-upgrades/L2SystemProxiesUpgrade.sol";
import {VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";

import {StateTransitionDeployedAddresses, Utils} from "../Utils.sol";

import {SystemContractProxy} from "contracts/l2-upgrades/SystemContractProxy.sol";
import {SystemContractProxyAdmin} from "contracts/l2-upgrades/SystemContractProxyAdmin.sol";
import {L2ComplexUpgrader} from "contracts/l2-upgrades/L2ComplexUpgrader.sol";


/// @dev This contract exists only to return arbitrary runtime bytecode.
contract ReturnDeployedBytecode {
    constructor(bytes memory deployedBytecode) {
        assembly {
            // return the deployed bytecode as the contract's runtime bytecode
            return(add(deployedBytecode, 0x20), mload(deployedBytecode))
        }
    }
}

/// @dev The registry of bytecodes that were published
contract PublishedBytecodesRegistry {
    mapping(bytes32 => address) public bytecodeHashToDeployedAddress;

    function registerBytecode(bytes memory deployedBytecode) external {
        address deployed = address(new ReturnDeployedBytecode(deployedBytecode));

        bytes32 codeHash;
        assembly {
            codeHash := extcodehash(deployed)
        }
        require(codeHash == keccak256(deployedBytecode), "Deployed code hash does not match expected hash");

        bytecodeHashToDeployedAddress[codeHash] = deployed;
    }
}

contract DeployFromBytecode is Script {
    function run() internal pure returns (bytes[] memory) {
        bytes[] memory expected = new bytes[](9);
        expected[0] = type(SystemContractProxy).runtimeCode;
        expected[1] = type(SystemContractProxyAdmin).runtimeCode;

        expected[2] = type(L2ComplexUpgrader).runtimeCode;
        expected[3] = type(L2MessageRoot).runtimeCode;
        expected[4] = type(L2Bridgehub).runtimeCode;
        expected[5] = type(L2AssetRouter).runtimeCode;
        expected[6] = type(L2NativeTokenVault).runtimeCode;
        expected[7] = type(L2ChainAssetHandler).runtimeCode;
        expected[8] = type(UpgradeableBeaconDeployer).runtimeCode;

        return expected;
    }
    
    function publish() external {
        bytes[] memory bytecodes = expectedBytecodes();
        
        vm.startBroadcast();

        PublishedBytecodesRegistry registry = new PublishedBytecodesRegistry();
        for (uint256 i = 0; i < bytecodes.length; i++) {
            registry.registerBytecode(bytecodes[i]);
        }
    
        vm.stopBroadcast();

        console2.log("Registry deployed at:", address(registry));
    }
}
