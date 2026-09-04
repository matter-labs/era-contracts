// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../libraries/Diamond.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ChainCreationParams, ChainTypeManagerInitializeData, IChainTypeManager} from "../../IChainTypeManager.sol";
import {ServerNotifier} from "../../../governance/ServerNotifier.sol";
import {ChainTypeManager} from "../../ChainTypeManager.sol";

import {L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";

import {Facets} from "contracts/common/StateTransitionTypes.sol";
import {GatewayCTMDeployerConfig, GatewayCTMFinalConfig, GatewayCTMFinalResult} from "./GatewayCTMDeployer.sol";

/// @title GatewayCTMDeployerCTM
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Gateway CTM deployer: deploys ServerNotifier and the ZKsync OS CTM, links them together.
contract GatewayCTMDeployerCTM {
    GatewayCTMFinalResult internal deployedResult;

    /// @notice Returns the deployed contracts from this deployer.
    /// @return result The struct with information about the deployed contracts.
    function getResult() external view returns (GatewayCTMFinalResult memory result) {
        result = deployedResult;
    }

    constructor(GatewayCTMFinalConfig memory _config) {
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

    /// @notice Deploys the ChainTypeManager contract.
    /// @param _salt Salt used for CREATE2 deployments.
    /// @param _config The deployment config.
    /// @param _result The result struct to populate with CTM addresses.
    function _deployCTM(
        bytes32 _salt,
        GatewayCTMFinalConfig memory _config,
        GatewayCTMFinalResult memory _result
    ) internal {
        // PermissionlessValidator is address(0) since Priority Mode is L1-only
        _result.chainTypeManagerImplementation = address(
            new ChainTypeManager{salt: _salt}(L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER_ADDR, address(0), address(0))
        );

        GatewayCTMDeployerConfig memory baseConfig = _config.baseConfig;
        Facets memory facets = _config.facets;

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

        // The chain-creation init tail is empty: the verifier is fetched from the CTM on-chain and
        // the remaining fields of `InitializeData` are mandatory data prepended by the CTM itself.
        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: facetCuts,
            initAddress: facets.diamondInit,
            initCalldata: hex""
        });

        _result.diamondCutData = abi.encode(diamondCut);

        ChainCreationParams memory chainCreationParams = ChainCreationParams({
            genesisUpgrade: _config.genesisUpgrade,
            genesisBatchHash: baseConfig.genesisRoot,
            genesisIndexRepeatedStorageChanges: uint64(baseConfig.genesisRollupLeafIndex),
            genesisBatchCommitment: baseConfig.genesisBatchCommitment,
            diamondCut: diamondCut,
            forceDeploymentsData: baseConfig.forceDeploymentsData
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
