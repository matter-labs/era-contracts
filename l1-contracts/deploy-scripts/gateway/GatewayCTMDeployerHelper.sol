// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

// solhint-disable no-console

import {console2 as console} from "forge-std/Script.sol";
import {SystemContractsProcessing} from "../upgrade/SystemContractsProcessing.s.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {ZKsyncOSChainTypeManager} from "contracts/state-transition/ZKsyncOSChainTypeManager.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";

import {
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_CHAIN_ASSET_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ChainTypeManagerInitializeData, IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";

import {Utils} from "../utils/Utils.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {CTMContract, CTMCoreDeploymentConfig, DeployCTML1OrGateway} from "../ctm/DeployCTML1OrGateway.sol";

import {Facets, Verifiers} from "contracts/common/StateTransitionTypes.sol";
import {GenesisManifestLib} from "contracts/upgrades/registry/libraries/GenesisManifestLib.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";

import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";

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
import {
    GenesisConfig,
    GenesisFacet,
    ReleaseGenesisData,
    ReleaseManifest,
    PinnedContract
} from "../../contracts/upgrades/registry/RegistryTypes.sol";

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
    /// @dev The bootstrap `CTMRelease`. It is a direct CREATE2 deployment like the facets: a
    ///      release takes its manifest as a CONSTRUCTOR argument, so its address is a commitment
    ///      to that manifest and cannot be produced from inside the CTM deployer.
    address currentRelease;
    bytes32 currentReleaseCodehash;
    /// @dev Predicted LIVE codehashes (EXTCODEHASH after deployment) in genesisFacetSlots order:
    ///      admin, getters, mailbox, executor, migrator, committer. On an EVM-equivalent Gateway
    ///      these come from a local simulated deployment (immutables get patched into runtime
    ///      code, so the raw artifact hash would be wrong); on EraVM from the versioned ZK
    ///      bytecode hash (immutables live in the simulator, not the code).
    bytes32[6] genesisFacetCodehashes;
    /// @dev Each facet's OWN `ISelfDescribingFacet.selectors()` output (exact embedded order —
    ///      `abi.encode` of the manifest is order-sensitive), read from a locally simulated
    ///      deployment of the facet's EVM twin (the embedded constant is source-level, identical
    ///      across compile targets).
    bytes4[][6] genesisFacetSelectors;
    bytes32 diamondInitCodehash;
    bytes32 genesisUpgradeCodehash;
    /// @dev The main verifier and its predicted live codehash. Not a direct deployment (it comes
    ///      from the verifiers deployer), but it is part of the genesis manifest, so it is carried
    ///      here with the other predicted manifest inputs.
    address verifier;
    bytes32 verifierCodehash;
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
    bytes currentReleaseCalldata;
}

struct CalculateAddressesIntermediate {
    DAContracts daResult;
    GatewayProxyAdminDeployerResult proxyAdminResult;
    GatewayValidatorTimelockDeployerResult validatorTimelockResult;
    Verifiers verifiersResult;
}

/// @notice Result of preparing an L1->L2 deployment (CREATE2 via the ZKsyncOS deterministic factory).
struct L1L2DeployPrepareResult {
    address expectedAddress;
    bytes data;
    address targetAddress;
}

