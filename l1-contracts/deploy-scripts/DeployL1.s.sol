// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {DeployL1Abstract} from "./DeployL1Abstract.s.sol";
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
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {CTMDeploymentTracker} from "contracts/bridgehub/CTMDeploymentTracker.sol";
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

contract DeployL1Script is Script, DeployL1Abstract {
    function deployTuppWithContract(
        string memory contractName
    ) internal virtual override returns (address implementation, address proxy) {
        implementation = deployViaCreate2AndNotify(
            getCreationCode(contractName),
            getCreationCalldata(contractName),
            contractName,
            string.concat(contractName, " Implementation")
        );

        proxy = deployViaCreate2AndNotify(
            type(TransparentUpgradeableProxy).creationCode,
            abi.encode(implementation, addresses.transparentProxyAdmin, getInitializeCalldata(contractName)),
            contractName,
            string.concat(contractName, " Proxy")
        );
        return (implementation, proxy);
    }

    function saveDiamondSelectors() public {
        AdminFacet adminFacet = new AdminFacet(1, RollupDAManager(address(0)));
        GettersFacet gettersFacet = new GettersFacet();
        MailboxFacet mailboxFacet = new MailboxFacet(1, 1);
        ExecutorFacet executorFacet = new ExecutorFacet(1);
        bytes4[] memory adminFacetSelectors = Utils.getAllSelectors(address(adminFacet).code);
        bytes4[] memory gettersFacetSelectors = Utils.getAllSelectors(address(gettersFacet).code);
        bytes4[] memory mailboxFacetSelectors = Utils.getAllSelectors(address(mailboxFacet).code);
        bytes4[] memory executorFacetSelectors = Utils.getAllSelectors(address(executorFacet).code);

        string memory root = vm.projectRoot();
        string memory outputPath = string.concat(root, "/script-out/diamond-selectors.toml");

        bytes memory adminFacetSelectorsBytes = abi.encode(adminFacetSelectors);
        bytes memory gettersFacetSelectorsBytes = abi.encode(gettersFacetSelectors);
        bytes memory mailboxFacetSelectorsBytes = abi.encode(mailboxFacetSelectors);
        bytes memory executorFacetSelectorsBytes = abi.encode(executorFacetSelectors);

        vm.serializeBytes("diamond_selectors", "admin_facet_selectors", adminFacetSelectorsBytes);
        vm.serializeBytes("diamond_selectors", "getters_facet_selectors", gettersFacetSelectorsBytes);
        vm.serializeBytes("diamond_selectors", "mailbox_facet_selectors", mailboxFacetSelectorsBytes);
        string memory toml = vm.serializeBytes(
            "diamond_selectors",
            "executor_facet_selectors",
            executorFacetSelectorsBytes
        );

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

    function getCreationCode(string memory contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "ChainRegistrar")) {
            return type(ChainRegistrar).creationCode;
        } else if (compareStrings(contractName, "Bridgehub")) {
            return type(Bridgehub).creationCode;
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
        } else if (compareStrings(contractName, "BlobVersionedHashRetriever")) {
            return hex"600b600b5f39600b5ff3fe5f358049805f5260205ff3";
        } else if (compareStrings(contractName, "RollupDAManager")) {
            return type(RollupDAManager).creationCode;
        } else if (compareStrings(contractName, "RollupL1DAValidator")) {
            return Utils.readRollupDAValidatorBytecode();
        } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
            return type(ValidiumL1DAValidator).creationCode;
        } else if (compareStrings(contractName, "AvailL1DAValidator")) {
            return Utils.readAvailL1DAValidatorBytecode();
        } else if (compareStrings(contractName, "DummyAvailBridge")) {
            return Utils.readDummyAvailBridgeBytecode();
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
        } else if (compareStrings(contractName, "RollupL1DAValidator")) {
            return Utils.readRollupDAValidatorBytecode();
        } else if (compareStrings(contractName, "ValidiumL1DAValidator")) {
            return type(ValidiumL1DAValidator).creationCode;
        } else if (compareStrings(contractName, "AvailL1DAValidator")) {
            return Utils.readAvailL1DAValidatorBytecode();
        } else if (compareStrings(contractName, "DummyAvailBridge")) {
            return Utils.readDummyAvailBridgeBytecode();
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
        } else {
            revert(string.concat("Contract ", contractName, " creation code not set"));
        }
    }

    function getInitializeCalldata(
        string memory contractName
    ) internal virtual override(DeployL1Abstract) returns (bytes memory) {
        if (compareStrings(contractName, "Bridgehub")) {
            return abi.encodeCall(Bridgehub.initialize, (config.deployerAddress));
        } else if (compareStrings(contractName, "MessageRoot")) {
            return abi.encodeCall(MessageRoot.initialize, ());
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
        } else {
            return super.getInitializeCalldata(contractName);
        }
    }

    function test() internal virtual override(DeployL1Abstract) {}
}
