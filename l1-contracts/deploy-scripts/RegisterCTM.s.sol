// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";
import {StateTransitionDeployedAddresses, Utils, L2_BRIDGEHUB_ADDRESS, L2_ASSET_ROUTER_ADDRESS, L2_NATIVE_TOKEN_VAULT_ADDRESS, L2_MESSAGE_ROOT_ADDRESS} from "./Utils.sol";
import {Multicall3} from "contracts/dev-contracts/Multicall3.sol";

import {Call} from "contracts/governance/Common.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";

import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVault} from "contracts/bridge/ntv/INativeTokenVault.sol";
import {AddressHasNoCode} from "./ZkSyncScriptErrors.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";

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
import {L1VerifierPlonk} from "contracts/state-transition/verifiers/L1VerifierPlonk.sol";
import {L1VerifierFflonk} from "contracts/state-transition/verifiers/L1VerifierFflonk.sol";
import {TestnetVerifier} from "contracts/state-transition/verifiers/TestnetVerifier.sol";
import {VerifierParams, IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {L1GenesisUpgrade} from "contracts/upgrades/L1GenesisUpgrade.sol";
import {ChainAdmin} from "contracts/governance/ChainAdmin.sol";
import {AccessControlRestriction} from "contracts/governance/AccessControlRestriction.sol";
import {ValidatorTimelock} from "contracts/state-transition/ValidatorTimelock.sol";
import {L1Bridgehub} from "contracts/bridgehub/L1Bridgehub.sol";
import {L1ChainAssetHandler} from "contracts/bridgehub/L1ChainAssetHandler.sol";
import {L1MessageRoot} from "contracts/bridgehub/L1MessageRoot.sol";
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

    function run() public virtual {
        console.log("Registering CTM");

        runInner(
            "/script-config/config-deploy-l1.toml",
            "/script-out/output-deploy-l1.toml",
            "/script-out/register-ctm-l1.toml",
            true
        );
    }

    function registerCTM(bool shouldSend) public virtual {
        console.log("Registering CTM");

        runInner(
            "/script-config/config-deploy-l1.toml",
            "/script-out/output-deploy-l1.toml",
            "/script-out/register-ctm-l1.toml",
            shouldSend
        );
    }

    function runForTest() public {
        runInnerForTest(vm.envString("L1_CONFIG"), vm.envString("L1_OUTPUT"));
    }

    function getAddresses() public view returns (DeployedAddresses memory) {
        return addresses;
    }

    function getConfig() public view returns (Config memory) {
        return config;
    }

    function runInner(
        string memory inputPath,
        string memory inputPathIfEcosystemDeployedLocally,
        string memory outputPath,
        bool shouldSend
    ) internal {
        string memory root = vm.projectRoot();
        inputPath = string.concat(root, inputPath);
        inputPathIfEcosystemDeployedLocally = string.concat(root, inputPathIfEcosystemDeployedLocally);

        initializeConfig(inputPath);
        initializeConfigIfEcosystemDeployedLocally(inputPathIfEcosystemDeployedLocally);

        registerChainTypeManager(outputPath, shouldSend);
    }

    function runInnerForTest(string memory inputPath, string memory inputPathIfEcosystemDeployedLocally) internal {
        string memory root = vm.projectRoot();
        inputPath = string.concat(root, inputPath);
        inputPathIfEcosystemDeployedLocally = string.concat(root, inputPathIfEcosystemDeployedLocally);

        initializeConfig(inputPath);
        initializeConfigIfEcosystemDeployedLocally(inputPathIfEcosystemDeployedLocally);

        registerChainTypeManagerForTest();
    }

    function registerChainTypeManager(string memory outputPath, bool shouldSend) internal {
        IBridgehub bridgehub = IBridgehub(addresses.bridgehub.bridgehubProxy);

        vm.startBroadcast(msg.sender);
        IGovernance governance = IGovernance(IOwnable(address(bridgehub)).owner());
        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            target: address(bridgehub),
            value: 0,
            data: abi.encodeCall(bridgehub.addChainTypeManager, (addresses.stateTransition.chainTypeManagerProxy))
        });
        ICTMDeploymentTracker ctmDT = ICTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy);
        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        calls[1] = Call({
            target: address(sharedBridge),
            value: 0,
            data: abi.encodeCall(
                sharedBridge.setAssetDeploymentTracker,
                (bytes32(uint256(uint160(addresses.stateTransition.chainTypeManagerProxy))), address(ctmDT))
            )
        });
        calls[2] = Call({
            target: address(ctmDT),
            value: 0,
            data: abi.encodeCall(ctmDT.registerCTMAssetOnL1, (addresses.stateTransition.chainTypeManagerProxy))
        });

        IGovernance.Operation memory operation = IGovernance.Operation({
            calls: calls,
            predecessor: bytes32(0),
            salt: bytes32(uint256(13))
        });

        if (shouldSend) {
            governance.scheduleTransparent(operation, 0);
            // We assume that the total value is 0
            governance.execute{value: 0}(operation);

            console.log("CTM DT whitelisted");
            vm.stopBroadcast();

            bytes32 assetId = bridgehub.ctmAssetIdFromAddress(addresses.stateTransition.chainTypeManagerProxy);
            console.log(
                "CTM in router 1",
                sharedBridge.assetHandlerAddress(assetId),
                bridgehub.ctmAssetIdToAddress(assetId)
            );
        } else {
            saveOutput(Output({governance: address(governance), encodedData: abi.encode(calls)}), outputPath);
        }
    }
    function registerChainTypeManagerForTest() internal {
        IBridgehub bridgehub = IBridgehub(addresses.bridgehub.bridgehubProxy);
        vm.startBroadcast(msg.sender);
        bridgehub.addChainTypeManager(addresses.stateTransition.chainTypeManagerProxy);
        console.log("ChainTypeManager registered");
        ICTMDeploymentTracker ctmDT = ICTMDeploymentTracker(addresses.bridgehub.ctmDeploymentTrackerProxy);
        IL1AssetRouter sharedBridge = IL1AssetRouter(addresses.bridges.l1AssetRouterProxy);
        sharedBridge.setAssetDeploymentTracker(
            bytes32(uint256(uint160(addresses.stateTransition.chainTypeManagerProxy))),
            address(ctmDT)
        );
        console.log("CTM DT whitelisted");

        ctmDT.registerCTMAssetOnL1(addresses.stateTransition.chainTypeManagerProxy);
        vm.stopBroadcast();
        console.log("CTM registered in CTMDeploymentTracker");

        bytes32 assetId = bridgehub.ctmAssetIdFromAddress(addresses.stateTransition.chainTypeManagerProxy);
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
        // Unused boilterplate for inheriting DeployUtils
        revert("unimplemented");
    }

    function deployTuppWithContractAndProxyAdmin(
        string memory contractName,
        address proxyAdmin,
        bool isZKBytecode
    ) internal returns (address implementation, address proxy) {
        // Unused boilterplate for inheriting DeployUtils
        revert("unimplemented");
    }

    /// @notice Get new facet cuts
    function getFacetCuts(
        StateTransitionDeployedAddresses memory stateTransition
    ) internal virtual override returns (FacetCut[] memory facetCuts) {
        // Unused boilterplate for inheriting DeployUtils
        revert("unimplemented");
    }

    ////////////////////////////// GetContract data  /////////////////////////////////

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        // Unused boilterplate for inheriting DeployUtils
        revert("unimplemented");
    }

    function getInitializeCalldata(string memory contractName) internal virtual override returns (bytes memory) {
        // Unused boilterplate for inheriting DeployUtils
        revert("unimplemented");
    }

    // add this to be excluded from coverage report
    function test() internal virtual override {}
}
