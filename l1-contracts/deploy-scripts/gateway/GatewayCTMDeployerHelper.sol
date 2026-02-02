// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {Utils} from "../utils/Utils.sol";
import {L1L2DeployUtils} from "../utils/deploy/L1L2DeployUtils.sol";

import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";

import {DeployedContracts, DAContracts, Facets, GatewayCTMDeployerConfig, GatewayDADeployerConfig, GatewayProxyAdminDeployerConfig, GatewayProxyAdminDeployerResult, GatewayValidatorTimelockDeployerConfig, GatewayValidatorTimelockDeployerResult, GatewayVerifiersDeployerConfig, Verifiers, GatewayCTMFinalConfig, GatewayCTMFinalResult} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";

import {DeployCTML1OrGateway, CTMCoreDeploymentConfig} from "../ctm/DeployCTML1OrGateway.sol";
import {CTMContract} from "../ctm/DeployCTML1OrGateway.sol";

// solhint-disable gas-custom-errors

struct InnerDeployConfig {
    address deployerAddr;
    bytes32 salt;
}

/// @notice Addresses of deployer contracts
struct DeployerAddresses {
    address daDeployer;
    address proxyAdminDeployer;
    address validatorTimelockDeployer;
    address verifiersDeployer;
    address ctmDeployer;
}

/// @notice CREATE2 calldata for the deployers
struct DeployerCreate2Calldata {
    bytes daCalldata;
    bytes proxyAdminCalldata;
    bytes validatorTimelockCalldata;
    bytes verifiersCalldata;
    bytes ctmCalldata;
}

/// @notice Addresses of contracts deployed directly (no deployer)
struct DirectDeployedAddresses {
    Facets facets;
    address genesisUpgrade;
    address multicall3;
}

/// @notice CREATE2 calldata for contracts deployed directly (no deployer)
struct DirectCreate2Calldata {
    bytes adminFacetCalldata;
    bytes mailboxFacetCalldata;
    bytes executorFacetCalldata;
    bytes gettersFacetCalldata;
    bytes migratorFacetCalldata;
    bytes diamondInitCalldata;
    bytes genesisUpgradeCalldata;
    bytes multicall3Calldata;
}

