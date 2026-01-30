// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {NativeTokenVaultBase} from "contracts/bridge/ntv/NativeTokenVaultBase.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {AddressAliasHelper} from "contracts/vendor/AddressAliasHelper.sol";

import {Call} from "contracts/governance/Common.sol";

import {L2_CHAIN_ASSET_HANDLER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";

import {DefaultCoreUpgrade} from "../default_upgrade/DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "../default_upgrade/DefaultCTMUpgrade.s.sol";

import {IL2V29Upgrade} from "contracts/upgrades/IL2V29Upgrade.sol";
import {L1V29Upgrade} from "contracts/upgrades/L1V29Upgrade.sol";
import {DefaultGatewayUpgrade} from "../default_upgrade/DefaultGatewayUpgrade.s.sol";
import {DeployL1CoreUtils} from "../../ecosystem/DeployL1CoreUtils.s.sol";
import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";

/// @notice Script used for v31 upgrade flow
contract CoreUpgrade_v31 is Script, DefaultCoreUpgrade {
    using stdToml for string;

    /// @notice E2e upgrade generation
    function run() public virtual override {
        // preparePermanentValues();
        initialize(
            "/upgrade-envs/permanent-values/local.toml",
            "/upgrade-envs/v0.31.0-interopB/local.toml",
            vm.envString("V31_UPGRADE_ECOSYSTEM_OUTPUT")
        );

        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    /// todo create in deploy scripts instead of here.
    function preparePermanentValues() public {
        string memory root = vm.projectRoot();
        string memory permanentValuesInputPath = string.concat(root, "/upgrade-envs/permanent-values/local.toml");
        string memory permanentValuesToml = vm.readFile(permanentValuesInputPath);
        string memory outputDeployL1Toml = vm.readFile(string.concat(root, "/script-out/output-deploy-l1.toml"));
        string memory outputDeployCTMToml = vm.readFile(string.concat(root, "/script-out/output-deploy-ctm.toml"));

        bytes32 create2FactorySalt = permanentValuesToml.readBytes32("$.permanent_contracts.create2_factory_salt");
        address create2FactoryAddr;
        if (vm.keyExistsToml(permanentValuesToml, "$.permanent_contracts.create2_factory_addr")) {
            create2FactoryAddr = permanentValuesToml.readAddress("$.permanent_contracts.create2_factory_addr");
        }
        address ctm = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.state_transition_proxy_addr"
        );
        address bytecodesSupplier = outputDeployCTMToml.readAddress(
            "$.deployed_addresses.state_transition.bytecodes_supplier_addr"
        );
        address l1Bridgehub = outputDeployL1Toml.readAddress("$.deployed_addresses.bridgehub.bridgehub_proxy_addr");
        address rollupDAManager = outputDeployCTMToml.readAddress("$.deployed_addresses.l1_rollup_da_manager");
        uint256 eraChainId = outputDeployL1Toml.readUint("$.era_chain_id");

        // Serialize permanent_contracts section
        {
            vm.serializeString("permanent_contracts", "create2_factory_salt", vm.toString(create2FactorySalt));
            string memory permanent_contracts = vm.serializeAddress(
                "permanent_contracts",
                "create2_factory_addr",
                create2FactoryAddr
            );
            vm.serializeString("root", "permanent_contracts", permanent_contracts);
        }

        // Serialize ctm_contracts section
        {
            vm.serializeAddress("ctm_contracts", "ctm_proxy_addr", ctm);
            vm.serializeAddress("ctm_contracts", "rollup_da_manager", rollupDAManager);
            string memory ctm_contracts = vm.serializeAddress(
                "ctm_contracts",
                "l1_bytecodes_supplier_addr",
                bytecodesSupplier
            );
            vm.serializeString("root", "ctm_contracts", ctm_contracts);
        }

        // Serialize core_contracts section
        {
            string memory core_contracts = vm.serializeAddress("core_contracts", "bridgehub_proxy_addr", l1Bridgehub);
            vm.serializeString("root", "core_contracts", core_contracts);
        }

        // Write the final TOML
        string memory outputToml = vm.serializeUint("root", "era_chain_id", eraChainId);
        vm.writeToml(outputToml, permanentValuesInputPath);
    }

    function deployNewEcosystemContractsL1() public virtual override {
        coreAddresses.bridgehub.implementations.bridgehub = deploySimpleContract("L1Bridgehub", false);
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot", false);
        coreAddresses.bridges.implementations.l1Nullifier = deploySimpleContract("L1Nullifier", false);
        coreAddresses.bridges.implementations.l1AssetRouter = deploySimpleContract("L1AssetRouter", false);
        coreAddresses.bridges.implementations.l1NativeTokenVault = deploySimpleContract("L1NativeTokenVault", false);
        (
            coreAddresses.bridgehub.implementations.assetTracker,
            coreAddresses.bridgehub.proxies.assetTracker
        ) = deployTuppWithContract("L1AssetTracker", false);
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = deploySimpleContract(
            "CTMDeploymentTracker",
            false
        );
        coreAddresses.bridgehub.implementations.chainAssetHandler = deploySimpleContract("L1ChainAssetHandler", false);
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender",
            false
        );
        // deploySimpleContract("L1ChainTypeManager", false);

        // Configure AssetTracker connections after deployment
        updateContractConnections();
    }

    /// @notice Configure contract connections after deployment
    /// @dev AssetTracker is new in v31, we initialize it here with deployer as owner, then transfer ownership
    function updateContractConnections() internal {
        console.log("Configuring AssetTracker connections...");

        address assetTrackerProxy = coreAddresses.bridgehub.proxies.assetTracker;
        require(assetTrackerProxy != address(0), "AssetTracker proxy not deployed");

        console.log("AssetTracker proxy:", assetTrackerProxy);
        console.log("Current AssetTracker owner:", Ownable2StepUpgradeable(assetTrackerProxy).owner());
        console.log("Deployer (msg.sender):", msg.sender);

        // Initialize AssetTracker with ChainAssetHandler reference
        // This sets: chainAssetHandler = IChainAssetHandler(BRIDGE_HUB.chainAssetHandler())
        // At this point, deployer is the owner (set in initialize() during proxy deployment)
        console.log("Calling setAddresses() on AssetTracker...");
        vm.broadcast();
        IL1AssetTracker(assetTrackerProxy).setAddresses();
        console.log("AssetTracker.setAddresses() completed");

        // Transfer ownership to the proper owner (governance)
        address properOwner = getOwnerAddress();
        console.log("Transferring AssetTracker ownership from deployer to governance:", properOwner);
        vm.broadcast();
        Ownable2StepUpgradeable(assetTrackerProxy).transferOwnership(properOwner);
        console.log("AssetTracker ownership transfer initiated (pending acceptance by governance)");
    }

    /*//////////////////////////////////////////////////////////////
                          Internal functions
    //////////////////////////////////////////////////////////////*/

    function getCreationCode(
        string memory contractName,
        bool isZKBytecode
    ) internal view virtual override returns (bytes memory) {
        return super.getCreationCode(contractName, isZKBytecode);
    }

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view override returns (bytes memory) {
        return super.getCreationCalldata(contractName, isZKBytecode);
    }

    function deployUsedUpgradeContract() internal returns (address) {
        return deploySimpleContract("SettlementLayerV31Upgrade", false);
    }

    /// @notice Override to properly set deployerAddress in upgrade context
    /// @dev In upgrade scripts, msg.sender is the script address, not the broadcast address
    ///      We need to use tx.origin which is the actual transaction sender (private key holder)
    function initializeL1CoreUtilsConfig() internal override {
        super.initializeL1CoreUtilsConfig();

        // In Forge scripts with vm.broadcast(), msg.sender is the script address,
        // but tx.origin is the address of the private key being used for broadcasts.
        // We need to use tx.origin as the deployer address.
        config.deployerAddress = tx.origin;
        console.log("Overriding deployerAddress in upgrade context:");
        console.log("  msg.sender (script):", msg.sender);
        console.log("  tx.origin (actual deployer):", tx.origin);
        console.log("  config.deployerAddress:", config.deployerAddress);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZkBytecode
    ) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "L1MessageRoot")) {
            return abi.encodeCall(L1MessageRoot.initializeL1V31Upgrade, ());
        } else if (compareStrings(contractName, "L1AssetTracker")) {
            // Initialize AssetTracker with config.deployerAddress which is now properly set
            // to tx.origin (the address of the private key being used for broadcasts)
            console.log("Initializing L1AssetTracker with deployer as owner:", config.deployerAddress);
            return abi.encodeCall(L1AssetTracker.initialize, (config.deployerAddress));
        }
        return super.getInitializeCalldata(contractName, isZkBytecode);
    }

    /// @notice Override to add version-specific governance calls for stage 1
    /// @dev Stage 1 runs after proxy upgrades
    /// @dev Accepts AssetTracker ownership and sets it in NativeTokenVault
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        console.log("Preparing v31-specific stage1 governance calls...");

        // Get NativeTokenVault from AssetRouter
        IL1AssetRouter assetRouter = IL1AssetRouter(coreAddresses.bridges.proxies.l1AssetRouter);
        address ntvProxy = address(assetRouter.nativeTokenVault());
        address assetTrackerProxy = coreAddresses.bridgehub.proxies.assetTracker;

        require(ntvProxy != address(0), "NTV proxy address not found");
        require(assetTrackerProxy != address(0), "AssetTracker proxy address not found");

        console.log("Accepting AssetTracker ownership and setting in NativeTokenVault");
        console.log("NTV address:", ntvProxy);
        console.log("AssetTracker address:", assetTrackerProxy);
        // console.log()

        // Note: AssetTracker.setAddresses() was already called during deployment
        // in updateContractConnections(), and ownership was transferred to governance.
        // Now governance needs to accept the ownership transfer.

        calls = new Call[](2);

        // First, accept ownership of AssetTracker (completes the two-step transfer)
        calls[0] = Call({
            target: assetTrackerProxy,
            value: 0,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ())
        });

        // Then, set AssetTracker reference in NTV
        calls[1] = Call({
            target: ntvProxy,
            value: 0,
            data: abi.encodeCall(L1NativeTokenVault.setAssetTracker, (assetTrackerProxy))
        });

        return calls;
    }

    /// @notice Save v31-specific addresses to output file
    function saveOutputVersionSpecific() public virtual override {
        // Save AssetTracker address for Rust test to read
        vm.writeToml(
            vm.toString(coreAddresses.bridgehub.proxies.assetTracker),
            upgradeConfig.outputPath,
            ".asset_tracker_proxy_addr"
        );
    }
}
