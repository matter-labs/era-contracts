// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {EraChainTypeManager} from "contracts/state-transition/EraChainTypeManager.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";
import {
    ChainCreationParams,
    ChainTypeManagerInitializeData,
    IChainTypeManager
} from "contracts/state-transition/IChainTypeManager.sol";

import {L1L2DeployPrepareResult, EraZkosContract, EraZkosRouter} from "../utils/EraZkosRouter.sol";

import {Facets, Verifiers} from "contracts/common/StateTransitionTypes.sol";

import {DAContracts} from "contracts/common/StateTransitionTypes.sol";
import {
    DeployedContracts,
    GatewayCTMDeployerConfig,
    GatewayDADeployerConfig,
    GatewayProxyAdminDeployerConfig,
    GatewayProxyAdminDeployerResult,
    GatewayValidatorTimelockDeployerConfig,
    GatewayValidatorTimelockDeployerResult,
    GatewayVerifiersDeployerConfig,
    GatewayCTMFinalConfig,
    GatewayCTMFinalResult
} from "contracts/state-transition/chain-deps/gateway-ctm-deployer/GatewayCTMDeployer.sol";

import {CTMCoreDeploymentConfig} from "../ctm/DeployCTML1OrGateway.sol";

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
    bytes committerFacetCalldata;
    bytes diamondInitCalldata;
    bytes genesisUpgradeCalldata;
    bytes multicall3Calldata;
}

struct CalculateAddressesIntermediate {
    DAContracts daResult;
    GatewayProxyAdminDeployerResult proxyAdminResult;
    GatewayValidatorTimelockDeployerResult validatorTimelockResult;
    Verifiers verifiersResult;
}

