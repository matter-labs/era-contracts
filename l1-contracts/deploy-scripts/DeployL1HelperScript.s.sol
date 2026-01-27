// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors
import {Script, console2 as console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {StateTransitionDeployedAddresses} from "./Utils.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
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
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ChainAssetHandler} from "contracts/bridgehub/ChainAssetHandler.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {ContractsBytecodesLib} from "./ContractsBytecodesLib.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IRollupDAManager} from "./interfaces/IRollupDAManager.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {L1VerifierPlonk} from "contracts/state-transition/verifiers/L1VerifierPlonk.sol";
import {L1VerifierFflonk} from "contracts/state-transition/verifiers/L1VerifierFflonk.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";

import {Config, DeployUtils, DeployedAddresses, GeneratedData} from "./DeployUtils.s.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";

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
            if (compareStrings(contractName, "Bridgehub")) {
                return type(Bridgehub).creationCode;
            } else if (compareStrings(contractName, "ChainAssetHandler")) {
                return type(ChainAssetHandler).creationCode;
            } else if (compareStrings(contractName, "MessageRoot")) {
                return type(MessageRoot).creationCode;
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
                    return type(TestnetVerifier).creationCode;
                } else {
                    return type(DualVerifier).creationCode;
                }
            } else if (compareStrings(contractName, "VerifierFflonk")) {
                return type(L1VerifierFflonk).creationCode;
            } else if (compareStrings(contractName, "VerifierPlonk")) {
                return type(L1VerifierPlonk).creationCode;
            } else if (compareStrings(contractName, "DefaultUpgrade")) {
                return type(DefaultUpgrade).creationCode;
            } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
                return type(L1GenesisUpgrade).creationCode;
            } else if (compareStrings(contractName, "ValidatorTimelock")) {
                return type(ValidatorTimelock).creationCode;
            } else if (compareStrings(contractName, "ChainTypeManager")) {
                return type(ChainTypeManager).creationCode;
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
            }
        } else {
            if (compareStrings(contractName, "Verifier")) {
                if (config.testnetVerifier) {
                    return getCreationCode("TestnetVerifier", true);
                } else {
                    return getCreationCode("DualVerifier", true);
                }
            }
        }
        return ContractsBytecodesLib.getCreationCode(contractName, isZKBytecode);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            if (compareStrings(contractName, "Bridgehub")) {
                return abi.encodeCall(Bridgehub.initialize, (config.deployerAddress));
            } else if (compareStrings(contractName, "MessageRoot")) {
                return abi.encodeCall(MessageRoot.initialize, ());
            } else if (compareStrings(contractName, "ChainAssetHandler")) {
                return abi.encodeCall(ChainAssetHandler.initialize, (config.deployerAddress));
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
                        (addresses.governance, addresses.bridges.bridgedTokenBeacon)
                    );
            } else if (compareStrings(contractName, "ChainTypeManager")) {
                return
                    abi.encodeCall(
                        ChainTypeManager.initialize,
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
