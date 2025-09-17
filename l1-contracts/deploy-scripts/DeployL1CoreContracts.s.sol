// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {FacetCut, StateTransitionDeployedAddresses} from "./Utils.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {IL1Nullifier, L1Nullifier} from "contracts/bridge/L1Nullifier.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {IL1ERC20Bridge} from "contracts/bridge/interfaces/IL1ERC20Bridge.sol";
import {ICTMDeploymentTracker} from "contracts/bridgehub/ICTMDeploymentTracker.sol";
import {IMessageRoot} from "contracts/bridgehub/IMessageRoot.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {DualVerifier} from "contracts/state-transition/verifiers/DualVerifier.sol";
import {VerifierPlonk} from "contracts/state-transition/verifiers/VerifierPlonk.sol";
import {VerifierFflonk} from "contracts/state-transition/verifiers/VerifierFflonk.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {IVerifier, VerifierParams} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
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

import {Config, DeployedAddresses} from "./DeployUtils.s.sol";
import {DeployL1HelperScript} from "./DeployL1HelperScript.s.sol";

contract DeployL1CoreContractsScript is Script, DeployL1HelperScript {
    using stdToml for string;

    function run() public virtual {
        console.log("Deploying L1 contracts");

        runInner("/script-config/config-deploy-l1.toml", "/script-out/output-deploy-l1.toml");
    }

    function runForTest() public {
        runInner(vm.envString("L1_CONFIG"), vm.envString("L1_OUTPUT"));

        // In the production environment, there will be a separate script dedicated to accepting the adminship
        // but for testing purposes we'll have to do it here.
        Bridgehub bridgehub = Bridgehub(addresses.bridgehub.bridgehubProxy);
        vm.broadcast(addresses.chainAdmin);
        bridgehub.acceptAdmin();
    }

    function getAddresses() public view returns (DeployedAddresses memory) {
        return addresses;
    }

    function getConfig() public view returns (Config memory) {
        return config;
    }

    function runInner(string memory inputPath, string memory outputPath) internal {
        string memory root = vm.projectRoot();
        inputPath = string.concat(root, inputPath);
        outputPath = string.concat(root, outputPath);

        initializeConfig(inputPath);

        instantiateCreate2Factory();

        (addresses.governance) = deploySimpleContract("Governance", false);
        (addresses.chainAdmin) = deploySimpleContract("ChainAdminOwnable", false);
        addresses.transparentProxyAdmin = deployWithCreate2AndOwner("ProxyAdmin", addresses.governance, false);

        // The single owner chainAdmin does not have a separate control restriction contract.
        // We set to it to zero explicitly so that it is clear to the reader.
        addresses.accessControlRestrictionAddress = address(0);
        (addresses.bridgehub.bridgehubImplementation, addresses.bridgehub.bridgehubProxy) = deployTuppWithContract(
            "Bridgehub",
            false
        );
        (addresses.bridgehub.messageRootImplementation, addresses.bridgehub.messageRootProxy) = deployTuppWithContract(
            "MessageRoot",
            false
        );

        (addresses.bridges.l1NullifierImplementation, addresses.bridges.l1NullifierProxy) = deployTuppWithContract(
            "L1Nullifier",
            false
        );
        (addresses.bridges.l1AssetRouterImplementation, addresses.bridges.l1AssetRouterProxy) = deployTuppWithContract(
            "L1AssetRouter",
            false
        );
        (addresses.bridges.bridgedStandardERC20Implementation) = deploySimpleContract("BridgedStandardERC20", false);
        addresses.bridges.bridgedTokenBeacon = deployWithCreate2AndOwner(
            "BridgedTokenBeacon",
            config.ownerAddress,
            false
        );
        (
            addresses.vaults.l1NativeTokenVaultImplementation,
            addresses.vaults.l1NativeTokenVaultProxy
        ) = deployTuppWithContract("L1NativeTokenVault", false);
        setL1NativeTokenVaultParams();

        (addresses.bridges.erc20BridgeImplementation, addresses.bridges.erc20BridgeProxy) = deployTuppWithContract(
            "L1ERC20Bridge",
            false
        );
        updateSharedBridge();
        (
            addresses.bridgehub.ctmDeploymentTrackerImplementation,
            addresses.bridgehub.ctmDeploymentTrackerProxy
        ) = deployTuppWithContract("CTMDeploymentTracker", false);

        (
            addresses.bridgehub.chainAssetHandlerImplementation,
            addresses.bridgehub.chainAssetHandlerProxy
        ) = deployTuppWithContract("ChainAssetHandler", false);
        setBridgehubParams();

        updateOwners();

        saveOutput(outputPath);
    }

    function setBridgehubParams() internal {
        IBridgehub bridgehub = IBridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addTokenAssetId(bridgehub.baseTokenAssetId(config.eraChainId));
        bridgehub.setAddresses(
            addresses.bridges.l1AssetRouterProxy,
            ICTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy),
            IMessageRoot(addresses.bridgehub.messageRootProxy),
            addresses.bridgehub.chainAssetHandlerProxy
        );
        vm.stopBroadcast();
        console.log("SharedBridge registered");
    }

    function updateSharedBridge() internal {
        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        vm.broadcast(msg.sender);
        sharedBridge.setL1Erc20Bridge(IL1ERC20Bridge(addresses.bridges.erc20BridgeProxy));
        console.log("SharedBridge updated with ERC20Bridge address");
    }

    function setL1NativeTokenVaultParams() internal {
        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        IL1Nullifier l1Nullifier = IL1Nullifier(addresses.bridges.l1NullifierProxy);
        // Ownable ownable = Ownable(addresses.bridges.l1AssetRouterProxy);
        vm.broadcast(msg.sender);
        sharedBridge.setNativeTokenVault(INativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1NativeTokenVault(IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy));
        vm.broadcast(msg.sender);
        l1Nullifier.setL1AssetRouter(addresses.bridges.l1AssetRouterProxy);

        vm.broadcast(msg.sender);
        IL1NativeTokenVault(addresses.vaults.l1NativeTokenVaultProxy).registerEthToken();
    }

    function updateOwners() internal {
        vm.startBroadcast(msg.sender);

        IBridgehub bridgehub = IBridgehub(addresses.bridgehub.bridgehubProxy);
        IOwnable(address(bridgehub)).transferOwnership(addresses.governance);
        bridgehub.setPendingAdmin(addresses.chainAdmin);

        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        IOwnable(address(sharedBridge)).transferOwnership(addresses.governance);

        ICTMDeploymentTracker ctmDeploymentTracker = ICTMDeploymentTracker(
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );
        IOwnable(address(ctmDeploymentTracker)).transferOwnership(addresses.governance);

        vm.stopBroadcast();
        console.log("Owners updated");
    }

    function saveOutput(string memory outputPath) internal virtual {
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", addresses.bridgehub.bridgehubProxy);
        vm.serializeAddress("bridgehub", "bridgehub_implementation_addr", addresses.bridgehub.bridgehubImplementation);
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            addresses.bridgehub.chainAssetHandlerImplementation
        );
        vm.serializeAddress("bridgehub", "chain_asset_handler_proxy_addr", addresses.bridgehub.chainAssetHandlerProxy);
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
            addresses.bridgehub.ctmDeploymentTrackerProxy
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_implementation_addr",
            addresses.bridgehub.ctmDeploymentTrackerImplementation
        );
        vm.serializeAddress("bridgehub", "message_root_proxy_addr", addresses.bridgehub.messageRootProxy);
        string memory bridgehub = vm.serializeAddress(
            "bridgehub",
            "message_root_implementation_addr",
            addresses.bridgehub.messageRootImplementation
        );

        vm.serializeAddress("bridges", "erc20_bridge_implementation_addr", addresses.bridges.erc20BridgeImplementation);
        vm.serializeAddress("bridges", "erc20_bridge_proxy_addr", addresses.bridges.erc20BridgeProxy);
        vm.serializeAddress("bridges", "l1_nullifier_implementation_addr", addresses.bridges.l1NullifierImplementation);
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", addresses.bridges.l1NullifierProxy);
        vm.serializeAddress(
            "bridges",
            "shared_bridge_implementation_addr",
            addresses.bridges.l1AssetRouterImplementation
        );
        string memory bridges = vm.serializeAddress(
            "bridges",
            "shared_bridge_proxy_addr",
            addresses.bridges.l1AssetRouterProxy
        );

        vm.serializeAddress("deployed_addresses", "governance_addr", addresses.governance);
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin_addr", addresses.transparentProxyAdmin);
        vm.serializeAddress("deployed_addresses", "chain_admin", addresses.chainAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "access_control_restriction_addr",
            addresses.accessControlRestrictionAddress
        );
        vm.serializeString("deployed_addresses", "bridgehub", bridgehub);
        vm.serializeString("deployed_addresses", "bridges", bridges);

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_addr",
            addresses.vaults.l1NativeTokenVaultProxy
        );

        vm.serializeAddress("root", "create2_factory_addr", create2FactoryState.create2FactoryAddress);
        vm.serializeBytes32("root", "create2_factory_salt", create2FactoryParams.factorySalt);
        vm.serializeUint("root", "l1_chain_id", config.l1ChainId);
        vm.serializeUint("root", "era_chain_id", config.eraChainId);
        vm.serializeAddress("root", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        string memory toml = vm.serializeAddress("root", "owner_address", config.ownerAddress);

        vm.writeToml(toml, outputPath);
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
