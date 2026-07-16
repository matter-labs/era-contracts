// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../libraries/Diamond.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ChainTypeManagerInitializeData, IChainTypeManager} from "../../IChainTypeManager.sol";
import {ServerNotifier} from "../../../governance/ServerNotifier.sol";

import {Facets} from "contracts/common/StateTransitionTypes.sol";
import {CTMRelease} from "../../../upgrades/registry/CTMRelease.sol";
import {GenesisManifestLib} from "../../../upgrades/registry/GenesisManifestLib.sol";
import {GatewayCTMDeployerConfig, GatewayCTMFinalConfig, GatewayCTMFinalResult} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerCTMBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Base contract for Gateway CTM deployer.
/// @dev Contains shared logic for deploying ServerNotifier and CTM.
/// Subclasses implement _deployCTMImplementation to deploy the specific CTM type.
abstract contract GatewayCTMDeployerCTMBase {
    GatewayCTMFinalResult internal deployedResult;

    /// @notice Returns the deployed contracts from this deployer.
    /// @return result The struct with information about the deployed contracts.
    function getResult() external view returns (GatewayCTMFinalResult memory result) {
        result = deployedResult;
    }

    /// @notice Initializes the deployer and deploys all contracts.
    /// @param _config The deployment configuration.
    function _deployInner(GatewayCTMFinalConfig memory _config) internal {
        bytes32 salt = _config.baseConfig.salt;

        GatewayCTMFinalResult memory result;

        // Deploy ServerNotifier (with this contract as temporary owner)
        _deployServerNotifier(salt, _config, result);

        // Deploy CTM
        _deployCTM(salt, _config, result);

        // Link ServerNotifier to CTM and transfer ownership
        _setChainTypeManagerInServerNotifier(_config.baseConfig.aliasedGovernanceAddress, result);

        deployedResult = result;
    }

    /// @notice Deploys the ServerNotifier contract.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _config The deployment config.
    /// @param _result The result struct to populate with server notifier addresses.
    function _deployServerNotifier(
        bytes32 _salt,
        GatewayCTMFinalConfig memory _config,
        GatewayCTMFinalResult memory _result
    ) internal {
        _result.serverNotifierImplementation = address(new ServerNotifier{salt: _salt}());
        _result.serverNotifierProxy = address(
            new TransparentUpgradeableProxy{salt: _salt}(
                _result.serverNotifierImplementation,
                _config.chainTypeManagerProxyAdmin,
                abi.encodeCall(ServerNotifier.initialize, (address(this)))
            )
        );
    }

    /// @notice Deploys the ChainTypeManager implementation contract.
    /// @dev Must be implemented by subclasses to deploy the specific CTM type.
    /// @dev PermissionlessValidator is hardcoded to address(0) since Priority Mode is L1-only.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @return The address of the deployed CTM implementation.
    function _deployCTMImplementation(bytes32 _salt) internal virtual returns (address);

    /// @notice Deploys the ChainTypeManager contract.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _config The deployment config.
    /// @param _result The result struct to populate with CTM addresses.
    function _deployCTM(
        bytes32 _salt,
        GatewayCTMFinalConfig memory _config,
        GatewayCTMFinalResult memory _result
    ) internal {
        _result.chainTypeManagerImplementation = _deployCTMImplementation(_salt);

        GatewayCTMDeployerConfig memory baseConfig = _config.baseConfig;
        Facets memory facets = _config.facets;

        // Gateway pins a genesis registry, exactly like L1: the committed cut carries NO facet
        // addresses (empty `facetCuts`) and NO init payload (empty `initCalldata`), only a
        // pointer to the registry. `DiamondInit` reads the registry (via the CTM's
        // `genesisRegistry()`) and installs the facets itself, resolving each facet's selectors
        // from its own `ISelfDescribingFacet.selectors()` bytecode; the base system contract
        // hashes are read from the registry too. The registry contract is deployed DIRECTLY via
        // CREATE2 (no constructor, so its address is independent of the pinned values — the
        // off-chain helper can put it in the cut before any facet exists) and initialized HERE,
        // in the same deployer flow governance approved.
        address currentRelease = _initializeCurrentRelease(
            _config.bootstrapRegistry,
            _config.genesisUpgrade,
            _config.verifier,
            baseConfig,
            facets
        );

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: facets.diamondInit,
            initCalldata: ""
        });

        _result.diamondCutData = abi.encode(diamondCut);

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: baseConfig.aliasedGovernanceAddress,
            validatorTimelock: _config.validatorTimelockProxy,
            currentRelease: currentRelease,
            protocolVersion: baseConfig.protocolVersion,
            verifier: _config.verifier,
            serverNotifier: _result.serverNotifierProxy
        });

        bytes memory initCalldata = abi.encodeCall(IChainTypeManager.initialize, (diamondInitData));

        _result.chainTypeManagerProxy = address(
            new TransparentUpgradeableProxy{salt: _salt}(
                _result.chainTypeManagerImplementation,
                _config.chainTypeManagerProxyAdmin,
                initCalldata
            )
        );
    }

    /// @notice Initializes the (directly deployed, still-uninitialized) bootstrap registry with
    ///         the genesis manifest. The facet order and freezability mirror the diamond's
    ///         installed set.
    /// @param _release The pre-deployed bootstrap `CTMRelease` address.
    /// @param _genesisUpgrade The L1 genesis upgrade contract new chains run at creation.
    /// @param _verifier The verifier pinned by the release.
    /// @param _baseConfig The deployment config (protocol version, base system hashes, genesis).
    /// @param _facets The deployed diamond facet addresses.
    /// @return release The initialized bootstrap release (echoed back).
    function _initializeCurrentRelease(
        address _release,
        address _genesisUpgrade,
        address _verifier,
        GatewayCTMDeployerConfig memory _baseConfig,
        Facets memory _facets
    ) internal returns (address release) {
        CTMRelease(_release).initialize(
            GenesisManifestLib.buildGenesisManifest(
                GenesisManifestLib.GenesisConfig({
                    isZKsyncOS: _baseConfig.isZKsyncOS,
                    protocolVersion: _baseConfig.protocolVersion,
                    verifier: _verifier,
                    facets: _facets,
                    bootloaderHash: _baseConfig.bootloaderHash,
                    defaultAccountHash: _baseConfig.defaultAccountHash,
                    evmEmulatorHash: _baseConfig.evmEmulatorHash,
                    genesisUpgrade: _genesisUpgrade,
                    genesisBatchHash: _baseConfig.genesisRoot,
                    genesisBatchCommitment: _baseConfig.genesisBatchCommitment,
                    genesisIndexRepeatedStorageChanges: uint64(_baseConfig.genesisRollupLeafIndex),
                    fixedForceDeploymentsData: _baseConfig.forceDeploymentsData
                })
            )
        );
        release = _release;
    }

    /// @notice Sets the previously deployed CTM inside the ServerNotifier and transfers ownership.
    /// @param _aliasedGovernanceAddress The aliased address of the governance.
    /// @param _result The result struct containing the deployed addresses.
    function _setChainTypeManagerInServerNotifier(
        address _aliasedGovernanceAddress,
        GatewayCTMFinalResult memory _result
    ) internal {
        ServerNotifier serverNotifier = ServerNotifier(_result.serverNotifierProxy);
        serverNotifier.setChainTypeManager(IChainTypeManager(_result.chainTypeManagerProxy));
        serverNotifier.transferOwnership(_aliasedGovernanceAddress);
    }
}
