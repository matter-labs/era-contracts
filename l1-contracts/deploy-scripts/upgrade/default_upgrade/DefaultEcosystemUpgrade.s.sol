// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts-v4/proxy/beacon/UpgradeableBeacon.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Call} from "contracts/governance/Common.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {DeployL1CoreUtils} from "../../ecosystem/DeployL1CoreUtils.s.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {BridgehubAddresses, BridgesDeployedAddresses} from "../../ecosystem/DeployL1CoreUtils.s.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";

/// @notice Script used for default ecosystem upgrade flow should be run as a first for the upgrade.
/// @dev For more complex upgrades, this script can be inherited and its functionality overridden if needed.
contract DefaultEcosystemUpgrade is Script, DeployL1CoreUtils {
    using stdToml for string;

    /// @notice Internal state of the upgrade script
    struct EcosystemUpgradeConfig {
        bool initialized;
        string outputPath;
    }

    struct AdditionalConfigParams {
        uint256 newProtocolVersion;
    }
    AdditionalConfigParams internal additionalConfig;

    EcosystemUpgradeConfig internal upgradeConfig;

    function initialize(
        string memory permanentValuesInputPath,
        string memory upgradeInputPath,
        string memory newConfigPath,
        string memory _outputPath
    ) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);
        permanentValuesInputPath = string.concat(root, permanentValuesInputPath);
        upgradeInputPath = string.concat(root, upgradeInputPath);
        console.log("permanentValuesInputPath", permanentValuesInputPath);
        console.log("root", root);

        initializeConfig(permanentValuesInputPath, upgradeInputPath, newConfigPath);
        instantiateCreate2Factory();

        console.log("Initialized config from %s", newConfigPath);
        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    /// @notice Full default upgrade preparation flow
    function prepareEcosystemUpgrade() public virtual {
        deployNewEcosystemContractsL1();
        console.log("Ecosystem contracts are deployed!");
    }

    /// @notice Deploy everything that should be deployed
    function deployNewEcosystemContractsL1() public virtual {}

    /// @notice E2e upgrade generation
    function run() public virtual {
        initialize(
            vm.envString("PERMANENT_VALUES_INPUT"),
            vm.envString("UPGRADE_INPUT"),
            vm.envString("UPGRADE_ECOSYSTEM_INPUT"),
            vm.envString("UPGRADE_ECOSYSTEM_OUTPUT")
        );
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    function setOwners(address owner) public virtual {
        config.ownerAddress = owner;
    }

    function getNewProtocolVersion() public virtual returns (uint256) {
        return additionalConfig.newProtocolVersion;
    }

    function getProtocolUpgradeNonce() public virtual returns (uint256) {
        return (getNewProtocolVersion() >> 32);
    }

    function getOldProtocolDeadline() public virtual returns (uint256) {
        // Note, that it is this way by design, on stage2 it
        // will be set to 0
        return type(uint256).max;
    }

    function getDiscoveredBridgehub() public view returns (BridgehubAddresses memory) {
        return coreAddresses.bridgehub;
    }

    function initializeConfig(
        string memory permanentValuesInputPath,
        string memory upgradeInputPath,
        string memory newConfigPath
    ) public virtual {
        string memory permanentValuesToml = vm.readFile(permanentValuesInputPath);
        string memory upgradeToml = vm.readFile(upgradeInputPath);
        string memory toml = vm.readFile(newConfigPath);

        (address create2FactoryAddr, bytes32 create2FactorySalt) = getPermanentValues(permanentValuesInputPath);
        _initCreate2FactoryParams(create2FactoryAddr, create2FactorySalt);
        //        config.supportL2LegacySharedBridgeTest = permanentValuesToml.readBool("$.support_l2_legacy_shared_bridge_test");
        additionalConfig.newProtocolVersion = upgradeToml.readUint("$.contracts.new_protocol_version");

        coreAddresses.bridgehub.proxies.bridgehub = permanentValuesToml.readAddress(
            "$.core_contracts.bridgehub_proxy_addr"
        );
        setAddressesBasedOnBridgehub();
        initializeL1CoreUtilsConfig();
    }

    function initializeL1CoreUtilsConfig() internal virtual {
        L1AssetRouter assetRouter = L1AssetRouter(coreAddresses.bridges.proxies.l1AssetRouter);
        L1Bridgehub bridgehub = L1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub);
        Governance governance = Governance(payable(coreAddresses.shared.governance));
        config.l1ChainId = block.chainid;
        config.deployerAddress = msg.sender;
        config.eraChainId = assetRouter.ERA_CHAIN_ID();
        config.eraDiamondProxyAddress = bridgehub.getZKChain(assetRouter.ERA_CHAIN_ID());

        config.ownerAddress = assetRouter.owner();

        config.contracts.governanceSecurityCouncilAddress = governance.securityCouncil();
        // config.contracts.governanceMinDelay = governance.minDelay();

        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();

        config.tokens.tokenWethAddress = assetRouter.L1_WETH_TOKEN();
    }

    function setAddressesBasedOnBridgehub() internal virtual {
        coreAddresses = AddressIntrospector.getCoreDeployedAddresses(coreAddresses.bridgehub.proxies.bridgehub);
    }

    function saveOutput(string memory outputPath) internal virtual {
        // Serialize bridgehub addresses
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", coreAddresses.bridgehub.proxies.bridgehub);
        vm.serializeAddress(
            "bridgehub",
            "bridgehub_implementation_addr",
            coreAddresses.bridgehub.implementations.bridgehub
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_implementation_addr",
            coreAddresses.bridgehub.implementations.ctmDeploymentTracker
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            coreAddresses.bridgehub.implementations.chainAssetHandler
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_proxy_addr",
            coreAddresses.bridgehub.proxies.chainAssetHandler
        );
        vm.serializeAddress("bridgehub", "message_root_proxy_addr", coreAddresses.bridgehub.proxies.messageRoot);
        string memory bridgehubSerialized = vm.serializeAddress(
            "bridgehub",
            "message_root_implementation_addr",
            coreAddresses.bridgehub.implementations.messageRoot
        );

        // Serialize bridges addresses
        vm.serializeAddress(
            "bridges",
            "erc20_bridge_implementation_addr",
            coreAddresses.bridges.implementations.erc20Bridge
        );
        vm.serializeAddress("bridges", "erc20_bridge_proxy_addr", coreAddresses.bridges.proxies.erc20Bridge);
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", coreAddresses.bridges.proxies.l1Nullifier);
        vm.serializeAddress(
            "bridges",
            "l1_nullifier_implementation_addr",
            coreAddresses.bridges.implementations.l1Nullifier
        );
        vm.serializeAddress(
            "bridges",
            "l1_asset_router_implementation_addr",
            coreAddresses.bridges.implementations.l1AssetRouter
        );
        vm.serializeAddress("bridges", "l1_asset_router_proxy_addr", coreAddresses.bridges.proxies.l1AssetRouter);
        // TODO: legacy name
        vm.serializeAddress(
            "bridges",
            "shared_bridge_implementation_addr",
            coreAddresses.bridges.implementations.l1AssetRouter
        );
        vm.serializeAddress(
            "bridges",
            "bridged_standard_erc20_impl",
            coreAddresses.bridges.bridgedStandardERC20Implementation
        );

        string memory bridgesSerialized = vm.serializeAddress(
            "bridges",
            "bridged_token_beacon",
            coreAddresses.bridges.bridgedTokenBeacon
        );

        vm.serializeString("deployed_addresses", "bridgehub", bridgehubSerialized);
        vm.serializeString("deployed_addresses", "bridges", bridgesSerialized);
        vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_addr",
            coreAddresses.bridges.proxies.l1NativeTokenVault
        );
        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_implementation_addr",
            coreAddresses.bridges.implementations.l1NativeTokenVault
        );

        string memory toml = vm.serializeString("root", "upgrade_addresses", deployedAddresses);

        vm.writeToml(toml, outputPath);

        saveOutputVersionSpecific();
    }

    function saveOutputVersionSpecific() public virtual {}

    ////////////////////////////// Preparing calls /////////////////////////////////

    function prepareDefaultGovernanceCalls()
        public
        virtual
        returns (Call[] memory stage0Calls, Call[] memory stage1Calls, Call[] memory stage2Calls)
    {
        // Default upgrade is done it 3 stages:
        // 0. Pause migration to/from Gateway
        // 1. Perform upgrade
        // 2. Unpause migration to/from Gateway
        stage0Calls = prepareStage0GovernanceCalls();
        vm.serializeBytes("governance_calls", "stage0_calls", abi.encode(stage0Calls));
        stage1Calls = prepareStage1GovernanceCalls();
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(stage1Calls));
        stage2Calls = prepareStage2GovernanceCalls();

        string memory governanceCallsSerialized = vm.serializeBytes(
            "governance_calls",
            "stage2_calls",
            abi.encode(stage2Calls)
        );

        vm.writeToml(governanceCallsSerialized, upgradeConfig.outputPath, ".governance_calls");
    }

    function prepareDefaultEcosystemAdminCalls() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareUnpauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(coreAddresses.bridgehub.proxies.bridgehub != address(0), "bridgehubProxyAddress is zero in newConfig");

        result = new Call[](1);
        result[0] = Call({
            target: coreAddresses.bridgehub.proxies.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandler.unpauseMigration, ())
        });
    }

    /// @notice The zeroth step of upgrade. By default it just stops gateway migrations
    function prepareStage0GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](3);

        allCalls[0] = preparePauseGatewayMigrationsCall();
        allCalls[1] = prepareVersionSpecificStage0GovernanceCallsL1();
        allCalls[2] = prepareDefaultEcosystemAdminCalls();

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice The first step of upgrade. It upgrades the proxies and sets the new version upgrade
    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](3);

        console.log("prepareStage1GovernanceCalls: prepareUpgradeProxiesCalls");
        allCalls[0] = prepareUpgradeProxiesCalls();
        allCalls[1] = provideSetNewVersionUpgradeCall();
        console.log("prepareStage1GovernanceCalls: prepareGatewaySpecificStage1GovernanceCalls");
        allCalls[2] = prepareVersionSpecificStage1GovernanceCallsL1();

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice The second step of upgrade. By default it unpauses migrations.
    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        Call[][] memory allCalls = new Call[][](2);

        allCalls[0] = prepareVersionSpecificStage2GovernanceCallsL1();
        allCalls[1] = prepareUnpauseGatewayMigrationsCall();

        calls = UpgradeUtils.mergeCallsArray(allCalls);
    }

    function prepareVersionSpecificStage0GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    function prepareVersionSpecificStage2GovernanceCallsL1() public virtual returns (Call[] memory calls) {
        // Empty by default.
        return calls;
    }

    // TODO looks like we have to set it for bridgehub too
    function provideSetNewVersionUpgradeCall() public virtual returns (Call[] memory calls) {}

    function preparePauseGatewayMigrationsCall() public view virtual returns (Call[] memory result) {
        require(coreAddresses.bridgehub.proxies.chainAssetHandler != address(0), "chainAssetHandlerProxy is zero");

        result = new Call[](1);
        result[0] = Call({
            target: coreAddresses.bridgehub.proxies.chainAssetHandler,
            value: 0,
            data: abi.encodeCall(IChainAssetHandler.pauseMigration, ())
        });
    }

    /// @notice Update implementations in proxies
    function prepareUpgradeProxiesCalls() public virtual returns (Call[] memory calls) {
        calls = new Call[](7);

        calls[0] = _buildCallProxyUpgrade(
            coreAddresses.bridgehub.proxies.bridgehub,
            coreAddresses.bridgehub.implementations.bridgehub
        );

        // Note, that we do not need to run the initializer
        calls[1] = _buildCallProxyUpgrade(
            coreAddresses.bridges.proxies.l1Nullifier,
            coreAddresses.bridges.implementations.l1Nullifier
        );

        calls[2] = _buildCallProxyUpgrade(
            coreAddresses.bridges.proxies.l1AssetRouter,
            coreAddresses.bridges.implementations.l1AssetRouter
        );

        calls[3] = _buildCallProxyUpgrade(
            coreAddresses.bridges.proxies.l1NativeTokenVault,
            coreAddresses.bridges.implementations.l1NativeTokenVault
        );

        calls[4] = _buildCallProxyUpgrade(
            coreAddresses.bridgehub.proxies.messageRoot,
            coreAddresses.bridgehub.implementations.messageRoot
        );

        calls[5] = _buildCallProxyUpgrade(
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
            coreAddresses.bridgehub.implementations.ctmDeploymentTracker
        );

        // calls[6] = _buildCallProxyUpgrade(coreAddresses.bridges.proxies.erc20Bridge, coreAddresses.bridges.implementations.erc20Bridge);
    }

    function _buildCallProxyUpgrade(
        address proxyAddress,
        address newImplementationAddress
    ) internal virtual returns (Call memory call) {
        require(coreAddresses.shared.transparentProxyAdmin != address(0), "transparentProxyAdmin not newConfigured");

        call = Call({
            target: coreAddresses.shared.transparentProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(payable(proxyAddress)), newImplementationAddress)
            ),
            value: 0
        });
    }

    function _buildCallBeaconProxyUpgrade(
        address proxyAddress,
        address newImplementationAddress
    ) internal virtual returns (Call memory call) {
        call = Call({
            target: proxyAddress,
            data: abi.encodeCall(UpgradeableBeacon.upgradeTo, (newImplementationAddress)),
            value: 0
        });
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}
