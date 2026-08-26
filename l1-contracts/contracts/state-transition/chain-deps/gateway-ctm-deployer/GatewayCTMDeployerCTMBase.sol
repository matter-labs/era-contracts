// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../libraries/Diamond.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ChainTypeManagerInitializeData, IChainTypeManager} from "../../IChainTypeManager.sol";
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

        // Gateway pins a genesis release, exactly like L1: the committed cut carries NO facet
        // addresses (empty `facetCuts`) and NO init payload (empty `initCalldata`). `DiamondInit`
        // installs the release's explicit facet routing and reads the base system contract
        // hashes from it.
        // TODO(gateway): a `CTMRelease` takes its manifest as a CONSTRUCTOR argument and EraVM has
        // no constructors, so the release cannot be built inside this deployer's transaction — it
        // is supplied pre-deployed and merely pinned here. Making this deployer stand up a Gateway
        // CTM on its own needs an EraVM-deployable release that takes its manifest through an
        // atomic post-deployment initialization.
        address currentRelease = _config.currentRelease;

        Diamond.DiamondCutData memory diamondCut = Diamond.DiamondCutData({
            facetCuts: new Diamond.FacetCut[](0),
            initAddress: facets.diamondInit,
            initCalldata: ""
        });

        _result.diamondCutData = abi.encode(diamondCut);

        ChainTypeManagerInitializeData memory diamondInitData = ChainTypeManagerInitializeData({
            owner: baseConfig.aliasedGovernanceAddress,
            validatorTimelock: _config.validatorTimelockProxy,
            releaseCodehash: _config.currentRelease.codehash,
            currentRelease: currentRelease,
            protocolVersion: baseConfig.protocolVersion,
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
