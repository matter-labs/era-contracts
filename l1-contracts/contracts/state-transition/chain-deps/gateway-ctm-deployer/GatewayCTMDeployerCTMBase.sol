// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../libraries/Diamond.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    FacetInstallation,
    InitializeDataNewChain as DiamondInitializeDataNewChain
} from "../../chain-interfaces/IDiamondInit.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "../../IChainTypeManager.sol";
import {ServerNotifier} from "../../../governance/ServerNotifier.sol";

import {Facets} from "contracts/common/StateTransitionTypes.sol";
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

        // No facet cuts and no selector lists: DiamondInit installs the facets itself, reading
        // each facet's own `ISelfDescribingFacet.selectors()` on the chain where the cut runs —
        // the facets deployed above are all self-describing.
        FacetInstallation[] memory facetInstallations = new FacetInstallation[](6);
        facetInstallations[0] = FacetInstallation({
            facet: facets.adminFacet,
            isFreezable: false,
            selectors: new bytes4[](0)
        });
        facetInstallations[1] = FacetInstallation({
            facet: facets.gettersFacet,
            isFreezable: false,
            selectors: new bytes4[](0)
        });
        facetInstallations[2] = FacetInstallation({
            facet: facets.mailboxFacet,
            isFreezable: true,
            selectors: new bytes4[](0)
        });
        facetInstallations[3] = FacetInstallation({
            facet: facets.executorFacet,
            isFreezable: true,
            selectors: new bytes4[](0)
        });
        facetInstallations[4] = FacetInstallation({
            facet: facets.migratorFacet,
            isFreezable: false,
            selectors: new bytes4[](0)
        });
        facetInstallations[5] = FacetInstallation({
            facet: facets.committerFacet,
            isFreezable: true,
            selectors: new bytes4[](0)
        });

        // Only system contract hashes are initialized here; verifier and facet set are read from
        // the CTM on-chain (the facet set via `newChainFacetData`, stored below).
        DiamondInitializeDataNewChain memory initializeData = DiamondInitializeDataNewChain({
            l2BootloaderBytecodeHash: baseConfig.bootloaderHash,
            l2DefaultAccountBytecodeHash: baseConfig.defaultAccountHash,
            l2EvmEmulatorBytecodeHash: baseConfig.evmEmulatorHash
        });

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
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
            newChainFacetData: abi.encode(facetInstallations)
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
