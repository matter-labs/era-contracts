// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../libraries/Diamond.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "../../chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "../../IChainTypeManager.sol";
import {ServerNotifier} from "../../../governance/ServerNotifier.sol";

import {Facets} from "contracts/common/StateTransitionTypes.sol";
import {CTMContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {GatewayGenesisRegistry} from "./GatewayGenesisRegistry.sol";
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
        // addresses (empty `facetCuts`), only a pointer to the registry. `DiamondInit` reads the
        // registry (via the CTM's `genesisRegistry()`) and installs the facets itself, resolving
        // each facet's selectors from its own `ISelfDescribingFacet.selectors()` bytecode. The
        // registry is deployed via CREATE2 (deterministic address, independent of the facet
        // addresses) so the off-chain helper can put it in the cut before any facet exists.
        address genesisRegistry = _deployGenesisRegistry(_salt, baseConfig.protocolVersion, facets);

        Diamond.FacetCut[] memory facetCuts = new Diamond.FacetCut[](0);

        // Only system contract hashes are initialized here; the verifier is read from the CTM.
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

        _result.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: _config.genesisUpgrade,
            genesisBatchHash: baseConfig.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(baseConfig.genesisRollupLeafIndex),
            genesisBatchCommitment: baseConfig.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: baseConfig.forceDeploymentsData,
            registry: genesisRegistry
        });

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: baseConfig.aliasedGovernanceAddress,
            validatorTimelock: _config.validatorTimelockProxy,
            chainCreationParams: chainCreationParams,
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

    /// @notice Deploys the Gateway genesis facet registry and pins the facet set into it.
    /// @dev CREATE2 with the shared salt: the address is deterministic and independent of the
    ///      facet addresses (no constructor args), so the off-chain helper reproduces it for the
    ///      genesis cut before the facets are deployed. Initialized in the same transaction; the
    ///      facet order and freezability mirror the diamond's installed set.
    /// @param _salt Salt used for the CREATE2 deployment.
    /// @param _protocolVersion The packed SemVer protocol version new chains are created at.
    /// @param _facets The deployed diamond facet addresses.
    /// @return registry The address of the deployed and initialized genesis registry.
    function _deployGenesisRegistry(
        bytes32 _salt,
        uint256 _protocolVersion,
        Facets memory _facets
    ) internal returns (address registry) {
        CTMContract[] memory facetIds = new CTMContract[](6);
        address[] memory facetAddresses = new address[](6);
        bool[] memory freezable = new bool[](6);

        facetIds[0] = CTMContract.AdminFacet;
        facetAddresses[0] = _facets.adminFacet;
        freezable[0] = false;

        facetIds[1] = CTMContract.GettersFacet;
        facetAddresses[1] = _facets.gettersFacet;
        freezable[1] = false;

        facetIds[2] = CTMContract.MailboxFacet;
        facetAddresses[2] = _facets.mailboxFacet;
        freezable[2] = true;

        facetIds[3] = CTMContract.ExecutorFacet;
        facetAddresses[3] = _facets.executorFacet;
        freezable[3] = true;

        facetIds[4] = CTMContract.MigratorFacet;
        facetAddresses[4] = _facets.migratorFacet;
        freezable[4] = false;

        facetIds[5] = CTMContract.CommitterFacet;
        facetAddresses[5] = _facets.committerFacet;
        freezable[5] = true;

        GatewayGenesisRegistry genesisRegistry = new GatewayGenesisRegistry{salt: _salt}();
        genesisRegistry.initialize(_protocolVersion, facetIds, facetAddresses, freezable);
        registry = address(genesisRegistry);
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
