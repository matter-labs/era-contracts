// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors
import {Script, console2 as console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {StateTransitionDeployedAddresses, Utils} from "./Utils.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {L1ChainAssetHandler} from "contracts/bridgehub/L1ChainAssetHandler.sol";
import {L1MessageRoot} from "contracts/bridgehub/L1MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {ContractsBytecodesLib} from "./ContractsBytecodesLib.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";

import {EraDualVerifier} from "contracts/state-transition/verifiers/EraDualVerifier.sol";
import {ZKsyncOSDualVerifier} from "contracts/state-transition/verifiers/ZKsyncOSDualVerifier.sol";
import {EraVerifierFflonk} from "contracts/state-transition/verifiers/EraVerifierFflonk.sol";
import {EraVerifierPlonk} from "contracts/state-transition/verifiers/EraVerifierPlonk.sol";
import {ZKsyncOSVerifierFflonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierFflonk.sol";
import {ZKsyncOSVerifierPlonk} from "contracts/state-transition/verifiers/ZKsyncOSVerifierPlonk.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {ZKsyncOSTestnetVerifier} from "contracts/state-transition/verifiers/ZKsyncOSTestnetVerifier.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";

import {Config, DeployUtils, DeployedAddresses, GeneratedData} from "./DeployUtils.s.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

import {L2Bridgehub} from "contracts/bridgehub/L2Bridgehub.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {L2NativeTokenVaultZKOS} from "contracts/bridge/ntv/L2NativeTokenVaultZKOS.sol";
import {L2MessageRoot} from "contracts/bridgehub/L2MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1ZKsyncOSV30Upgrade} from "contracts/upgrades/L1ZKsyncOSV30Upgrade.sol";

abstract contract DeployL1HelperScript is Script, DeployUtils {
    function deployTuppWithContract(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (address implementation, address proxy) {
        (implementation, proxy) = deployTuppWithContractAndProxyAdmin(
            contractName,
            addresses.transparentProxyAdmin,
            isZKBytecode
        );
    }

    function deployTuppWithContractAndProxyAdmin(
        string memory contractName,
        address proxyAdmin,
        bool isZKBytecode
    ) internal returns (address implementation, address proxy) {
        implementation = deployViaCreate2AndNotify(
            getCreationCode(contractName, false),
            getCreationCalldata(contractName, false),
            contractName,
            string.concat(contractName, " Implementation"),
            isZKBytecode
        );

        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, proxyAdmin, getInitializeCalldata(contractName, false)),
            contractName,
            string.concat(contractName, " Proxy"),
            isZKBytecode
        );
        return (implementation, proxy);
    }

    ////////////////////////////// GetContract data  /////////////////////////////////

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            if (compareStrings(contractName, "L1Bridgehub")) {
                return type(L1Bridgehub).creationCode;
            } else if (compareStrings(contractName, "L1ChainAssetHandler")) {
                return type(L1ChainAssetHandler).creationCode;
            } else if (compareStrings(contractName, "L1MessageRoot")) {
                return type(L1MessageRoot).creationCode;
            } else if (compareStrings(contractName, "CTMDeploymentTracker")) {
                return type(CTMDeploymentTracker).creationCode;
            } else if (compareStrings(contractName, "L1Nullifier")) {
                if (config.supportL2LegacySharedBridgeTest) {
                    return type(L1NullifierDev).creationCode;
                } else {
                    return type(L1Nullifier).creationCode;
                }
            } else if (compareStrings(contractName, "L1AssetRouter")) {
                return type(L1AssetRouter).creationCode;
            } else if (compareStrings(contractName, "L1ERC20Bridge")) {
                return type(L1ERC20Bridge).creationCode;
            } else if (compareStrings(contractName, "L1NativeTokenVault")) {
                return type(L1NativeTokenVault).creationCode;
            } else if (compareStrings(contractName, "BridgedStandardERC20")) {
                return type(BridgedStandardERC20).creationCode;
            } else if (compareStrings(contractName, "BridgedTokenBeacon")) {
                return type(UpgradeableBeacon).creationCode;
            } else if (compareStrings(contractName, "Governance")) {
                return type(Governance).creationCode;
            } else if (compareStrings(contractName, "ChainAdminOwnable")) {
                return type(ChainAdminOwnable).creationCode;
            } else if (compareStrings(contractName, "ChainAdmin")) {
                return type(ChainAdmin).creationCode;
            } else if (compareStrings(contractName, "ProxyAdmin")) {
                return type(ProxyAdmin).creationCode;
            } else if (compareStrings(contractName, "RollupDAManager")) {
                return type(RollupDAManager).creationCode;
            } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
                return type(ValidiumL1DAValidator).creationCode;
            } else if (compareStrings(contractName, "Verifier")) {
                if (config.testnetVerifier) {
                    if (config.isZKsyncOS) {
                        return type(ZKsyncOSTestnetVerifier).creationCode;
                    } else {
                        return type(EraTestnetVerifier).creationCode;
                    }
                } else {
                    if (config.isZKsyncOS) {
                        return type(ZKsyncOSDualVerifier).creationCode;
                    } else {
                        return type(EraDualVerifier).creationCode;
                    }
                }
            } else if (compareStrings(contractName, "EraVerifierFflonk")) {
                return type(EraVerifierFflonk).creationCode;
            } else if (compareStrings(contractName, "EraVerifierPlonk")) {
                return type(EraVerifierPlonk).creationCode;
            } else if (compareStrings(contractName, "ZKsyncOSVerifierFflonk")) {
                return type(ZKsyncOSVerifierFflonk).creationCode;
            } else if (compareStrings(contractName, "ZKsyncOSVerifierPlonk")) {
                return type(ZKsyncOSVerifierPlonk).creationCode;
            } else if (compareStrings(contractName, "DefaultUpgrade")) {
                return type(DefaultUpgrade).creationCode;
            } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
                return type(L1GenesisUpgrade).creationCode;
            } else if (compareStrings(contractName, "ValidatorTimelock")) {
                return type(ValidatorTimelock).creationCode;
            } else if (compareStrings(contractName, "EraChainTypeManager")) {
                return type(EraChainTypeManager).creationCode;
            } else if (compareStrings(contractName, "ZKsyncOSChainTypeManager")) {
                return type(ZKsyncOSChainTypeManager).creationCode;
            } else if (compareStrings(contractName, "BytecodesSupplier")) {
                return type(BytecodesSupplier).creationCode;
            } else if (compareStrings(contractName, "ExecutorFacet")) {
                return type(ExecutorFacet).creationCode;
            } else if (compareStrings(contractName, "AdminFacet")) {
                return type(AdminFacet).creationCode;
            } else if (compareStrings(contractName, "MailboxFacet")) {
                return type(MailboxFacet).creationCode;
            } else if (compareStrings(contractName, "GettersFacet")) {
                return type(GettersFacet).creationCode;
            } else if (compareStrings(contractName, "DiamondInit")) {
                return type(DiamondInit).creationCode;
            } else if (compareStrings(contractName, "ServerNotifier")) {
                return type(ServerNotifier).creationCode;
            } else if (compareStrings(contractName, "UpgradeStageValidator")) {
                return type(UpgradeStageValidator).creationCode;
            } else if (compareStrings(contractName, "L1ZKsyncOSV30Upgrade")) {
                return type(L1ZKsyncOSV30Upgrade).creationCode;
            }
        } else {
            if (compareStrings(contractName, "L2Bridgehub")) {
                return Utils.readZKFoundryBytecodeL1("L2Bridgehub.sol", "L2Bridgehub");
            } else if (compareStrings(contractName, "L2MessageRoot")) {
                return Utils.readZKFoundryBytecodeL1("L2MessageRoot.sol", "L2MessageRoot");
            } else if (compareStrings(contractName, "ICTMDeploymentTracker")) {
                return Utils.readZKFoundryBytecodeL1("ICTMDeploymentTracker.sol", "ICTMDeploymentTracker");
            } else if (compareStrings(contractName, "L2AssetRouter")) {
                return Utils.readZKFoundryBytecodeL1("L2AssetRouter.sol", "L2AssetRouter");
            } else if (compareStrings(contractName, "L1ERC20Bridge")) {
                return Utils.readZKFoundryBytecodeL1("L1ERC20Bridge.sol", "L1ERC20Bridge");
            } else if (compareStrings(contractName, "L2NativeTokenVault")) {
                return Utils.readZKFoundryBytecodeL1("L2NativeTokenVault.sol", "L2NativeTokenVault");
            } else if (compareStrings(contractName, "BridgedStandardERC20")) {
                return Utils.readZKFoundryBytecodeL1("BridgedStandardERC20.sol", "BridgedStandardERC20");
            } else if (compareStrings(contractName, "BridgedTokenBeacon")) {
                return Utils.readZKFoundryBytecodeL1("UpgradeableBeacon.sol", "UpgradeableBeacon");
            } else if (compareStrings(contractName, "BlobVersionedHashRetriever")) {
                return hex"600b600b5f39600b5ff3fe5f358049805f5260205ff3";
            } else if (compareStrings(contractName, "RollupDAManager")) {
                return Utils.readZKFoundryBytecodeL1("RollupDAManager.sol", "RollupDAManager");
            } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
                return Utils.readZKFoundryBytecodeL1("ValidiumL1DAValidator.sol", "ValidiumL1DAValidator");
            } else if (compareStrings(contractName, "Verifier")) {
                if (config.testnetVerifier) {
                    return getCreationCode("EraTestnetVerifier", true);
                } else {
                    return getCreationCode("DualVerifier", true);
                }
            } else if (compareStrings(contractName, "VerifierFflonk")) {
                return Utils.readZKFoundryBytecodeL1("L1VerifierFflonk.sol", "L1VerifierFflonk");
            } else if (compareStrings(contractName, "VerifierPlonk")) {
                return Utils.readZKFoundryBytecodeL1("L1VerifierPlonk.sol", "L1VerifierPlonk");
            } else if (compareStrings(contractName, "DefaultUpgrade")) {
                return Utils.readZKFoundryBytecodeL1("DefaultUpgrade.sol", "DefaultUpgrade");
            } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
                return Utils.readZKFoundryBytecodeL1("L1GenesisUpgrade.sol", "L1GenesisUpgrade");
            } else if (compareStrings(contractName, "ValidatorTimelock")) {
                return Utils.readZKFoundryBytecodeL1("ValidatorTimelock.sol", "ValidatorTimelock");
            } else if (compareStrings(contractName, "Governance")) {
                return Utils.readZKFoundryBytecodeL1("Governance.sol", "Governance");
            } else if (compareStrings(contractName, "ChainAdminOwnable")) {
                return Utils.readZKFoundryBytecodeL1("ChainAdminOwnable.sol", "ChainAdminOwnable");
            } else if (compareStrings(contractName, "AccessControlRestriction")) {
                // TODO(EVM-924): this function is unused
                return Utils.readZKFoundryBytecodeL1("AccessControlRestriction.sol", "AccessControlRestriction");
            } else if (compareStrings(contractName, "ChainAdmin")) {
                return Utils.readZKFoundryBytecodeL1("ChainAdmin.sol", "ChainAdmin");
            } else if (compareStrings(contractName, "ChainTypeManager")) {
                return Utils.readZKFoundryBytecodeL1("ChainTypeManager.sol", "ChainTypeManager");
            } else if (compareStrings(contractName, "BytecodesSupplier")) {
                return Utils.readZKFoundryBytecodeL1("BytecodesSupplier.sol", "BytecodesSupplier");
            } else if (compareStrings(contractName, "ProxyAdmin")) {
                return Utils.readZKFoundryBytecodeL1("ProxyAdmin.sol", "ProxyAdmin");
            } else if (compareStrings(contractName, "ExecutorFacet")) {
                return Utils.readZKFoundryBytecodeL1("Executor.sol", "ExecutorFacet");
            } else if (compareStrings(contractName, "AdminFacet")) {
                return Utils.readZKFoundryBytecodeL1("Admin.sol", "AdminFacet");
            } else if (compareStrings(contractName, "MailboxFacet")) {
                return Utils.readZKFoundryBytecodeL1("Mailbox.sol", "MailboxFacet");
            } else if (compareStrings(contractName, "GettersFacet")) {
                return Utils.readZKFoundryBytecodeL1("Getters.sol", "GettersFacet");
            } else if (compareStrings(contractName, "DiamondInit")) {
                return Utils.readZKFoundryBytecodeL1("DiamondInit.sol", "DiamondInit");
            } else if (compareStrings(contractName, "ServerNotifier")) {
                return Utils.readZKFoundryBytecodeL1("ServerNotifier.sol", "ServerNotifier");
            } else if (compareStrings(contractName, "BeaconProxy")) {
                return Utils.readZKFoundryBytecodeL1("BeaconProxy.sol", "BeaconProxy");
            } else {
                revert(string.concat("Contract ", contractName, " creation code not set"));
            }
        }
        return ContractsBytecodesLib.getCreationCode(contractName, isZKBytecode);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            if (compareStrings(contractName, "L1Bridgehub")) {
                return abi.encodeCall(L1Bridgehub.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "L1MessageRoot")) {
                return abi.encodeCall(L1MessageRoot.initialize, ());
            } else if (compareStrings(contractName, "L1ChainAssetHandler")) {
                return abi.encodeCall(L1ChainAssetHandler.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "CTMDeploymentTracker")) {
                return abi.encodeCall(CTMDeploymentTracker.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "L1Nullifier")) {
                return abi.encodeCall(L1Nullifier.initialize, (config.deployerAddress, 1, 1, 1, 0));
            } else if (compareStrings(contractName, "L1AssetRouter")) {
                return abi.encodeCall(L1AssetRouter.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "L1ERC20Bridge")) {
                return abi.encodeCall(L1ERC20Bridge.initialize, ());
            } else if (compareStrings(contractName, "L1NativeTokenVault")) {
                return
                    abi.encodeCall(
                        L1NativeTokenVault.initialize,
                        (config.ownerAddress, addresses.bridges.bridgedTokenBeacon)
                    );
            } else if (compareStrings(contractName, "EraChainTypeManager")) {
                return
                    abi.encodeCall(
                        IChainTypeManager.initialize,
                        getChainTypeManagerInitializeData(addresses.stateTransition)
                    );
            } else if (compareStrings(contractName, "ZKsyncOSChainTypeManager")) {
                return
                    abi.encodeCall(
                        IChainTypeManager.initialize,
                        getChainTypeManagerInitializeData(addresses.stateTransition)
                    );
            } else if (compareStrings(contractName, "ServerNotifier")) {
                return abi.encodeCall(ServerNotifier.initialize, (msg.sender));
            } else if (compareStrings(contractName, "ValidatorTimelock")) {
                return
                    abi.encodeCall(
                        ValidatorTimelock.initialize,
                        (config.deployerAddress, uint32(config.contracts.validatorTimelockExecutionDelay))
                    );
            } else {
                revert(string.concat("Contract ", contractName, " initialize calldata not set"));
            }
        } else {
            revert(string.concat("Contract ", contractName, " ZK initialize calldata not set"));
        }
    }
}