library GatewayCTMDeployerHelper {
    /// @notice Calculates all addresses for the deployment.
    /// @dev Uses 5 deployers + direct contract deployments.
    /// @param _create2Salt Salt used for CREATE2 when deploying the deployers.
    /// @param config The full deployment configuration.
    /// @return contracts The complete set of deployed contracts.
    /// @return deployerCalldata The CREATE2 calldata for each deployer.
    /// @return deployers The addresses of each deployer.
    /// @return directCalldata The CREATE2 calldata for direct contract deployments.
    /// @return create2FactoryAddress The CREATE2 factory address for L1->L2 deployment transactions.
    function calculateAddresses(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config
    )
        internal
        returns (
            DeployedContracts memory contracts,
            DeployerCreate2Calldata memory deployerCalldata,
            DeployerAddresses memory deployers,
            DirectCreate2Calldata memory directCalldata,
            address create2FactoryAddress
        )
    {
        // Set target address based on mode
        create2FactoryAddress = L1L2DeployUtils.getDeploymentTarget(config.isZKsyncOS);

        // Calculate DA deployer addresses
        DAContracts memory daResult;
        (deployers.daDeployer, deployerCalldata.daCalldata, daResult) = _calculateDADeployer(_create2Salt, config);

        // Calculate ProxyAdmin deployer addresses
        GatewayProxyAdminDeployerResult memory proxyAdminResult;
        (
            deployers.proxyAdminDeployer,
            deployerCalldata.proxyAdminCalldata,
            proxyAdminResult
        ) = _calculateProxyAdminDeployer(_create2Salt, config);

        // Calculate ValidatorTimelock deployer addresses
        GatewayValidatorTimelockDeployerResult memory validatorTimelockResult;
        (
            deployers.validatorTimelockDeployer,
            deployerCalldata.validatorTimelockCalldata,
            validatorTimelockResult
        ) = _calculateValidatorTimelockDeployer(_create2Salt, config, proxyAdminResult);

        // Calculate Verifiers deployer addresses
        Verifiers memory verifiersResult;
        (
            deployers.verifiersDeployer,
            deployerCalldata.verifiersCalldata,
            verifiersResult
        ) = _calculateVerifiersDeployer(_create2Salt, config);

        // Calculate direct deployment addresses and calldata (no deployer)
        DirectDeployedAddresses memory directAddresses;
        (directAddresses, directCalldata) = _calculateDirectDeployments(_create2Salt, config, daResult);

        // Calculate CTM deployer addresses
        GatewayCTMFinalResult memory ctmResult;
        (deployers.ctmDeployer, deployerCalldata.ctmCalldata, ctmResult) = _calculateCTMDeployer(
            _create2Salt,
            config,
            directAddresses,
            proxyAdminResult,
            validatorTimelockResult,
            verifiersResult
        );

        // Assemble the complete DeployedContracts struct
        contracts = _assembleContracts(
            daResult,
            proxyAdminResult,
            validatorTimelockResult,
            verifiersResult,
            directAddresses,
            ctmResult
        );
    }

    // ============ DA Deployer ============

    function _calculateDADeployer(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config
    ) internal returns (address deployer, bytes memory data, DAContracts memory result) {
        GatewayDADeployerConfig memory daConfig = GatewayDADeployerConfig({
            salt: config.salt,
            aliasedGovernanceAddress: config.aliasedGovernanceAddress
        });

        bytes memory bytecode = _readBytecode("GatewayCTMDeployerDA.sol", "GatewayCTMDeployerDA", config.isZKsyncOS);
        bytes memory constructorArgs = abi.encode(daConfig);

        L1L2DeployUtils.DeployResult memory deployResult = L1L2DeployUtils.prepareDeployment(
            _create2Salt,
            bytecode,
            constructorArgs,
            config.isZKsyncOS
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateDADeployerAddressesWithMode(deployer, daConfig, config.isZKsyncOS);
    }

    // ============ ProxyAdmin Deployer ============

    function _calculateProxyAdminDeployer(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config
    ) internal returns (address deployer, bytes memory data, GatewayProxyAdminDeployerResult memory result) {
        GatewayProxyAdminDeployerConfig memory proxyAdminConfig = GatewayProxyAdminDeployerConfig({
            salt: config.salt,
            aliasedGovernanceAddress: config.aliasedGovernanceAddress
        });

        bytes memory bytecode = _readBytecode(
            "GatewayCTMDeployerProxyAdmin.sol",
            "GatewayCTMDeployerProxyAdmin",
            config.isZKsyncOS
        );
        bytes memory constructorArgs = abi.encode(proxyAdminConfig);

        L1L2DeployUtils.DeployResult memory deployResult = L1L2DeployUtils.prepareDeployment(
            _create2Salt,
            bytecode,
            constructorArgs,
            config.isZKsyncOS
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateProxyAdminDeployerAddressesWithMode(deployer, proxyAdminConfig, config.isZKsyncOS);
    }

    // ============ ValidatorTimelock Deployer ============

    function _calculateValidatorTimelockDeployer(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config,
        GatewayProxyAdminDeployerResult memory proxyAdminResult
    ) internal returns (address deployer, bytes memory data, GatewayValidatorTimelockDeployerResult memory result) {
        GatewayValidatorTimelockDeployerConfig memory vtConfig = GatewayValidatorTimelockDeployerConfig({
            salt: config.salt,
            aliasedGovernanceAddress: config.aliasedGovernanceAddress,
            chainTypeManagerProxyAdmin: proxyAdminResult.chainTypeManagerProxyAdmin
        });

        bytes memory bytecode = _readBytecode(
            "GatewayCTMDeployerValidatorTimelock.sol",
            "GatewayCTMDeployerValidatorTimelock",
            config.isZKsyncOS
        );
        bytes memory constructorArgs = abi.encode(vtConfig);

        L1L2DeployUtils.DeployResult memory deployResult = L1L2DeployUtils.prepareDeployment(
            _create2Salt,
            bytecode,
            constructorArgs,
            config.isZKsyncOS
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateValidatorTimelockDeployerAddressesWithMode(deployer, vtConfig, config.isZKsyncOS);
    }

    // ============ Verifiers Deployer ============

    function _calculateVerifiersDeployer(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config
    ) internal returns (address deployer, bytes memory data, Verifiers memory result) {
        GatewayVerifiersDeployerConfig memory verifiersConfig = GatewayVerifiersDeployerConfig({
            salt: config.salt,
            aliasedGovernanceAddress: config.aliasedGovernanceAddress,
            testnetVerifier: config.testnetVerifier,
            isZKsyncOS: config.isZKsyncOS
        });

        // Different deployer contracts for each mode
        bytes memory bytecode = config.isZKsyncOS
            ? _readBytecode("GatewayCTMDeployerVerifiersZKsyncOS.sol", "GatewayCTMDeployerVerifiersZKsyncOS", true)
            : _readBytecode("GatewayCTMDeployerVerifiers.sol", "GatewayCTMDeployerVerifiers", false);
        bytes memory constructorArgs = abi.encode(verifiersConfig);

        L1L2DeployUtils.DeployResult memory deployResult = L1L2DeployUtils.prepareDeployment(
            _create2Salt,
            bytecode,
            constructorArgs,
            config.isZKsyncOS
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateVerifiersDeployerAddressesWithMode(deployer, verifiersConfig, config.isZKsyncOS);
    }

    // ============ Direct Deployments (no deployer) ============

    function _calculateDirectDeployments(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config,
        DAContracts memory daResult
    ) internal returns (DirectDeployedAddresses memory addresses, DirectCreate2Calldata memory data) {
        // AdminFacet
        bytes memory adminFacetArgs = abi.encode(config.l1ChainId, daResult.rollupDAManager, config.testnetVerifier);
        (addresses.facets.adminFacet, data.adminFacetCalldata) = _calculateCreate2AddressAndCalldataWithMode(
            _create2Salt,
            "Admin.sol",
            "AdminFacet",
            adminFacetArgs,
            config.isZKsyncOS
        );

        // MailboxFacet
        bytes memory mailboxFacetArgs = abi.encode(
            config.eraChainId,
            config.l1ChainId,
            L2_CHAIN_ASSET_HANDLER_ADDR,
            address(0), // eip7702Checker
            config.testnetVerifier
        );
        (addresses.facets.mailboxFacet, data.mailboxFacetCalldata) = _calculateCreate2AddressAndCalldataWithMode(
            _create2Salt,
            "Mailbox.sol",
            "MailboxFacet",
            mailboxFacetArgs,
            config.isZKsyncOS
        );

        // ExecutorFacet
        bytes memory executorFacetArgs = abi.encode(config.l1ChainId);
        (addresses.facets.executorFacet, data.executorFacetCalldata) = _calculateCreate2AddressAndCalldataWithMode(
            _create2Salt,
            "Executor.sol",
            "ExecutorFacet",
            executorFacetArgs,
            config.isZKsyncOS
        );

        // GettersFacet
        (addresses.facets.gettersFacet, data.gettersFacetCalldata) = _calculateCreate2AddressAndCalldataWithMode(
            _create2Salt,
            "Getters.sol",
            "GettersFacet",
            hex"",
            config.isZKsyncOS
        );

        // MigratorFacet
        bytes memory migratorFacetArgs = abi.encode(config.l1ChainId, config.testnetVerifier);
        (addresses.facets.migratorFacet, data.migratorFacetCalldata) = _calculateCreate2AddressAndCalldataWithMode(
            _create2Salt,
            "Migrator.sol",
            "Migrator",
            migratorFacetArgs,
            config.isZKsyncOS
        );

        // DiamondInit
        bytes memory diamondInitArgs = abi.encode(config.isZKsyncOS);
        (addresses.facets.diamondInit, data.diamondInitCalldata) = _calculateCreate2AddressAndCalldataWithMode(
            _create2Salt,
            "DiamondInit.sol",
            "DiamondInit",
            diamondInitArgs,
            config.isZKsyncOS
        );

        // L1GenesisUpgrade
        (addresses.genesisUpgrade, data.genesisUpgradeCalldata) = _calculateCreate2AddressAndCalldataWithMode(
            _create2Salt,
            "L1GenesisUpgrade.sol",
            "L1GenesisUpgrade",
            hex"",
            config.isZKsyncOS
        );

        // Multicall3
        (addresses.multicall3, data.multicall3Calldata) = _calculateCreate2AddressAndCalldataWithMode(
            _create2Salt,
            "Multicall3.sol",
            "Multicall3",
            hex"",
            config.isZKsyncOS
        );
    }

    function _calculateCreate2AddressAndCalldata(
        bytes32 _create2Salt,
        string memory fileName,
        string memory contractName,
        bytes memory constructorArgs
    ) internal returns (address addr, bytes memory data) {
        // Default to Era mode (non-ZKsyncOS) for backwards compatibility
        return
            _calculateCreate2AddressAndCalldataWithMode(_create2Salt, fileName, contractName, constructorArgs, false);
    }

    function _calculateCreate2AddressAndCalldataWithMode(
        bytes32 _create2Salt,
        string memory fileName,
        string memory contractName,
        bytes memory constructorArgs,
        bool isZKsyncOS
    ) internal returns (address addr, bytes memory data) {
        bytes memory bytecode = _readBytecode(fileName, contractName, isZKsyncOS);
        L1L2DeployUtils.DeployResult memory result = L1L2DeployUtils.prepareDeployment(
            _create2Salt,
            bytecode,
            constructorArgs,
            isZKsyncOS
        );
        addr = result.expectedAddress;
        data = result.data;
    }

    // ============ CTM Deployer ============

    function _calculateCTMDeployer(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config,
        DirectDeployedAddresses memory directAddresses,
        GatewayProxyAdminDeployerResult memory proxyAdminResult,
        GatewayValidatorTimelockDeployerResult memory validatorTimelockResult,
        Verifiers memory verifiersResult
    ) internal returns (address deployer, bytes memory data, GatewayCTMFinalResult memory result) {
        GatewayCTMFinalConfig memory ctmConfig = GatewayCTMFinalConfig({
            baseConfig: config,
            chainTypeManagerProxyAdmin: proxyAdminResult.chainTypeManagerProxyAdmin,
            validatorTimelockProxy: validatorTimelockResult.validatorTimelockProxy,
            facets: directAddresses.facets,
            genesisUpgrade: directAddresses.genesisUpgrade,
            verifier: verifiersResult.verifier
        });

        // Different deployer contracts for each mode
        bytes memory bytecode = config.isZKsyncOS
            ? _readBytecode("GatewayCTMDeployerCTMZKsyncOS.sol", "GatewayCTMDeployerCTMZKsyncOS", true)
            : _readBytecode("GatewayCTMDeployerCTM.sol", "GatewayCTMDeployerCTM", false);
        bytes memory constructorArgs = abi.encode(ctmConfig);

        L1L2DeployUtils.DeployResult memory deployResult = L1L2DeployUtils.prepareDeployment(
            _create2Salt,
            bytecode,
            constructorArgs,
            config.isZKsyncOS
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateCTMDeployerAddressesWithMode(deployer, ctmConfig, config.isZKsyncOS);
    }

    // ============ Address Calculation Helpers ============

    function _calculateDADeployerAddresses(
        address deployerAddr,
        GatewayDADeployerConfig memory config
    ) internal returns (DAContracts memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        result.rollupDAManager = _deployInternalEmptyParams("RollupDAManager", "RollupDAManager.sol", innerConfig);
        result.validiumDAValidator = _deployInternalEmptyParams(
            "ValidiumL1DAValidator",
            "ValidiumL1DAValidator.sol",
            innerConfig
        );
        result.relayedSLDAValidator = _deployInternalEmptyParams(
            "RelayedSLDAValidator",
            "RelayedSLDAValidator.sol",
            innerConfig
        );
    }

    function _calculateDADeployerAddressesWithMode(
        address deployerAddr,
        GatewayDADeployerConfig memory config,
        bool isZKsyncOS
    ) internal returns (DAContracts memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        result.rollupDAManager = _deployInternalEmptyParamsWithMode(
            "RollupDAManager",
            "RollupDAManager.sol",
            innerConfig,
            isZKsyncOS
        );
        result.validiumDAValidator = _deployInternalEmptyParamsWithMode(
            "ValidiumL1DAValidator",
            "ValidiumL1DAValidator.sol",
            innerConfig,
            isZKsyncOS
        );
        result.relayedSLDAValidator = _deployInternalEmptyParamsWithMode(
            "RelayedSLDAValidator",
            "RelayedSLDAValidator.sol",
            innerConfig,
            isZKsyncOS
        );
    }

    function _calculateProxyAdminDeployerAddresses(
        address deployerAddr,
        GatewayProxyAdminDeployerConfig memory config
    ) internal returns (GatewayProxyAdminDeployerResult memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});
        result.chainTypeManagerProxyAdmin = _deployInternalEmptyParams("ProxyAdmin", "ProxyAdmin.sol", innerConfig);
    }

    function _calculateProxyAdminDeployerAddressesWithMode(
        address deployerAddr,
        GatewayProxyAdminDeployerConfig memory config,
        bool isZKsyncOS
    ) internal returns (GatewayProxyAdminDeployerResult memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});
        result.chainTypeManagerProxyAdmin = _deployInternalEmptyParamsWithMode(
            "ProxyAdmin",
            "ProxyAdmin.sol",
            innerConfig,
            isZKsyncOS
        );
    }

    function _calculateValidatorTimelockDeployerAddresses(
        address deployerAddr,
        GatewayValidatorTimelockDeployerConfig memory config
    ) internal returns (GatewayValidatorTimelockDeployerResult memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        result.validatorTimelockImplementation = _deployInternalWithParams(
            "ValidatorTimelock",
            "ValidatorTimelock.sol",
            abi.encode(L2_BRIDGEHUB_ADDR),
            innerConfig
        );

        result.validatorTimelockProxy = _deployInternalWithParams(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                result.validatorTimelockImplementation,
                config.chainTypeManagerProxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (config.aliasedGovernanceAddress, 0))
            ),
            innerConfig
        );
    }

    function _calculateValidatorTimelockDeployerAddressesWithMode(
        address deployerAddr,
        GatewayValidatorTimelockDeployerConfig memory config,
        bool isZKsyncOS
    ) internal returns (GatewayValidatorTimelockDeployerResult memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        result.validatorTimelockImplementation = _deployInternalWithParamsWithMode(
            "ValidatorTimelock",
            "ValidatorTimelock.sol",
            abi.encode(L2_BRIDGEHUB_ADDR),
            innerConfig,
            isZKsyncOS
        );

        result.validatorTimelockProxy = _deployInternalWithParamsWithMode(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                result.validatorTimelockImplementation,
                config.chainTypeManagerProxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (config.aliasedGovernanceAddress, 0))
            ),
            innerConfig,
            isZKsyncOS
        );
    }

    function _calculateVerifiersDeployerAddresses(
        address deployerAddr,
        GatewayVerifiersDeployerConfig memory config
    ) internal returns (Verifiers memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        // Deploy base verifiers based on config
        if (config.isZKsyncOS) {
            result.verifierFflonk = _deployInternalEmptyParams(
                "ZKsyncOSVerifierFflonk",
                "ZKsyncOSVerifierFflonk.sol",
                innerConfig
            );
            result.verifierPlonk = _deployInternalEmptyParams(
                "ZKsyncOSVerifierPlonk",
                "ZKsyncOSVerifierPlonk.sol",
                innerConfig
            );
        } else {
            result.verifierFflonk = _deployInternalEmptyParams(
                "EraVerifierFflonk",
                "EraVerifierFflonk.sol",
                innerConfig
            );
            result.verifierPlonk = _deployInternalEmptyParams("EraVerifierPlonk", "EraVerifierPlonk.sol", innerConfig);
        }

        // Deploy main verifier
        if (config.testnetVerifier) {
            if (config.isZKsyncOS) {
                result.verifier = _deployInternalWithParams(
                    "ZKsyncOSTestnetVerifier",
                    "ZKsyncOSTestnetVerifier.sol",
                    abi.encode(result.verifierFflonk, result.verifierPlonk, config.aliasedGovernanceAddress),
                    innerConfig
                );
            } else {
                result.verifier = _deployInternalWithParams(
                    "EraTestnetVerifier",
                    "EraTestnetVerifier.sol",
                    abi.encode(result.verifierFflonk, result.verifierPlonk),
                    innerConfig
                );
            }
        } else {
            if (config.isZKsyncOS) {
                result.verifier = _deployInternalWithParams(
                    "ZKsyncOSDualVerifier",
                    "ZKsyncOSDualVerifier.sol",
                    abi.encode(result.verifierFflonk, result.verifierPlonk, config.aliasedGovernanceAddress),
                    innerConfig
                );
            } else {
                result.verifier = _deployInternalWithParams(
                    "EraDualVerifier",
                    "EraDualVerifier.sol",
                    abi.encode(result.verifierFflonk, result.verifierPlonk),
                    innerConfig
                );
            }
        }
    }

    function _calculateVerifiersDeployerAddressesWithMode(
        address deployerAddr,
        GatewayVerifiersDeployerConfig memory config,
        bool isZKsyncOS
    ) internal returns (Verifiers memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        // Deploy base verifiers based on config
        if (config.isZKsyncOS) {
            result.verifierFflonk = _deployInternalEmptyParamsWithMode(
                "ZKsyncOSVerifierFflonk",
                "ZKsyncOSVerifierFflonk.sol",
                innerConfig,
                isZKsyncOS
            );
            result.verifierPlonk = _deployInternalEmptyParamsWithMode(
                "ZKsyncOSVerifierPlonk",
                "ZKsyncOSVerifierPlonk.sol",
                innerConfig,
                isZKsyncOS
            );
        } else {
            result.verifierFflonk = _deployInternalEmptyParamsWithMode(
                "EraVerifierFflonk",
                "EraVerifierFflonk.sol",
                innerConfig,
                isZKsyncOS
            );
            result.verifierPlonk = _deployInternalEmptyParamsWithMode(
                "EraVerifierPlonk",
                "EraVerifierPlonk.sol",
                innerConfig,
                isZKsyncOS
            );
        }

        // Deploy main verifier
        if (config.testnetVerifier) {
            if (config.isZKsyncOS) {
                result.verifier = _deployInternalWithParamsWithMode(
                    "ZKsyncOSTestnetVerifier",
                    "ZKsyncOSTestnetVerifier.sol",
                    abi.encode(result.verifierFflonk, result.verifierPlonk, config.aliasedGovernanceAddress),
                    innerConfig,
                    isZKsyncOS
                );
            } else {
                result.verifier = _deployInternalWithParamsWithMode(
                    "EraTestnetVerifier",
                    "EraTestnetVerifier.sol",
                    abi.encode(result.verifierFflonk, result.verifierPlonk),
                    innerConfig,
                    isZKsyncOS
                );
            }
        } else {
            if (config.isZKsyncOS) {
                result.verifier = _deployInternalWithParamsWithMode(
                    "ZKsyncOSDualVerifier",
                    "ZKsyncOSDualVerifier.sol",
                    abi.encode(result.verifierFflonk, result.verifierPlonk, config.aliasedGovernanceAddress),
                    innerConfig,
                    isZKsyncOS
                );
            } else {
                result.verifier = _deployInternalWithParamsWithMode(
                    "EraDualVerifier",
                    "EraDualVerifier.sol",
                    abi.encode(result.verifierFflonk, result.verifierPlonk),
                    innerConfig,
                    isZKsyncOS
                );
            }
        }
    }

    function _calculateCTMDeployerAddresses(
        address deployerAddr,
        GatewayCTMFinalConfig memory config
    ) internal returns (GatewayCTMFinalResult memory result) {
        GatewayCTMDeployerConfig memory baseConfig = config.baseConfig;
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: baseConfig.salt});

        // ServerNotifier
        result.serverNotifierImplementation = _deployInternalEmptyParams(
            "ServerNotifier",
            "ServerNotifier.sol",
            innerConfig
        );

        result.serverNotifierProxy = _deployInternalWithParams(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                result.serverNotifierImplementation,
                config.chainTypeManagerProxyAdmin,
                abi.encodeCall(ServerNotifier.initialize, (deployerAddr)) // deployer is temporary owner
            ),
            innerConfig
        );

        // CTM Implementation
        if (baseConfig.isZKsyncOS) {
            result.chainTypeManagerImplementation = _deployInternalWithParams(
                "ZKsyncOSChainTypeManager",
                "ZKsyncOSChainTypeManager.sol",
                abi.encode(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), baseConfig.permissionlessValidator),
                innerConfig
            );
        } else {
            result.chainTypeManagerImplementation = _deployInternalWithParams(
                "EraChainTypeManager",
                "EraChainTypeManager.sol",
                abi.encode(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), baseConfig.permissionlessValidator),
                innerConfig
            );
        }

        // Build diamond cut data
        Facets memory facets = config.facets;
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](5);
        facetCuts[0] = Diamond.FacetCut({
            facet: facets.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: baseConfig.adminSelectors
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: facets.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: baseConfig.gettersSelectors
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: facets.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: baseConfig.mailboxSelectors
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: facets.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: baseConfig.executorSelectors
        });
        facetCuts[4] = Diamond.FacetCut({
            facet: facets.migratorFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: baseConfig.migratorSelectors
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(config.verifier),
            l2BootloaderBytecodeHash: baseConfig.bootloaderHash,
            l2DefaultAccountBytecodeHash: baseConfig.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: baseConfig.evmEmulatorHash,
            permissionlessValidator: baseConfig.permissionlessValidator
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: facets.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        result.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: config.genesisUpgrade,
            genesisBatchHash: baseConfig.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(baseConfig.genesisRollupLeafIndex),
            genesisBatchCommitment: baseConfig.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: baseConfig.forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: baseConfig.aliasedGovernanceAddress,
            validatorTimelock: config.validatorTimelockProxy,
            chainCreationParams: chainCreationParams,
            protocolVersion: baseConfig.protocolVersion,
            serverNotifier: result.serverNotifierProxy
        });

        bytes memory initCalldata = abi.encodeCall(IChainTypeManager.initialize, (diamondInitData));

        result.chainTypeManagerProxy = _deployInternalWithParams(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(result.chainTypeManagerImplementation, config.chainTypeManagerProxyAdmin, initCalldata),
            innerConfig
        );
    }

    function _calculateCTMDeployerAddressesWithMode(
        address deployerAddr,
        GatewayCTMFinalConfig memory config,
        bool isZKsyncOS
    ) internal returns (GatewayCTMFinalResult memory result) {
        GatewayCTMDeployerConfig memory baseConfig = config.baseConfig;
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: baseConfig.salt});

        // ServerNotifier
        result.serverNotifierImplementation = _deployInternalEmptyParamsWithMode(
            "ServerNotifier",
            "ServerNotifier.sol",
            innerConfig,
            isZKsyncOS
        );

        result.serverNotifierProxy = _deployInternalWithParamsWithMode(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                result.serverNotifierImplementation,
                config.chainTypeManagerProxyAdmin,
                abi.encodeCall(ServerNotifier.initialize, (deployerAddr)) // deployer is temporary owner
            ),
            innerConfig,
            isZKsyncOS
        );

        // CTM Implementation
        if (baseConfig.isZKsyncOS) {
            result.chainTypeManagerImplementation = _deployInternalWithParamsWithMode(
                "ZKsyncOSChainTypeManager",
                "ZKsyncOSChainTypeManager.sol",
                abi.encode(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), baseConfig.permissionlessValidator),
                innerConfig,
                isZKsyncOS
            );
        } else {
            result.chainTypeManagerImplementation = _deployInternalWithParamsWithMode(
                "EraChainTypeManager",
                "EraChainTypeManager.sol",
                abi.encode(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), baseConfig.permissionlessValidator),
                innerConfig,
                isZKsyncOS
            );
        }

        // Build diamond cut data
        Facets memory facets = config.facets;
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](5);
        facetCuts[0] = Diamond.FacetCut({
            facet: facets.adminFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: baseConfig.adminSelectors
        });
        facetCuts[1] = Diamond.FacetCut({
            facet: facets.gettersFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: baseConfig.gettersSelectors
        });
        facetCuts[2] = Diamond.FacetCut({
            facet: facets.mailboxFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: baseConfig.mailboxSelectors
        });
        facetCuts[3] = Diamond.FacetCut({
            facet: facets.executorFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: baseConfig.executorSelectors
        });
        facetCuts[4] = Diamond.FacetCut({
            facet: facets.migratorFacet,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: baseConfig.migratorSelectors
        });

        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            verifier: IVerifier(config.verifier),
            l2BootloaderBytecodeHash: baseConfig.bootloaderHash,
            l2DefaultAccountBytecodeHash: baseConfig.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: baseConfig.evmEmulatorHash,
            permissionlessValidator: baseConfig.permissionlessValidator
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: facets.diamondInit,
            initCalldata: abi.encode(initializeData)
        });

        result.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: config.genesisUpgrade,
            genesisBatchHash: baseConfig.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(baseConfig.genesisRollupLeafIndex),
            genesisBatchCommitment: baseConfig.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: baseConfig.forceDeploymentsData
        });

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: baseConfig.aliasedGovernanceAddress,
            validatorTimelock: config.validatorTimelockProxy,
            chainCreationParams: chainCreationParams,
            protocolVersion: baseConfig.protocolVersion,
            serverNotifier: result.serverNotifierProxy
        });

        bytes memory initCalldata = abi.encodeCall(IChainTypeManager.initialize, (diamondInitData));

        result.chainTypeManagerProxy = _deployInternalWithParamsWithMode(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(result.chainTypeManagerImplementation, config.chainTypeManagerProxyAdmin, initCalldata),
            innerConfig,
            isZKsyncOS
        );
    }

    function _assembleContracts(
        DAContracts memory daResult,
        GatewayProxyAdminDeployerResult memory proxyAdminResult,
        GatewayValidatorTimelockDeployerResult memory validatorTimelockResult,
        Verifiers memory verifiersResult,
        DirectDeployedAddresses memory directAddresses,
        GatewayCTMFinalResult memory ctmResult
    ) internal pure returns (DeployedContracts memory contracts) {
        // From DA deployer
        contracts.daContracts.rollupDAManager = daResult.rollupDAManager;
        contracts.daContracts.validiumDAValidator = daResult.validiumDAValidator;
        contracts.daContracts.relayedSLDAValidator = daResult.relayedSLDAValidator;

        // From ProxyAdmin deployer
        contracts.stateTransition.chainTypeManagerProxyAdmin = proxyAdminResult.chainTypeManagerProxyAdmin;

        // From ValidatorTimelock deployer
        contracts.stateTransition.validatorTimelockImplementation = validatorTimelockResult
            .validatorTimelockImplementation;
        contracts.stateTransition.validatorTimelockProxy = validatorTimelockResult.validatorTimelockProxy;

        // From Verifiers deployer
        contracts.stateTransition.verifiers = verifiersResult;

        // From direct deployments
        contracts.stateTransition.facets = directAddresses.facets;
        contracts.stateTransition.genesisUpgrade = directAddresses.genesisUpgrade;
        contracts.multicall3 = directAddresses.multicall3;

        // From CTM deployer
        contracts.stateTransition.serverNotifierImplementation = ctmResult.serverNotifierImplementation;
        contracts.stateTransition.serverNotifierProxy = ctmResult.serverNotifierProxy;
        contracts.stateTransition.chainTypeManagerImplementation = ctmResult.chainTypeManagerImplementation;
        contracts.stateTransition.chainTypeManagerProxy = ctmResult.chainTypeManagerProxy;
        contracts.diamondCutData = ctmResult.diamondCutData;
    }

    /// @notice Returns the CTM core deployment config.
    function getCTMCoreDeploymentConfig(
        GatewayCTMDeployerConfig memory _config,
        DeployedContracts memory _deployedContracts
    ) internal returns (CTMCoreDeploymentConfig memory) {
        return
            CTMCoreDeploymentConfig({
                isZKsyncOS: _config.isZKsyncOS,
                testnetVerifier: _config.testnetVerifier,
                eraChainId: _config.eraChainId,
                l1ChainId: _config.l1ChainId,
                bridgehubProxy: L2_BRIDGEHUB_ADDR,
                interopCenterProxy: L2_INTEROP_CENTER_ADDR,
                rollupDAManager: _deployedContracts.daContracts.rollupDAManager,
                chainAssetHandler: L2_CHAIN_ASSET_HANDLER_ADDR,
                l1BytecodesSupplier: address(0),
                eip7702Checker: address(0),
                verifierFflonk: _deployedContracts.stateTransition.verifiers.verifierFflonk,
                verifierPlonk: _deployedContracts.stateTransition.verifiers.verifierPlonk,
                verifierOwner: _config.aliasedGovernanceAddress
            });
    }

    // ============ Internal Helpers ============

    function _readBytecode(
        string memory fileName,
        string memory contractName,
        bool isZKsyncOS
    ) private returns (bytes memory) {
        return
            isZKsyncOS
                ? Utils.readFoundryBytecodeL1(fileName, contractName)
                : Utils.readZKFoundryBytecodeL1(fileName, contractName);
    }

    function _deployInternalEmptyParams(
        string memory contractName,
        string memory fileName,
        InnerDeployConfig memory config
    ) private returns (address) {
        return _deployInternalInner(contractName, fileName, hex"", config);
    }

    function _deployInternalWithParams(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config
    ) private returns (address) {
        return _deployInternalInner(contractName, fileName, params, config);
    }

    function _deployInternalEmptyParamsWithMode(
        string memory contractName,
        string memory fileName,
        InnerDeployConfig memory config,
        bool isZKsyncOS
    ) private returns (address) {
        return _deployInternalInnerWithMode(contractName, fileName, hex"", config, isZKsyncOS);
    }

    function _deployInternalWithParamsWithMode(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config,
        bool isZKsyncOS
    ) private returns (address) {
        return _deployInternalInnerWithMode(contractName, fileName, params, config, isZKsyncOS);
    }

    function _deployInternalInner(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config
    ) private returns (address) {
        bytes memory bytecode = Utils.readZKFoundryBytecodeL1(fileName, contractName);

        return
            L2ContractHelper.computeCreate2Address(
                config.deployerAddr,
                config.salt,
                L2ContractHelper.hashL2Bytecode(bytecode),
                keccak256(params)
            );
    }

    function _deployInternalInnerWithMode(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config,
        bool isZKsyncOS
    ) private returns (address) {
        bytes memory bytecode = _readBytecode(fileName, contractName, isZKsyncOS);

        if (isZKsyncOS) {
            // Use standard EVM CREATE2 address derivation
            bytes memory initCode = abi.encodePacked(bytecode, params);
            return Utils.vm.computeCreate2Address(config.salt, keccak256(initCode), config.deployerAddr);
        } else {
            // Use ZKsync-specific CREATE2 address derivation
            return
                L2ContractHelper.computeCreate2Address(
                    config.deployerAddr,
                    config.salt,
                    L2ContractHelper.hashL2Bytecode(bytecode),
                    keccak256(params)
                );
        }
    }

    // ============ Factory Dependencies ============

    /// @notice Returns all factory dependencies for deployment.
    /// @param _isZKsyncOS Whether to include ZKsync OS-specific dependencies.
    /// @return dependencies Array of bytecodes needed for deployment.
    function getListOfFactoryDeps(bool _isZKsyncOS) external returns (bytes[] memory dependencies) {
        if (_isZKsyncOS) {
            // There are no factory dependencies needed for ZKSync OS chains to initialize ZK Gateway.
            return dependencies;
        }

        // For Era mode (non-ZKsyncOS):
        // 5 deployers (DA, ProxyAdmin, ValidatorTimelock, Verifiers Era, CTM Era)
        // + 3 DA contracts (RollupDAManager, ValidiumL1DAValidator, RelayedSLDAValidator)
        // + 1 ProxyAdmin contract
        // + 2 ValidatorTimelock contracts (implementation + proxy)
        // + 4 Verifier contracts (Era only)
        // + 2 CTM contracts (ServerNotifier, EraChainTypeManager)
        // + 9 direct contracts (AdminFacet, MailboxFacet, ExecutorFacet, GettersFacet, MigratorFacet, DiamondInit, GenesisUpgrade, Multicall3, DiamondProxy)
        // Total: 5 + 3 + 1 + 2 + 4 + 2 + 9 = 26
        uint256 totalDependencies = 26;
        dependencies = new bytes[](totalDependencies);
        uint256 index = 0;

        // Deployer contracts (Era only)
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployerDA.sol", "GatewayCTMDeployerDA");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1(
            "GatewayCTMDeployerProxyAdmin.sol",
            "GatewayCTMDeployerProxyAdmin"
        );
        dependencies[index++] = Utils.readZKFoundryBytecodeL1(
            "GatewayCTMDeployerValidatorTimelock.sol",
            "GatewayCTMDeployerValidatorTimelock"
        );
        dependencies[index++] = Utils.readZKFoundryBytecodeL1(
            "GatewayCTMDeployerVerifiers.sol",
            "GatewayCTMDeployerVerifiers"
        );
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("GatewayCTMDeployerCTM.sol", "GatewayCTMDeployerCTM");

        // DA contracts
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("RollupDAManager.sol", "RollupDAManager");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ValidiumL1DAValidator.sol", "ValidiumL1DAValidator");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("RelayedSLDAValidator.sol", "RelayedSLDAValidator");

        // ProxyAdmin contracts
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ProxyAdmin.sol", "ProxyAdmin");

        // ValidatorTimelock contracts
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ValidatorTimelock.sol", "ValidatorTimelock");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1(
            "TransparentUpgradeableProxy.sol",
            "TransparentUpgradeableProxy"
        );

        // Verifier contracts (Era only)
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraVerifierFflonk.sol", "EraVerifierFflonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraVerifierPlonk.sol", "EraVerifierPlonk");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraTestnetVerifier.sol", "EraTestnetVerifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraDualVerifier.sol", "EraDualVerifier");

        // CTM contracts (Era only)
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("ServerNotifier.sol", "ServerNotifier");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("EraChainTypeManager.sol", "EraChainTypeManager");

        // Direct deployment contracts
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Admin.sol", "AdminFacet");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Mailbox.sol", "MailboxFacet");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Executor.sol", "ExecutorFacet");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Getters.sol", "GettersFacet");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Migrator.sol", "Migrator");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("DiamondInit.sol", "DiamondInit");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("L1GenesisUpgrade.sol", "L1GenesisUpgrade");
        dependencies[index++] = Utils.readZKFoundryBytecodeL1("Multicall3.sol", "Multicall3");

        dependencies[index++] = Utils.readZKFoundryBytecodeL1("DiamondProxy.sol", "DiamondProxy");

        return dependencies;
    }
}
