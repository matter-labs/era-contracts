// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";
import {IL1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IAssetRouterBase} from "contracts/bridge/asset-router/IAssetRouterBase.sol";
import {IValidatorTimelock} from "contracts/state-transition/IValidatorTimelock.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {IRollupDAManager} from "./interfaces/IRollupDAManager.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {L2LegacySharedBridgeTestHelper} from "./L2LegacySharedBridgeTestHelper.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {StateTransitionDeployedAddresses, Utils, FacetCut, Action} from "./Utils.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {VerifierPlonk} from "contracts/state-transition/verifiers/VerifierPlonk.sol";
import {VerifierFflonk} from "contracts/state-transition/verifiers/VerifierFflonk.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {ChainAssetHandler} from "contracts/bridgehub/ChainAssetHandler.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {GettersFacet} from "contracts/state-transition/chain-deps/facets/Getters.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {ChainTypeManagerInitializeData, ChainCreationParams} from "contracts/state-transition/IChainTypeManager.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {FeeParams, PubdataPricingMode} from "contracts/state-transition/chain-deps/ZKChainStorage.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1ERC20Bridge} from "contracts/bridge/L1ERC20Bridge.sol";
import {L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {L1NullifierDev} from "contracts/dev-contracts/L1NullifierDev.sol";
import {DiamondProxy} from "contracts/state-transition/chain-deps/DiamondProxy.sol";
import {BridgedStandardERC20} from "contracts/bridge/BridgedStandardERC20.sol";
import {ChainRegistrar} from "contracts/chain-registrar/ChainRegistrar.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {L2LegacySharedBridgeTestHelper} from "./L2LegacySharedBridgeTestHelper.sol";
import {ChainAdminOwnable} from "contracts/governance/ChainAdminOwnable.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";

import {DeployUtils, GeneratedData, Config, DeployedAddresses} from "./DeployUtils.s.sol";
import {ContractsBytecodesLib} from "./ContractsBytecodesLib.sol";

contract RegisterCTM is Script, DeployUtils {
    using stdToml for string;

    struct Output {
        address governance;
        bytes encodedData;
    }

    function registerCTM(address bridgehub, address chainTypeManagerProxy, bool shouldSend) public virtual {
        console.log("Registering CTM for L1 contracts");

        runInner("/script-out/register-ctm-l1.toml", bridgehub, chainTypeManagerProxy, shouldSend);
    }

    function runForTest(address bridgehub, address chainTypeManagerProxy) public {
        registerChainTypeManagerForTest(bridgehub, chainTypeManagerProxy);
    }

    function runInner(
        string memory outputPath,
        address bridgehub,
        address chainTypeManagerProxy,
        bool shouldSend
    ) internal {
        string memory root = vm.projectRoot();

        registerChainTypeManager(outputPath, bridgehub, chainTypeManagerProxy, shouldSend);
    }

    function registerChainTypeManager(
        string memory outputPath,
        address bridgehubProxy,
        address chainTypeManagerProxy,
        bool shouldSend
    ) internal {
        IBridgehub bridgehub = IBridgehub(bridgehubProxy);
        address ctmDeploymentTrackerProxy = address(bridgehub.l1CtmDeployer());
        address l1AssetRouterProxy = bridgehub.assetRouter();

        vm.startBroadcast(msg.sender);
        IGovernance governance = IGovernance(IOwnable(bridgehubProxy).owner());
        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            target: bridgehubProxy,
            value: 0,
            data: abi.encodeCall(bridgehub.addChainTypeManager, (chainTypeManagerProxy))
        });
        ICTMDeploymentTracker ctmDT = ICTMDeploymentTracker(ctmDeploymentTrackerProxy);
        IL1AssetRouter sharedBridge = IL1AssetRouter(l1AssetRouterProxy);
        calls[1] = Call({
            target: address(sharedBridge),
            value: 0,
            data: abi.encodeCall(
                sharedBridge.setAssetDeploymentTracker,
                (bytes32(uint256(uint160(chainTypeManagerProxy))), address(ctmDT))
            )
        });
        calls[2] = Call({
            target: address(ctmDT),
            value: 0,
            data: abi.encodeCall(ctmDT.registerCTMAssetOnL1, (chainTypeManagerProxy))
        });

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(0)
        });

        if (shouldSend) {
            governance.scheduleTransparent(operation, 0);
            // We assume that the total value is 0
            governance.execute{value: 0}(operation);

            console.log("CTM DT whitelisted");
            vm.stopBroadcast();

            bytes32 assetId = bridgehub.ctmAssetIdFromAddress(chainTypeManagerProxy);
            console.log(
                "CTM in router 1",
                sharedBridge.assetHandlerAddress(assetId),
                bridgehub.ctmAssetIdToAddress(assetId)
            );
        }
        saveOutput(Output({governance: address(governance), encodedData: abi.encode(calls)}), outputPath);
    }

    function registerChainTypeManagerForTest(address bridgehubProxy, address chainTypeManagerProxy) internal {
        IBridgehub bridgehub = IBridgehub(bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addChainTypeManager(chainTypeManagerProxy);
        console.log("ChainTypeManager registered");
        address ctmDeploymentTrackerProxy = address(bridgehub.l1CtmDeployer());
        address l1AssetRouterProxy = bridgehub.assetRouter();
        ICTMDeploymentTracker ctmDT = ICTMDeploymentTracker(ctmDeploymentTrackerProxy);
        IL1AssetRouter sharedBridge = IL1AssetRouter(l1AssetRouterProxy);
        sharedBridge.setAssetDeploymentTracker(bytes32(uint256(uint160(chainTypeManagerProxy))), address(ctmDT));
        console.log("CTM DT whitelisted");

        ctmDT.registerCTMAssetOnL1(chainTypeManagerProxy);
        vm.stopBroadcast();
        console.log("CTM registered in CTMDeploymentTracker");

        bytes32 assetId = bridgehub.ctmAssetIdFromAddress(chainTypeManagerProxy);
        console.log(
            "CTM in router 1",
            sharedBridge.assetHandlerAddress(assetId),
            bridgehub.ctmAssetIdToAddress(assetId)
        );
    }

    function saveOutput(Output memory output, string memory outputPath) internal {
        vm.serializeAddress("root", "admin_address", output.governance);
        string memory toml = vm.serializeBytes("root", "encoded_data", output.encodedData);
        string memory path = string.concat(vm.projectRoot(), outputPath);
        vm.writeToml(toml, path);
    }

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
            getCreationCode(contractName, isZKBytecode),
            getCreationCalldata(contractName, isZKBytecode),
            contractName,
            string.concat(contractName, " Implementation"),
            isZKBytecode
        );

        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, proxyAdmin, getInitializeCalldata(contractName, isZKBytecode)),
            contractName,
            string.concat(contractName, " Proxy"),
            isZKBytecode
        );
        return (implementation, proxy);
    }

    /// @notice Get new facet cuts
    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (FacetCut[] memory facetCuts) {
        // Note: we use the provided stateTransition for the facet address, but not to get the selectors, as we use this feature for Gateway, which we cannot query.
        // If we start to use different selectors for Gateway, we should change this.
        facetCuts = new FacetCut[](4);
        facetCuts[0] = FacetCut({
            facet: stateTransition.adminFacet,
            action: Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.adminFacet.code)
        });
        facetCuts[1] = FacetCut({
            facet: stateTransition.gettersFacet,
            action: Action.Add,
            isFreezable: false,
            selectors: Utils.getAllSelectors(addresses.stateTransition.gettersFacet.code)
        });
        facetCuts[2] = FacetCut({
            facet: stateTransition.mailboxFacet,
            action: Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.mailboxFacet.code)
        });
        facetCuts[3] = FacetCut({
            facet: stateTransition.executorFacet,
            action: Action.Add,
            isFreezable: true,
            selectors: Utils.getAllSelectors(addresses.stateTransition.executorFacet.code)
        });
    }

    ////////////////////////////// GetContract data  /////////////////////////////////

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        if (!isZKBytecode) {
            if (compareStrings(contractName, "ChainRegistrar")) {
                return type(ChainRegistrar).creationCode;
            } else if (compareStrings(contractName, "Bridgehub")) {
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
                return type(VerifierFflonk).creationCode;
            } else if (compareStrings(contractName, "VerifierPlonk")) {
                return type(VerifierPlonk).creationCode;
            } else if (compareStrings(contractName, "DefaultUpgrade")) {
                return type(DefaultUpgrade).creationCode;
            } else if (compareStrings(contractName, "L1GenesisUpgrade")) {
                return type(L1GenesisUpgrade).creationCode;
            } else if (compareStrings(contractName, "ValidatorTimelock")) {
                return type(ValidatorTimelock).creationCode;
            } else if (compareStrings(contractName, "Governance")) {
                return type(Governance).creationCode;
            } else if (compareStrings(contractName, "ChainAdminOwnable")) {
                return type(ChainAdminOwnable).creationCode;
            } else if (compareStrings(contractName, "AccessControlRestriction")) {
                // TODO(EVM-924): this function is unused
                return type(AccessControlRestriction).creationCode;
            } else if (compareStrings(contractName, "ChainAdmin")) {
                return type(ChainAdmin).creationCode;
            } else if (compareStrings(contractName, "ChainTypeManager")) {
                return type(ChainTypeManager).creationCode;
            } else if (compareStrings(contractName, "BytecodesSupplier")) {
                return type(BytecodesSupplier).creationCode;
            } else if (compareStrings(contractName, "ProxyAdmin")) {
                return type(ProxyAdmin).creationCode;
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
                        (config.ownerAddress, addresses.bridges.bridgedTokenBeacon)
                    );
            } else if (compareStrings(contractName, "ChainTypeManager")) {
                return
                    abi.encodeCall(
                        ChainTypeManager.initialize,
                        getChainTypeManagerInitializeData(addresses.stateTransition)
                    );
            } else if (compareStrings(contractName, "ChainRegistrar")) {
                return
                    abi.encodeCall(
                        ChainRegistrar.initialize,
                        (addresses.bridgehub.bridgehubProxy, config.deployerAddress, config.ownerAddress)
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

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