library GatewayCTMDeployerHelper {
    /// @notice Calculates all addresses for the deployment.
    /// @dev Uses 5 deployers + direct contract deployments.
    /// @param _create2Salt Salt used for CREATE2 when deploying the deployers.
    /// @param config The full deployment configuration (`config.isZKsyncOS` selects Era vs ZKsyncOS).
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
        create2FactoryAddress = EraZkosRouter.getDeploymentTarget(config.isZKsyncOS);
        (contracts, deployerCalldata, deployers, directCalldata) = _calculateAddressesInner(_create2Salt, config);
    }

    function _calculateAddressesInner(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config
    )
        internal
        returns (
            DeployedContracts memory contracts,
            DeployerCreate2Calldata memory deployerCalldata,
            DeployerAddresses memory deployers,
            DirectCreate2Calldata memory directCalldata
        )
    {
        CalculateAddressesIntermediate memory im;

        (deployers.daDeployer, deployerCalldata.daCalldata, im.daResult) = _calculateDADeployer(_create2Salt, config);
        (
            deployers.proxyAdminDeployer,
            deployerCalldata.proxyAdminCalldata,
            im.proxyAdminResult
        ) = _calculateProxyAdminDeployer(_create2Salt, config);
        (
            deployers.validatorTimelockDeployer,
            deployerCalldata.validatorTimelockCalldata,
            im.validatorTimelockResult
        ) = _calculateValidatorTimelockDeployer(_create2Salt, config, im.proxyAdminResult);
        (
            deployers.verifiersDeployer,
            deployerCalldata.verifiersCalldata,
            im.verifiersResult
        ) = _calculateVerifiersDeployer(_create2Salt, config);

        DirectDeployedAddresses memory directAddresses;
        (directAddresses, directCalldata) = _calculateDirectDeployments(_create2Salt, config, im.daResult);

        GatewayCTMFinalResult memory ctmResult;
        (deployers.ctmDeployer, deployerCalldata.ctmCalldata, ctmResult) = _calculateCTMDeployer(
            _create2Salt,
            config,
            directAddresses,
            im.proxyAdminResult,
            im.validatorTimelockResult,
            im.verifiersResult
        );

        contracts = _assembleContracts(
            im.daResult,
            im.proxyAdminResult,
            im.validatorTimelockResult,
            im.verifiersResult,
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

        bytes memory bytecode = EraZkosRouter.readBytecodeL1Raw(
            config.isZKsyncOS,
            "GatewayCTMDeployerDA.sol",
            "GatewayCTMDeployerDA"
        );
        bytes memory constructorArgs = abi.encode(daConfig);

        L1L2DeployPrepareResult memory deployResult = EraZkosRouter.prepareL1L2Deployment(
            config.isZKsyncOS,
            _create2Salt,
            bytecode,
            constructorArgs
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateDADeployerAddresses(deployer, daConfig, config.isZKsyncOS);
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

        bytes memory bytecode = EraZkosRouter.readBytecodeL1Raw(
            config.isZKsyncOS,
            "GatewayCTMDeployerProxyAdmin.sol",
            "GatewayCTMDeployerProxyAdmin"
        );
        bytes memory constructorArgs = abi.encode(proxyAdminConfig);

        L1L2DeployPrepareResult memory deployResult = EraZkosRouter.prepareL1L2Deployment(
            config.isZKsyncOS,
            _create2Salt,
            bytecode,
            constructorArgs
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateProxyAdminDeployerAddresses(deployer, proxyAdminConfig, config.isZKsyncOS);
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

        bytes memory bytecode = EraZkosRouter.readBytecodeL1Raw(
            config.isZKsyncOS,
            "GatewayCTMDeployerValidatorTimelock.sol",
            "GatewayCTMDeployerValidatorTimelock"
        );
        bytes memory constructorArgs = abi.encode(vtConfig);

        L1L2DeployPrepareResult memory deployResult = EraZkosRouter.prepareL1L2Deployment(
            config.isZKsyncOS,
            _create2Salt,
            bytecode,
            constructorArgs
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateValidatorTimelockDeployerAddresses(deployer, vtConfig, config.isZKsyncOS);
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

        (string memory vdFile, string memory vdName) = EraZkosRouter.resolve(
            config.isZKsyncOS,
            EraZkosContract.GatewayCTMDeployerVerifiers
        );
        bytes memory bytecode = EraZkosRouter.readBytecodeL1Raw(config.isZKsyncOS, vdFile, vdName);
        bytes memory constructorArgs = abi.encode(verifiersConfig);

        L1L2DeployPrepareResult memory deployResult = EraZkosRouter.prepareL1L2Deployment(
            config.isZKsyncOS,
            _create2Salt,
            bytecode,
            constructorArgs
        );
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        result = _calculateVerifiersDeployerAddresses(deployer, verifiersConfig, config.isZKsyncOS);
    }

    // ============ Direct Deployments (no deployer) ============

    function _calculateDirectDeployments(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config,
        DAContracts memory daResult
    ) internal returns (DirectDeployedAddresses memory addresses, DirectCreate2Calldata memory data) {
        // AdminFacet
        bytes memory adminFacetArgs = abi.encode(config.l1ChainId, daResult.rollupDAManager);
        (addresses.facets.adminFacet, data.adminFacetCalldata) = _calculateCreate2AddressAndCalldata(
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
        (addresses.facets.mailboxFacet, data.mailboxFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Mailbox.sol",
            "MailboxFacet",
            mailboxFacetArgs,
            config.isZKsyncOS
        );

        // ExecutorFacet
        bytes memory executorFacetArgs = abi.encode(config.l1ChainId);
        (addresses.facets.executorFacet, data.executorFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Executor.sol",
            "ExecutorFacet",
            executorFacetArgs,
            config.isZKsyncOS
        );

        // GettersFacet
        (addresses.facets.gettersFacet, data.gettersFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Getters.sol",
            "GettersFacet",
            hex"",
            config.isZKsyncOS
        );

        // MigratorFacet
        bytes memory migratorFacetArgs = abi.encode(config.l1ChainId, config.testnetVerifier);
        (addresses.facets.migratorFacet, data.migratorFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Migrator.sol",
            "MigratorFacet",
            migratorFacetArgs,
            config.isZKsyncOS
        );

        // CommitterFacet
        bytes memory committerFacetArgs = abi.encode(config.l1ChainId);
        (addresses.facets.committerFacet, data.committerFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Committer.sol",
            "CommitterFacet",
            committerFacetArgs,
            config.isZKsyncOS
        );

        // DiamondInit
        bytes memory diamondInitArgs = abi.encode(config.isZKsyncOS);
        (addresses.facets.diamondInit, data.diamondInitCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "DiamondInit.sol",
            "DiamondInit",
            diamondInitArgs,
            config.isZKsyncOS
        );

        // L1GenesisUpgrade
        (addresses.genesisUpgrade, data.genesisUpgradeCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "L1GenesisUpgrade.sol",
            "L1GenesisUpgrade",
            hex"",
            config.isZKsyncOS
        );

        // Multicall3
        (addresses.multicall3, data.multicall3Calldata) = _calculateCreate2AddressAndCalldata(
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
        bytes memory constructorArgs,
        bool _isZKsyncOS
    ) internal returns (address addr, bytes memory data) {
        bytes memory bytecode = EraZkosRouter.readBytecodeL1Raw(_isZKsyncOS, fileName, contractName);
        L1L2DeployPrepareResult memory result = EraZkosRouter.prepareL1L2Deployment(
            _isZKsyncOS,
            _create2Salt,
            bytecode,
            constructorArgs
        );
        addr = result.expectedAddress;
        data = result.data;
    }

    function _calculateCreate2AddressAndCalldata(
        bytes32 _create2Salt,
        EraZkosContract vmContract,
        bytes memory constructorArgs,
        bool _isZKsyncOS
    ) internal returns (address addr, bytes memory data) {
        (string memory fileName, string memory contractName) = EraZkosRouter.resolve(_isZKsyncOS, vmContract);
        return _calculateCreate2AddressAndCalldata(_create2Salt, fileName, contractName, constructorArgs, _isZKsyncOS);
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
        GatewayCTMFinalConfig memory ctmConfig = _buildCTMFinalConfig(
            config,
            directAddresses,
            proxyAdminResult,
            validatorTimelockResult,
            verifiersResult
        );
        (deployer, data) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            EraZkosContract.GatewayCTMDeployerCTM,
            abi.encode(ctmConfig),
            config.isZKsyncOS
        );
        result = _calculateCTMDeployerAddresses(deployer, ctmConfig, config.isZKsyncOS);
    }

    function _buildCTMFinalConfig(
        GatewayCTMDeployerConfig memory config,
        DirectDeployedAddresses memory directAddresses,
        GatewayProxyAdminDeployerResult memory proxyAdminResult,
        GatewayValidatorTimelockDeployerResult memory validatorTimelockResult,
        Verifiers memory verifiersResult
    ) internal pure returns (GatewayCTMFinalConfig memory) {
        return
            GatewayCTMFinalConfig({
                baseConfig: config,
                chainTypeManagerProxyAdmin: proxyAdminResult.chainTypeManagerProxyAdmin,
                validatorTimelockProxy: validatorTimelockResult.validatorTimelockProxy,
                facets: directAddresses.facets,
                genesisUpgrade: directAddresses.genesisUpgrade,
                verifier: verifiersResult.verifier
            });
    }

    // ============ Address Calculation Helpers ============

    function _calculateDADeployerAddresses(
        address deployerAddr,
        GatewayDADeployerConfig memory config,
        bool _isZKsyncOS
    ) internal returns (DAContracts memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        result.rollupDAManager = _deployInternalEmptyParams(
            "RollupDAManager",
            "RollupDAManager.sol",
            innerConfig,
            _isZKsyncOS
        );
        result.validiumDAValidator = _deployInternalEmptyParams(
            "ValidiumL1DAValidator",
            "ValidiumL1DAValidator.sol",
            innerConfig,
            _isZKsyncOS
        );
        result.relayedSLDAValidator = _deployInternalEmptyParams(
            "RelayedSLDAValidator",
            "RelayedSLDAValidator.sol",
            innerConfig,
            _isZKsyncOS
        );
    }

    function _calculateProxyAdminDeployerAddresses(
        address deployerAddr,
        GatewayProxyAdminDeployerConfig memory config,
        bool _isZKsyncOS
    ) internal returns (GatewayProxyAdminDeployerResult memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});
        result.chainTypeManagerProxyAdmin = _deployInternalEmptyParams(
            "ProxyAdmin",
            "ProxyAdmin.sol",
            innerConfig,
            _isZKsyncOS
        );
    }

    function _calculateValidatorTimelockDeployerAddresses(
        address deployerAddr,
        GatewayValidatorTimelockDeployerConfig memory config,
        bool _isZKsyncOS
    ) internal returns (GatewayValidatorTimelockDeployerResult memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        result.validatorTimelockImplementation = _deployInternalWithParams(
            "ValidatorTimelock",
            "ValidatorTimelock.sol",
            abi.encode(L2_BRIDGEHUB_ADDR),
            innerConfig,
            _isZKsyncOS
        );

        result.validatorTimelockProxy = _deployInternalWithParams(
            "TransparentUpgradeableProxy",
            "TransparentUpgradeableProxy.sol",
            abi.encode(
                result.validatorTimelockImplementation,
                config.chainTypeManagerProxyAdmin,
                abi.encodeCall(ValidatorTimelock.initialize, (config.aliasedGovernanceAddress, 0))
            ),
            innerConfig,
            _isZKsyncOS
        );
    }

    function _calculateVerifiersDeployerAddresses(
        address deployerAddr,
        GatewayVerifiersDeployerConfig memory config,
        bool _isZKsyncOS
    ) internal returns (Verifiers memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        {
            (string memory fflonkFile, string memory fflonkName) = EraZkosRouter.resolve(
                _isZKsyncOS,
                EraZkosContract.VerifierFflonk
            );
            result.verifierFflonk = _deployInternalEmptyParams(fflonkName, fflonkFile, innerConfig, _isZKsyncOS);
        }
        {
            (string memory plonkFile, string memory plonkName) = EraZkosRouter.resolve(
                _isZKsyncOS,
                EraZkosContract.VerifierPlonk
            );
            result.verifierPlonk = _deployInternalEmptyParams(plonkName, plonkFile, innerConfig, _isZKsyncOS);
        }
        {
            (string memory mainVerifierFile, string memory mainVerifierName) = EraZkosRouter.resolveMainVerifier(
                _isZKsyncOS,
                config.testnetVerifier
            );
            bytes memory creationArgs = EraZkosRouter.verifierCreationArgs(
                _isZKsyncOS,
                result.verifierFflonk,
                result.verifierPlonk,
                config.aliasedGovernanceAddress
            );
            result.verifier = _deployInternalWithParams(
                mainVerifierName,
                mainVerifierFile,
                creationArgs,
                innerConfig,
                _isZKsyncOS
            );
        }
    }

    function _calculateCTMDeployerAddresses(
        address deployerAddr,
        GatewayCTMFinalConfig memory config,
        bool isZKsyncOS
    ) internal returns (GatewayCTMFinalResult memory result) {
        GatewayCTMDeployerConfig memory baseConfig = config.baseConfig;
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: baseConfig.salt});

        // ServerNotifier
        result.serverNotifierImplementation = _deployInternalEmptyParams(
            "ServerNotifier",
            "ServerNotifier.sol",
            innerConfig,
            isZKsyncOS
        );

        result.serverNotifierProxy = _deployInternalWithParams(
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
        (string memory ctmFile, string memory ctmName) = EraZkosRouter.resolve(
            isZKsyncOS,
            EraZkosContract.ChainTypeManager
        );
        result.chainTypeManagerImplementation = _deployInternalWithParams(
            ctmName,
            ctmFile,
            abi.encode(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), address(0)),
            innerConfig,
            isZKsyncOS
        );

        {
            bytes memory proxyConstructorArgs = _buildCTMProxyConstructorArgs(
                config,
                baseConfig,
                result.chainTypeManagerImplementation,
                result.serverNotifierProxy,
                deployerAddr
            );
            result.diamondCutData = _buildDiamondCutDataEncoded(config.facets, baseConfig);
            result.chainTypeManagerProxy = _deployInternalWithParams(
                "TransparentUpgradeableProxy",
                "TransparentUpgradeableProxy.sol",
                proxyConstructorArgs,
                innerConfig,
                isZKsyncOS
            );
        }
    }

    function _buildDiamondCutDataEncoded(
        Facets memory facets,
        GatewayCTMDeployerConfig memory baseConfig
    ) private pure returns (bytes memory) {
        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](6);
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
        facetCuts[5] = Diamond.FacetCut({
            facet: facets.committerFacet,
            action: Diamond.Action.Add,
            isFreezable: true,
            selectors: baseConfig.committerSelectors
        });
        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            l2BootloaderBytecodeHash: baseConfig.bootloaderHash,
            l2DefaultAccountBytecodeHash: baseConfig.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: baseConfig.evmEmulatorHash
        });
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: facets.diamondInit,
            initCalldata: abi.encode(initializeData)
        });
        return abi.encode(diamondCut);
    }

    function _buildCTMProxyConstructorArgs(
        GatewayCTMFinalConfig memory config,
        GatewayCTMDeployerConfig memory baseConfig,
        address ctmImplementation,
        address serverNotifierProxy,
        address temporaryOwner
    ) private pure returns (bytes memory) {
        Diamond.DiamondCutData memory diamondCut = abi.decode(
            _buildDiamondCutDataEncoded(config.facets, baseConfig),
            (Diamond.DiamondCutData)
        );
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
            verifier: config.verifier,
            serverNotifier: serverNotifierProxy
        });
        bytes memory initCalldata = abi.encodeCall(IChainTypeManager.initialize, (diamondInitData));
        return abi.encode(ctmImplementation, config.chainTypeManagerProxyAdmin, initCalldata);
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
        contracts.stateTransition.implementations.validatorTimelock = validatorTimelockResult
            .validatorTimelockImplementation;
        contracts.stateTransition.proxies.validatorTimelock = validatorTimelockResult.validatorTimelockProxy;

        // From Verifiers deployer
        contracts.stateTransition.verifiers = verifiersResult;

        // From direct deployments
        contracts.stateTransition.facets = directAddresses.facets;
        contracts.stateTransition.genesisUpgrade = directAddresses.genesisUpgrade;
        contracts.multicall3 = directAddresses.multicall3;

        // From CTM deployer
        contracts.stateTransition.implementations.serverNotifier = ctmResult.serverNotifierImplementation;
        contracts.stateTransition.proxies.serverNotifier = ctmResult.serverNotifierProxy;
        contracts.stateTransition.implementations.chainTypeManager = ctmResult.chainTypeManagerImplementation;
        contracts.stateTransition.proxies.chainTypeManager = ctmResult.chainTypeManagerProxy;
        contracts.diamondCutData = ctmResult.diamondCutData;
    }

    /// @notice Returns the CTM core deployment config.
    function getCTMCoreDeploymentConfig(
        GatewayCTMDeployerConfig memory _config,
        DeployedContracts memory _deployedContracts
    ) internal pure returns (CTMCoreDeploymentConfig memory) {
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
                verifierOwner: _config.aliasedGovernanceAddress,
                permissionlessValidator: address(0)
            });
    }

    // ============ Internal Helpers ============

    function _deployInternalEmptyParams(
        string memory contractName,
        string memory fileName,
        InnerDeployConfig memory config,
        bool _isZKsyncOS
    ) private returns (address) {
        return _deployInternal(contractName, fileName, hex"", config, _isZKsyncOS);
    }

    function _deployInternalWithParams(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config,
        bool _isZKsyncOS
    ) private returns (address) {
        return _deployInternal(contractName, fileName, params, config, _isZKsyncOS);
    }

    function _deployInternal(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config,
        bool _isZKsyncOS
    ) private returns (address) {
        bytes memory bytecode = EraZkosRouter.readBytecodeL1Raw(_isZKsyncOS, fileName, contractName);
        return EraZkosRouter.computeCreate2Address(_isZKsyncOS, config.deployerAddr, config.salt, bytecode, params);
    }

    // ============ Factory Dependencies ============

    /// @notice Returns all factory dependencies for deployment.
    /// @return dependencies Array of bytecodes needed for deployment.
    function getListOfFactoryDeps(
        GatewayCTMDeployerConfig memory config
    ) external returns (bytes[] memory dependencies) {
        return EraZkosRouter.gatewayCTMEraFactoryDependencies(config.isZKsyncOS);
    }
}