library GatewayCTMDeployerHelper {
    // Mirrors GenesisManifestLib.GENESIS_FACET_COUNT (cross-library constants cannot size arrays).
    uint256 internal constant GENESIS_FACET_COUNT_LOCAL = 6;

    /// @notice Calculates all addresses for the deployment.
    /// @dev Uses 5 deployers + direct contract deployments.
    /// @param _create2Salt Salt used for CREATE2 when deploying the deployers.
    /// @param config The full deployment configuration (ZKsyncOS only).
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
            DeployedContracts memory,
            DeployerCreate2Calldata memory,
            DeployerAddresses memory,
            DirectCreate2Calldata memory,
            address
        )
    {
        return calculateAddresses(_create2Salt, config, SystemContractsProcessing.buildL2BytecodeInfoTable());
    }

    /// @param _l2BytecodeInfos The release's L2 bytecode table (`ReleaseManifest.l2BytecodeInfos`),
    ///        taken as an argument so bytecode-light callers can substitute it — the default
    ///        builder reads every L2 contract's bytecode from artifacts.
    function calculateAddresses(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config,
        bytes[] memory _l2BytecodeInfos
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
        // Use Arachnid deterministic CREATE2 by default (GW path),
        create2FactoryAddress = Utils.DETERMINISTIC_CREATE2_ADDRESS;
        (contracts, deployerCalldata, deployers, directCalldata) = _calculateAddressesInner(
            _create2Salt,
            config,
            _l2BytecodeInfos
        );
    }

    function _calculateAddressesInner(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory config,
        bytes[] memory _l2BytecodeInfos
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
        directAddresses.verifier = im.verifiersResult.verifier;
        directAddresses.verifierCodehash = _mainVerifierCodehash(config, im.verifiersResult);
        // Last, because the manifest it commits to names every facet AND the verifier.
        (
            directAddresses.currentRelease,
            directAddresses.currentReleaseCodehash,
            directCalldata.currentReleaseCalldata
        ) = _calculateBootstrapRelease(_create2Salt, config, directAddresses, _l2BytecodeInfos);

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
        // Assigned after assembly to keep this function's call-site stack flat.
        contracts.stateTransition.currentRelease = directAddresses.currentRelease;
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

        bytes memory bytecode = BytecodeUtils.readBytecodeL1("GatewayCTMDeployerDA.sol", "GatewayCTMDeployerDA");
        bytes memory constructorArgs = abi.encode(daConfig);

        L1L2DeployPrepareResult memory deployResult = _prepareL1L2Deployment(_create2Salt, bytecode, constructorArgs);
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        _logGatewayVerifyContract(deployer, "GatewayCTMDeployerDA", constructorArgs);
        result = _calculateDADeployerAddresses(deployer, daConfig);
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

        bytes memory bytecode = BytecodeUtils.readBytecodeL1(
            "GatewayCTMDeployerProxyAdmin.sol",
            "GatewayCTMDeployerProxyAdmin"
        );
        bytes memory constructorArgs = abi.encode(proxyAdminConfig);

        L1L2DeployPrepareResult memory deployResult = _prepareL1L2Deployment(_create2Salt, bytecode, constructorArgs);
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        _logGatewayVerifyContract(deployer, "GatewayCTMDeployerProxyAdmin", constructorArgs);
        result = _calculateProxyAdminDeployerAddresses(deployer, proxyAdminConfig);
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

        bytes memory bytecode = BytecodeUtils.readBytecodeL1(
            "GatewayCTMDeployerValidatorTimelock.sol",
            "GatewayCTMDeployerValidatorTimelock"
        );
        bytes memory constructorArgs = abi.encode(vtConfig);

        L1L2DeployPrepareResult memory deployResult = _prepareL1L2Deployment(_create2Salt, bytecode, constructorArgs);
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        _logGatewayVerifyContract(deployer, "GatewayCTMDeployerValidatorTimelock", constructorArgs);
        result = _calculateValidatorTimelockDeployerAddresses(deployer, vtConfig);
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

        (string memory vdFile, string memory vdName) = DeployCTML1OrGateway.resolve(
            CTMContract.GatewayCTMDeployerVerifiers
        );
        bytes memory bytecode = BytecodeUtils.readBytecodeL1(vdFile, vdName);
        bytes memory constructorArgs = abi.encode(verifiersConfig);

        L1L2DeployPrepareResult memory deployResult = _prepareL1L2Deployment(_create2Salt, bytecode, constructorArgs);
        deployer = deployResult.expectedAddress;
        data = deployResult.data;
        _logGatewayVerifyContract(deployer, vdName, constructorArgs);
        result = _calculateVerifiersDeployerAddresses(deployer, verifiersConfig);
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
            adminFacetArgs
        );
        (addresses.genesisFacetSelectors[0], addresses.genesisFacetCodehashes[0]) = _simulateFacetRow(
            "Admin.sol",
            "AdminFacet",
            adminFacetArgs
        );

        // MailboxFacet
        bytes memory mailboxFacetArgs = abi.encode(
            config.l1ChainId,
            L2_CHAIN_ASSET_HANDLER_ADDR,
            address(0), // eip7702Checker
            config.testnetVerifier
        );
        (addresses.facets.mailboxFacet, data.mailboxFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Mailbox.sol",
            "MailboxFacet",
            mailboxFacetArgs
        );
        (addresses.genesisFacetSelectors[2], addresses.genesisFacetCodehashes[2]) = _simulateFacetRow(
            "Mailbox.sol",
            "MailboxFacet",
            mailboxFacetArgs
        );

        // ExecutorFacet
        (addresses.facets.executorFacet, data.executorFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Executor.sol",
            "ExecutorFacet",
            hex""
        );
        (addresses.genesisFacetSelectors[3], addresses.genesisFacetCodehashes[3]) = _simulateFacetRow(
            "Executor.sol",
            "ExecutorFacet",
            hex""
        );

        // GettersFacet
        (addresses.facets.gettersFacet, data.gettersFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Getters.sol",
            "GettersFacet",
            hex""
        );
        (addresses.genesisFacetSelectors[1], addresses.genesisFacetCodehashes[1]) = _simulateFacetRow(
            "Getters.sol",
            "GettersFacet",
            hex""
        );

        // MigratorFacet
        bytes memory migratorFacetArgs = abi.encode(config.l1ChainId, config.testnetVerifier);
        (addresses.facets.migratorFacet, data.migratorFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Migrator.sol",
            "MigratorFacet",
            migratorFacetArgs
        );
        (addresses.genesisFacetSelectors[4], addresses.genesisFacetCodehashes[4]) = _simulateFacetRow(
            "Migrator.sol",
            "MigratorFacet",
            migratorFacetArgs
        );

        // CommitterFacet
        bytes memory committerFacetArgs = abi.encode(config.l1ChainId);
        (addresses.facets.committerFacet, data.committerFacetCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Committer.sol",
            "CommitterFacet",
            committerFacetArgs
        );
        (addresses.genesisFacetSelectors[5], addresses.genesisFacetCodehashes[5]) = _simulateFacetRow(
            "Committer.sol",
            "CommitterFacet",
            committerFacetArgs
        );

        // DiamondInit — `DiamondInit(bool _isZKOS)`, always ZKsync OS.
        bytes memory diamondInitArgs = abi.encode(true);
        (addresses.facets.diamondInit, data.diamondInitCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "DiamondInit.sol",
            "DiamondInit",
            diamondInitArgs
        );
        addresses.diamondInitCodehash = _simulatedCodehash("DiamondInit.sol", "DiamondInit", diamondInitArgs);

        // L1GenesisUpgrade
        (addresses.genesisUpgrade, data.genesisUpgradeCalldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "L1GenesisUpgrade.sol",
            "L1GenesisUpgrade",
            hex""
        );
        addresses.genesisUpgradeCodehash = _simulatedCodehash("L1GenesisUpgrade.sol", "L1GenesisUpgrade", hex"");

        // Multicall3
        (addresses.multicall3, data.multicall3Calldata) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "Multicall3.sol",
            "Multicall3",
            hex""
        );
    }

    function _calculateCreate2AddressAndCalldata(
        bytes32 _create2Salt,
        string memory fileName,
        string memory contractName,
        bytes memory constructorArgs
    ) internal returns (address addr, bytes memory data) {
        bytes memory bytecode = BytecodeUtils.readBytecodeL1(fileName, contractName);
        L1L2DeployPrepareResult memory result = _prepareL1L2Deployment(_create2Salt, bytecode, constructorArgs);
        addr = result.expectedAddress;
        data = result.data;
        _logGatewayVerifyContract(addr, contractName, constructorArgs);
    }

    function _calculateCreate2AddressAndCalldata(
        bytes32 _create2Salt,
        CTMContract vmContract,
        bytes memory constructorArgs
    ) internal returns (address addr, bytes memory data) {
        (string memory fileName, string memory contractName) = DeployCTML1OrGateway.resolve(vmContract);
        return _calculateCreate2AddressAndCalldata(_create2Salt, fileName, contractName, constructorArgs);
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
            CTMContract.GatewayCTMDeployerCTM,
            abi.encode(ctmConfig)
        );
        result = _calculateCTMDeployerAddresses(
            deployer,
            ctmConfig,
            directAddresses.currentRelease,
            directAddresses.currentReleaseCodehash
        );
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
                verifier: verifiersResult.verifier,
                currentRelease: directAddresses.currentRelease
            });
    }

    /// @dev The manifest is the release's constructor argument, so the CREATE2 address is itself a
    ///      commitment to it: a different manifest lands at a different address, and the release
    ///      that lands at the predicted one can only be the audited manifest.
    function _calculateBootstrapRelease(
        bytes32 _create2Salt,
        GatewayCTMDeployerConfig memory _config,
        DirectDeployedAddresses memory _direct,
        bytes[] memory _l2BytecodeInfos
    ) internal returns (address releaseAddr, bytes32 releaseCodehash, bytes memory calldataOut) {
        bytes memory manifestArgs = abi.encode(_reconstructGenesisManifest(_direct, _config, _l2BytecodeInfos));
        (releaseAddr, calldataOut) = _calculateCreate2AddressAndCalldata(
            _create2Salt,
            "CTMRelease.sol",
            "CTMRelease",
            manifestArgs
        );
        // NOT `_simulatedCodehash`: a release validates its manifest's pins against LIVE code in
        // its constructor, and none of the pinned targets exist at prediction time. A release has
        // no immutables either, so its runtime code is exactly the artifact's.
        releaseCodehash = keccak256(BytecodeUtils.readDeployedBytecodeL1("CTMRelease.sol", "CTMRelease"));
    }

    /// @dev Rebuilds — from build artifacts and simulated deployments, byte-identically — the
    ///      genesis manifest the bootstrap release is constructed with
    ///      (`GenesisManifestLib.buildGenesisManifest`). The facets do not exist at prediction
    ///      time, so selectors come from each facet's EVM build artifact via `cast selectors`
    ///      (the same drift-guarded source the facets' own `ISelfDescribingFacet.selectors()`
    ///      embeds) and codehashes from `_simulatedCodehash` (see {DirectDeployedAddresses}).
    function _reconstructGenesisManifest(
        DirectDeployedAddresses memory _direct,
        GatewayCTMDeployerConfig memory _baseConfig,
        bytes[] memory _l2BytecodeInfos
    ) private pure returns (ReleaseManifest memory) {
        (
            address[GENESIS_FACET_COUNT_LOCAL] memory addrs,
            bool[GENESIS_FACET_COUNT_LOCAL] memory freezable
        ) = GenesisManifestLib.genesisFacetSlots(_direct.facets);

        // Slot order matches {GenesisManifestLib.genesisFacetSlots} and the simulated rows in
        // `DirectDeployedAddresses` (selectors in the facets' own embedded order).
        GenesisFacet[] memory rows = new GenesisFacet[](GENESIS_FACET_COUNT_LOCAL);
        for (uint256 i = 0; i < GENESIS_FACET_COUNT_LOCAL; ++i) {
            rows[i] = GenesisFacet({
                facet: PinnedContract({addr: addrs[i], codehash: _direct.genesisFacetCodehashes[i]}),
                isFreezable: freezable[i]
            });
        }

        return
            GenesisManifestLib.buildGenesisManifestFromRows(
                GenesisConfig({
                    facets: _direct.facets,
                    verifier: _direct.verifier,
                    genesisUpgrade: _direct.genesisUpgrade,
                    genesis: ReleaseGenesisData({
                        bootloaderHash: _baseConfig.bootloaderHash,
                        defaultAccountHash: _baseConfig.defaultAccountHash,
                        evmEmulatorHash: _baseConfig.evmEmulatorHash,
                        fixedForceDeploymentsData: _baseConfig.forceDeploymentsData,
                        genesisBatchHash: _baseConfig.genesisRoot,
                        genesisBatchCommitment: _baseConfig.genesisBatchCommitment,
                        genesisIndexRepeatedStorageChanges: uint64(_baseConfig.genesisRollupLeafIndex)
                    }),
                    l2BytecodeInfos: _l2BytecodeInfos
                }),
                rows,
                _direct.diamondInitCodehash,
                _direct.verifierCodehash,
                _direct.genesisUpgradeCodehash
            );
    }

    /// @dev One facet's manifest row inputs from a LOCAL simulated deployment of its EVM twin:
    ///      `selectors()` in the facet's own embedded order (the manifest encoding is
    ///      order-sensitive) and the flavour-appropriate codehash.
    function _simulateFacetRow(
        string memory _fileName,
        string memory _contractName,
        bytes memory _constructorArgs
    ) private returns (bytes4[] memory selectors, bytes32 codehash) {
        address simulated = _simulateDeploy(_fileName, _contractName, _constructorArgs);
        selectors = ISelfDescribingFacet(simulated).selectors();
        codehash = simulated.codehash;
    }

    /// @dev A stand-in Gateway chain id for local simulation: some facet constructors VALIDATE
    ///      against `block.chainid` (e.g. Mailbox allows a zero EIP-7702 checker only off-L1),
    ///      so the simulation must not run under the L1 chain id. The runtime code is
    ///      chainid-independent (immutables are constructor-args-only), so any non-L1 value
    ///      yields the exact Gateway runtime bytecode.
    uint256 internal constant SIMULATED_GATEWAY_CHAIN_ID = type(uint48).max;

    /// @dev Deploys an artifact locally (CREATE) so runtime-code-derived values (codehash,
    ///      self-described selectors) can be read exactly as they will exist on the Gateway.
    function _simulateDeploy(
        string memory _fileName,
        string memory _contractName,
        bytes memory _constructorArgs
    ) private returns (address simulated) {
        bytes memory initCode = abi.encodePacked(
            BytecodeUtils.readBytecodeL1(_fileName, _contractName),
            _constructorArgs
        );
        uint256 previousChainId = block.chainid;
        Utils.vm.chainId(SIMULATED_GATEWAY_CHAIN_ID);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            simulated := create(0, add(initCode, 0x20), mload(initCode))
        }
        Utils.vm.chainId(previousChainId);
        require(simulated != address(0), "codehash simulation deploy failed");
    }

    /// @dev What EXTCODEHASH will return for this artifact once deployed on the Gateway flavour.
    ///      EVM-equivalent Gateway: immutables are patched into the runtime code, so the value
    ///      comes from a LOCAL simulated deployment with the exact constructor args (deterministic
    ///      — the constructors only consume their arguments). EraVM: immutables live in the
    ///      simulator, so the versioned ZK bytecode hash IS the codehash.
    function _simulatedCodehash(
        string memory _fileName,
        string memory _contractName,
        bytes memory _constructorArgs
    ) private returns (bytes32) {
        return _simulateDeploy(_fileName, _contractName, _constructorArgs).codehash;
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
        result.rollupSLDAValidator = _deployInternalEmptyParams(
            "RelayedSLDAValidator",
            "RelayedSLDAValidator.sol",
            innerConfig
        );
    }

    function _calculateProxyAdminDeployerAddresses(
        address deployerAddr,
        GatewayProxyAdminDeployerConfig memory config
    ) internal returns (GatewayProxyAdminDeployerResult memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});
        result.chainTypeManagerProxyAdmin = _deployInternalEmptyParams("ProxyAdmin", "ProxyAdmin.sol", innerConfig);
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

    function _calculateVerifiersDeployerAddresses(
        address deployerAddr,
        GatewayVerifiersDeployerConfig memory config
    ) internal returns (Verifiers memory result) {
        InnerDeployConfig memory innerConfig = InnerDeployConfig({deployerAddr: deployerAddr, salt: config.salt});

        {
            (string memory plonkFile, string memory plonkName) = DeployCTML1OrGateway.resolve(
                CTMContract.VerifierPlonk
            );
            result.verifierPlonk = _deployInternalEmptyParams(plonkName, plonkFile, innerConfig);
        }
        {
            (string memory mainVerifierFile, string memory mainVerifierName) = DeployCTML1OrGateway.resolveMainVerifier(
                config.testnetVerifier
            );
            bytes memory creationArgs = abi.encode(result.verifierPlonk);
            result.verifier = _deployInternalWithParams(mainVerifierName, mainVerifierFile, creationArgs, innerConfig);
        }
    }

    /// @dev The predicted live codehash of the main verifier, resolved through the same
    ///      file/name/args triple `_calculateVerifiersDeployerAddresses` uses to predict its
    ///      address, so the manifest reconstruction matches what the deployer produces on-chain.
    function _mainVerifierCodehash(
        GatewayCTMDeployerConfig memory config,
        Verifiers memory verifiersResult
    ) internal returns (bytes32) {
        (string memory mainVerifierFile, string memory mainVerifierName) = DeployCTML1OrGateway.resolveMainVerifier(
            config.testnetVerifier
        );
        bytes memory creationArgs = abi.encode(verifiersResult.verifierPlonk);
        return _simulatedCodehash(mainVerifierFile, mainVerifierName, creationArgs);
    }

    function _calculateCTMDeployerAddresses(
        address deployerAddr,
        GatewayCTMFinalConfig memory config,
        address predictedRelease,
        bytes32 predictedReleaseCodehash
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
        (string memory ctmFile, string memory ctmName) = DeployCTML1OrGateway.resolve(CTMContract.ChainTypeManager);
        result.chainTypeManagerImplementation = _deployInternalWithParams(
            ctmName,
            ctmFile,
            abi.encode(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), address(0)),
            innerConfig
        );

        {
            bytes memory proxyConstructorArgs = _buildCTMProxyConstructorArgs(
                config,
                baseConfig,
                result.chainTypeManagerImplementation,
                result.serverNotifierProxy,
                predictedRelease,
                predictedReleaseCodehash
            );
            result.diamondCutData = _buildDiamondCutDataEncoded(config.facets, baseConfig);
            result.chainTypeManagerProxy = _deployInternalWithParams(
                "TransparentUpgradeableProxy",
                "TransparentUpgradeableProxy.sol",
                proxyConstructorArgs,
                innerConfig
            );
        }
    }

    function _buildDiamondCutDataEncoded(
        Facets memory facets,
        GatewayCTMDeployerConfig memory baseConfig
    ) private pure returns (bytes memory) {
        // Mirrors GatewayCTMDeployerCTMBase: the cut carries NO facet addresses (empty
        // `facetCuts`) and NO init payload (empty `initCalldata`), only a pointer to the genesis
        // registry set in `ChainCreationParams` below. DiamondInit reads the registry and
        // installs the facets and base system contract hashes itself. Empty here means this
        // off-chain reconstruction matches the on-chain cut exactly (both feed the CTM proxy's
        // CREATE2 address).
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: facets.diamondInit,
            initCalldata: ""
        });
        return abi.encode(diamondCut);
    }

    function _buildCTMProxyConstructorArgs(
        GatewayCTMFinalConfig memory config,
        GatewayCTMDeployerConfig memory baseConfig,
        address ctmImplementation,
        address serverNotifierProxy,
        address currentRelease,
        bytes32 currentReleaseCodehash
    ) private pure returns (bytes memory) {
        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: baseConfig.aliasedGovernanceAddress,
            validatorTimelock: config.validatorTimelockProxy,
            releaseCodehash: currentReleaseCodehash,
            currentRelease: currentRelease,
            protocolVersion: baseConfig.protocolVersion,
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
    ) internal view returns (DeployedContracts memory contracts) {
        // From DA deployer
        contracts.daContracts.rollupDAManager = daResult.rollupDAManager;
        contracts.daContracts.validiumDAValidator = daResult.validiumDAValidator;
        contracts.daContracts.rollupSLDAValidator = daResult.rollupSLDAValidator;

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
                testnetVerifier: _config.testnetVerifier,
                l1ChainId: _config.l1ChainId,
                bridgehubProxy: L2_BRIDGEHUB_ADDR,
                interopCenterProxy: L2_INTEROP_CENTER_ADDR,
                rollupDAManager: _deployedContracts.daContracts.rollupDAManager,
                chainAssetHandler: L2_CHAIN_ASSET_HANDLER_ADDR,
                l1BytecodesSupplier: address(0),
                eip7702Checker: address(0),
                verifierFflonk: _deployedContracts.stateTransition.verifiers.verifierFflonk,
                verifierPlonk: _deployedContracts.stateTransition.verifiers.verifierPlonk,
                permissionlessValidator: address(0)
            });
    }

    // ============ Internal Helpers ============

    function _deployInternalEmptyParams(
        string memory contractName,
        string memory fileName,
        InnerDeployConfig memory config
    ) private returns (address) {
        return _deployInternal(contractName, fileName, hex"", config);
    }

    function _deployInternalWithParams(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config
    ) private returns (address) {
        return _deployInternal(contractName, fileName, params, config);
    }

    function _deployInternal(
        string memory contractName,
        string memory fileName,
        bytes memory params,
        InnerDeployConfig memory config
    ) private returns (address addr) {
        bytes memory bytecode = BytecodeUtils.readBytecodeL1(fileName, contractName);
        addr = _computeCreate2Address(config.deployerAddr, config.salt, bytecode, params);
        _logGatewayVerifyContract(addr, contractName, params);
    }

    // ============ Factory Dependencies ============

    /// @notice Returns all factory dependencies for deployment.
    /// @dev ZKsyncOS gateway deployments are EVM-equivalent and need no EraVM factory dependencies.
    function getListOfFactoryDeps(
        GatewayCTMDeployerConfig memory // config
    ) external returns (bytes[] memory dependencies) {
        return dependencies;
    }

    // ======================== Deployment utilities ========================

    function _computeCreate2Address(
        address _deployer,
        bytes32 _salt,
        bytes memory _bytecode,
        bytes memory _constructorArgs
    ) private pure returns (address) {
        bytes memory initCode = abi.encodePacked(_bytecode, _constructorArgs);
        return Utils.vm.computeCreate2Address(_salt, keccak256(initCode), _deployer);
    }

    function _prepareL1L2Deployment(
        bytes32 _salt,
        bytes memory _bytecode,
        bytes memory _constructorArgs
    ) private view returns (L1L2DeployPrepareResult memory result) {
        // ZKsyncOS gateway deploys are EVM-equivalent and go through the deterministic CREATE2 factory.
        result.targetAddress = Utils.DETERMINISTIC_CREATE2_ADDRESS;
        bytes memory initCode = abi.encodePacked(_bytecode, _constructorArgs);
        result.expectedAddress = Utils.getL2AddressViaDeterministicCreate2(_salt, initCode);
        result.data = Utils.getDeterministicCreate2FactoryCalldata(_salt, initCode);
    }

    /// Emit a `forge verify-contract` line for a GW-side deploy. GW contracts
    /// are EVM-equivalent (ZKsync OS), so no toolchain flag is needed — the
    /// operator supplies the GW chain id and (if required) a custom
    /// `--verifier-url` at script invocation time. Routing into
    /// `gw-verification-logs.txt` is handled on the Rust side based on the
    /// emitting forge script (`GatewayVotePreparation.s.sol`).
    function _logGatewayVerifyContract(
        address contractAddr,
        string memory contractName,
        bytes memory constructorArgs
    ) internal view {
        string memory msgStr;
        if (constructorArgs.length == 0) {
            msgStr = string.concat("forge verify-contract ", Utils.vm.toString(contractAddr), " ", contractName);
        } else {
            msgStr = string.concat(
                "forge verify-contract ",
                Utils.vm.toString(contractAddr),
                " ",
                contractName,
                " --constructor-args ",
                Utils.vm.toString(constructorArgs)
            );
        }
        console.log(msgStr);
    }
}
